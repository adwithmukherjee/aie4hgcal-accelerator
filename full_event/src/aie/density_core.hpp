#pragma once
#include <adf.h>
#include <aie_api/aie.hpp>
#include "density.hpp"

using Mat = aie::mmul<4, 8, 4, int8, int8, acc48>;
using V16 = aie::vector<int32, 16>;
using V4 = aie::vector<int32, 4>;

// AIE1's byte transpose/byte zip(1) APIs use scalar fallbacks in 2022.2.
// Widen first: every interleave below maps to a native 16/32-bit shuffle.
static inline __attribute__((always_inline))
aie::vector<int8, 32> transpose4x8(aie::vector<int8, 32> input) {
    const v32int16 wide = ::unpack(input.to_native());
    const v32int16 rows = ::as_v32int16(::shuffle16(::as_v16int32(wide), 0, 0xba983210, 0xfedc7654));
    const v32int16 pairs = ::select32(0xaaaaaaaa, rows, 0, 0x03020100, 0x07060504, 0x0100,
                                                rows,16, 0x03020100, 0x07060504, 0x1000);
    const v32int16 columns = ::as_v32int16(::shuffle16(::as_v16int32(pairs), 0, 0xb3a29180, 0xf7e6d5c4));
    return ::pack(columns);
}

// Four byte lanes, each representing one landmark. Summing four rows and
// five hit blocks cannot carry between lanes (each final count is <= 20).
constexpr std::array<uint32_t,256> make_membership_bytes() {
    std::array<uint32_t,256> table{};
    for (unsigned mask=0; mask<256; ++mask)
        for (unsigned column=0; column<4; ++column)
            table[mask] |= (((mask>>column)&1) + ((mask>>(column+4))&1)) << (8*column);
    return table;
}
alignas(32) static constexpr auto membership_bytes = make_membership_bytes();
static inline __attribute__((always_inline))
uint32_t packed_membership(unsigned mask) {
    return membership_bytes[mask & 255] + membership_bytes[mask >> 8];
}

template<bool First, bool SingleHit = false>
static inline __attribute__((always_inline))
void compute_hit_block(aie::vector<int8,32> hits, V4 norms_h,
                       const int8* __restrict columns,
                       const int32* __restrict landmark_norms,
                       int32* __restrict cache, uint32_t* __restrict counts) {
    const V4 threshold{int32(density::radius_squared),0,0,0};
    for (unsigned r=0; r<32; ++r) chess_prepare_for_pipelining chess_loop_range(32,32) {
        Mat dots; dots.mul(hits,aie::load_v<32>(columns+r*32));
        // AIE1 SRS supports shift -1: produce 2*dot without another vector add.
        auto twice_dot=dots.to_vector<int32>(-1);
        auto norms_r=aie::load_v<4>(landmark_norms+r*4);
        auto norm_operands=aie::concat(norms_h,norms_r).grow<16>();
        V16 norms=::add16(norm_operands,0,0x11110000,0x33332222,
                                       4,0x32103210,0x32103210);
        auto squared=aie::sub(norms,twice_dot);
        unsigned mask=aie::ge(threshold[0],squared).data()[0];
        if constexpr (SingleHit) {
            // Row zero holds the real 21st hit; rows 1..3 are padding.
            aie::store_v(cache+r*4, squared.extract<4>(0));
            counts[r] += membership_bytes[mask & 0xf];
        } else {
            aie::store_v(cache+r*16,squared);
            if constexpr (First) counts[r]=packed_membership(mask);
            else counts[r]+=packed_membership(mask);
        }
    }
}

// The same arithmetic and blocked INT32 cache are used by both transports.
template<bool ExtraHit>
static inline __attribute__((always_inline))
void prepare_density(const int8* __restrict values,
                     const int8* __restrict representative_values,
                     int32* __restrict cache, uint32_t* __restrict counts,
                     int32* __restrict tail_distances) {
    alignas(32) int32 hit_norms[5 * 4];
    alignas(32) int32 landmark_norms[32 * 4];
    alignas(32) int8 landmark_columns[32 * 32];
    for (unsigned h = 0; h < 5; ++h) chess_prepare_for_pipelining chess_loop_range(5,5) {
        auto hits = aie::load_v<32>(values + h * 32);
        Mat gram; gram.mul(hits, transpose4x8(hits));
        V16 diagonal = ::shuffle16(gram.to_vector<int32>(), 0, 0x0000fa50, 0);
        aie::store_v(hit_norms + h * 4, diagonal.extract<4>(0));
    }
    for (unsigned r = 0; r < 32; ++r) chess_prepare_for_pipelining chess_loop_range(32,32) {
        auto representatives = aie::load_v<32>(representative_values + r * 32);
        auto transposed = transpose4x8(representatives);
        Mat gram; gram.mul(representatives, transposed);
        V16 diagonal = ::shuffle16(gram.to_vector<int32>(), 0, 0x0000fa50, 0);
        aie::store_v(landmark_norms + r * 4, diagonal.extract<4>(0));
        aie::store_v(landmark_columns + r * 32, transposed);
    }
    compute_hit_block<true>(aie::load_v<32>(values),aie::load_v<4>(hit_norms),
                            landmark_columns,landmark_norms,cache,counts);
    for (unsigned h=1; h<5; ++h)
        compute_hit_block<false>(aie::load_v<32>(values+h*32),aie::load_v<4>(hit_norms+h*4),
                                 landmark_columns,landmark_norms,cache+h*32*16,counts);
    if constexpr (ExtraHit) {
        // The 176-byte hit window contains 16 readable bytes after the SIMD batch.
        const auto pair = aie::load_v<16>(values+160);
        const auto tail = aie::concat(pair,pair);
        Mat gram;
        gram.mul(tail,transpose4x8(tail));
        V16 diagonal = ::shuffle16(gram.to_vector<int32>(),0,0x0000fa50,0);
        compute_hit_block<false,true>(tail,diagonal.extract<4>(0),landmark_columns,
                                      landmark_norms,tail_distances,counts);
    }
}

#pragma once
#include "density_core.hpp"

namespace assignment {
constexpr int32 unselected = 1 << 30;
constexpr unsigned rank_bits = 6;
constexpr unsigned rank_mask = (1u << rank_bits) - 1;
constexpr int32 maximum_distance = 8 * 255 * 255;
static_assert((maximum_distance << rank_bits) + rank_mask < unselected);
static_assert(unselected + (maximum_distance << rank_bits) < 0x7fffffff);

// UPS/SRS uses constrained AIE1 registers. Separating it from the running
// minimum avoids spilling that minimum on every cache block. This in-place
// pass runs only after density has consumed the unscaled distances.
static __attribute__((noinline)) void prepare(int32* cache) {
    // UG1079's in-place read/modify/write idiom: each vector is read once,
    // then overwritten, and different iterations touch disjoint addresses.
    // Keep the advancing load/store pointers independent for software pipelining.
    int32* __restrict output = chess_copy(cache);
    for (unsigned offset = 0; offset < density::distances; offset += 8)
            chess_prepare_for_pipelining chess_loop_range(320,320) {
        const auto distance = aie::load_v<8>(cache + offset);
        aie::store_v(output + offset,aie::upshift(distance,rank_bits));
    }
}

// Cache lanes are four consecutive landmarks for each of four hits. The
// low six bits encode seed order, so a plain signed minimum preserves ties.
// Unselected landmarks receive a larger key than every valid INT8 distance.
static __attribute__((noinline)) void assign(const int32* __restrict cache,
                                            const int32* __restrict ranks,
                                            int32* __restrict keys) {
    for (unsigned h = 0; h < 5; ++h) chess_unroll_loop(1) chess_loop_range(5,5) {
        V16 best = aie::broadcast<int32,16>(0x7fffffff);
        for (unsigned block = 0; block < 32; ++block)
                chess_prepare_for_pipelining chess_loop_range(32,32) {
            const V16 scaled = aie::load_v<16>(cache + h * 512 + block * 16);
            const V16 rank = aie::load_v<4>(ranks + block * 4).grow<16>();
            const V16 candidate = ::add16(scaled,0,0x76543210,0xfedcba98,
                                          rank,0,0x32103210,0x32103210);
            best = aie::min(best,candidate);
        }
        // Reduce within each group of four lanes, never across different hits.
        best = V16(::min16(best,0,0x76543210,0xfedcba98,
                               0,0x67452301,0xefcdab89));
        best = V16(::min16(best,0,0x76543210,0xfedcba98,
                               0,0x54761032,0xdcfe98ba));
        const V16 gathered = ::shuffle16(best,0,0x0000c840,0);
        aie::store_v(keys + h * 4,gathered.extract<4>(0));
    }
}
}

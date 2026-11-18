#pragma once
#include "density_core.hpp"

// Sort packed (distance, landmark slot) keys with native AIE1 word operations.
// 8 * 255^2 * 128 + 127 fits in signed INT32; no distance precision is lost.
namespace shortlist {
constexpr unsigned size=32;
constexpr unsigned xor_offsets(unsigned first,unsigned stride) {
    unsigned result=0;
    for(unsigned i=0;i<8;++i) result|=((first+i)^stride)<<(4*i);
    return result;
}
constexpr unsigned minimum_lanes(unsigned group,unsigned stride,bool descending) {
    unsigned result=0;
    for(unsigned i=0;i<16;++i)
        if(((i&stride)==0)^((i&group)!=0)^descending) result|=1u<<i;
    return result;
}
template<unsigned Group,unsigned Stride,bool Descending=false>
static inline __attribute__((always_inline)) V16 exchange(V16 value) {
    constexpr unsigned low=xor_offsets(0,Stride),high=xor_offsets(8,Stride);
    const unsigned less=::lt16(value,0,0x76543210,0xfedcba98,0,low,high);
    return ::select16(less^minimum_lanes(Group,Stride,Descending),
                      value,0,0x76543210,0xfedcba98,value,0,low,high);
}
template<bool Descending=false>
static inline __attribute__((always_inline)) V16 sort16(V16 v) {
    v=exchange<2,1,Descending>(v);
    v=exchange<4,2,Descending>(v);v=exchange<4,1,Descending>(v);
    v=exchange<8,4,Descending>(v);v=exchange<8,2,Descending>(v);v=exchange<8,1,Descending>(v);
    v=exchange<16,8,Descending>(v);v=exchange<16,4,Descending>(v);
    v=exchange<16,2,Descending>(v);return exchange<16,1,Descending>(v);
}
static inline __attribute__((always_inline)) V16 merge16(V16 v) {
    v=exchange<16,8>(v);v=exchange<16,4>(v);v=exchange<16,2>(v);
    return exchange<16,1>(v);
}
static inline __attribute__((always_inline)) void merge32(V16& low,V16& high) {
    const V16 a=aie::min(low,high),b=aie::max(low,high);
    low=merge16(a);high=merge16(b);
}
static inline __attribute__((always_inline)) V16 load_scratch(const int32* p) {
    const auto low=*reinterpret_cast<const volatile v8int32*>(p);
    const auto high=*reinterpret_cast<const volatile v8int32*>(p+8);
    return aie::concat(aie::vector<int32,8>(low),aie::vector<int32,8>(high));
}
static inline __attribute__((always_inline)) void store_scratch(int32* p,V16 value) {
    *reinterpret_cast<volatile v8int32*>(p)=value.extract<8>(0).to_native();
    *reinterpret_cast<volatile v8int32*>(p+8)=value.extract<8>(1).to_native();
}
alignas(32) static constexpr int32 slot_offsets[16]={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
static inline __attribute__((always_inline)) V16 load_keys(const int32* cache,unsigned slot) {
    // One hit's four consecutive landmarks from each 4x4 cache block.
    const V16 distance=aie::concat(aie::load_v<4>(cache),aie::load_v<4>(cache+16),
                                   aie::load_v<4>(cache+32),aie::load_v<4>(cache+48));
    const V16 slots=load_scratch(slot_offsets);
    return aie::add(aie::upshift(distance,7),aie::add(slots,int32(slot)));
}
// AIE1's compare/shuffle operands use most vector registers. Keep the other
// half in explicit SRAM between networks instead of holding it live throughout.
static inline __attribute__((always_inline)) void merge32_memory(int32* values,int32* lower) {
    store_scratch(lower,aie::min(load_scratch(values),load_scratch(values+16)));
    store_scratch(values+16,aie::max(load_scratch(values),load_scratch(values+16)));
    store_scratch(values,merge16(load_scratch(lower)));
    store_scratch(values+16,merge16(load_scratch(values+16)));
}
static __attribute__((noinline)) void sort_block(const int32* row,unsigned slot,int32* output,int32* lower) {
    store_scratch(output,sort16(load_keys(row,slot)));
    store_scratch(output+16,sort16<true>(load_keys(row+64,slot+16)));
    merge32_memory(output,lower);
}
static __attribute__((noinline)) void merge_block(int32* best,const int32* candidate,int32* lower) {
    store_scratch(best,V16(::min16(load_scratch(best),0,0x76543210,0xfedcba98,
        load_scratch(candidate+16),0,0x89abcdef,0x01234567)));
    store_scratch(best+16,V16(::min16(load_scratch(best+16),0,0x76543210,0xfedcba98,
        load_scratch(candidate),0,0x89abcdef,0x01234567)));
    merge32_memory(best,lower);
}
static __attribute__((noinline)) void prepare(const int32* cache,int32* output) {
    alignas(32) int32 candidate[48];
    for(unsigned hit=0;hit<20;++hit) chess_unroll_loop(1) chess_loop_range(20,20) {
        const int32* row=cache+(hit/4)*512+(hit%4)*4;
        int32* best=output+hit*32;
        sort_block(row,0,best,candidate+32);
        for(unsigned block=1;block<4;++block) chess_unroll_loop(1) chess_loop_range(3,3) {
            const int32* next=row+block*128;
            const V16 low=load_keys(next,block*32);
            const V16 high=load_keys(next+64,block*32+16);
            if(aie::min_reduce(aie::min(low,high))>=best[31]) continue;
            sort_block(next,block*32,candidate,candidate+32);
            merge_block(best,candidate,candidate+32);
        }
    }
}

// Scan only through the nearest selected distance group, preserving seed-order
// ties. A winner at the cutoff may tie an omitted landmark: use the exact path.
static inline __attribute__((always_inline)) int lookup(const int32* keys,const int32* ranks) {
    int32 best_distance=0x7fffffff,label=127;
    const int32 cutoff=keys[31]>>7;
    for(unsigned k=0;k<32;++k) chess_loop_range(1,32) {
        const int32 key=keys[k],distance=key>>7;
        if(distance>best_distance) break;
        const int32 rank=ranks[key&127];
        if(rank!=127) {best_distance=distance;label=rank<label?rank:label;}
    }
    return best_distance>=cutoff ? -1 : label;
}
}

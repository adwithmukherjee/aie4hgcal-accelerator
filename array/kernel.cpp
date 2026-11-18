#include "density_core.hpp"

static inline __attribute__((always_inline))
void update_label(const int32* cache,unsigned landmark,unsigned seed,V4& best,V4& label) {
    const V16 block=aie::load_v<16>(cache+(landmark/4)*16);
    const V16 gathered=::shuffle16(block,landmark&3,0x0000c840,0);
    const V4 squared=gathered.extract<4>(0);
    // min_cmp also returns a >= b: equality preserves the earlier seed.
    auto [minimum,keep_old]=aie::min_cmp(squared,best);
    best=minimum;
    label=aie::select(aie::broadcast<int32,4>(seed),label,keep_old);
}


void column_density(input_window<int32>* hits, input_window<int32>* landmarks,
                    input_pktstream* control, output_pktstream* output) {
    alignas(32) int32 cache[density::distances];
    alignas(32) uint32_t counts[32];
    alignas(32) int32 seed_ids[64];
    alignas(32) int32 labels[20];
    prepare_density(reinterpret_cast<const int8*>(hits->ptr),
                    reinterpret_cast<const int8*>(landmarks->ptr), cache, counts);
    const unsigned id = getPacketid(output, 0);
    writeHeader(output, 0, id);
    for (unsigned r=0; r<32; ++r) writeincr(output, int32(counts[r]), r==31);
    // Reuse the exact distances already resident in this tile.
    chess_separator_scheduler();
    readincr(control); // packet header
    const unsigned count=unsigned(readincr(control));
    for (unsigned word=0; word<(count+3)/4; ++word) {
        const uint32_t packed=uint32_t(readincr(control));
        for (unsigned lane=0; lane<4; ++lane)
            seed_ids[word*4+lane]=(packed>>(lane*8))&127;
    }
    chess_separator_scheduler();
    for (unsigned h=0; h<5; ++h) {
        V4 best=aie::broadcast<int32,4>(0x7fffffff);
        V4 label=aie::zeros<int32,4>();
        // Avoid the compiler's serial short-trip loop for 1-3 seeds.
        if(count<4) {
            for(unsigned s=0;s<3;++s) chess_unroll_loop(3) {
                if(s<count) update_label(cache+h*512,seed_ids[s],s,best,label);
            }
        } else {
            for(unsigned s=0;s<count;++s) chess_prepare_for_pipelining chess_loop_range(4,64)
                update_label(cache+h*512,seed_ids[s],s,best,label);
        }
        aie::store_v(labels+h*4,label);
    }
    chess_separator_scheduler();
    writeHeader(output, 2, id);
    for (unsigned h=0; h<5; ++h) {
        const uint32_t packed=uint32_t(labels[h*4])|(uint32_t(labels[h*4+1])<<8)
                            |(uint32_t(labels[h*4+2])<<16)|(uint32_t(labels[h*4+3])<<24);
        writeincr(output,int32(packed),h==4);
    }
}

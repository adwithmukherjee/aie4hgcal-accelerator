#include "density_core.hpp"
#include "assignment.hpp"

template<bool extra_hit>
static void process_tile(input_window<int32>* hits, input_window<int32>* landmarks,
                    input_pktstream* control, output_pktstream* output) {
    alignas(32) int32 cache[density::distances];
    alignas(32) uint32_t counts[32];
    alignas(32) int32 seed_ranks[128];
    alignas(32) int32 labels[20];
    alignas(32) int32 extra_distances[extra_hit ? 128 : 1];
    prepare_density<extra_hit>(reinterpret_cast<const int8*>(hits->ptr),
                               reinterpret_cast<const int8*>(landmarks->ptr),
                               cache, counts, extra_distances);
    const unsigned id = getPacketid(output, 0);
    writeHeader(output, 0, id);
    for (unsigned r=0; r<32; ++r) writeincr(output, int32(counts[r]), r==31);
    chess_separator_scheduler();
    assignment::prepare(cache);
    for(unsigned s=0;s<128;s+=16)
        aie::store_v(seed_ranks+s,aie::broadcast<int32,16>(assignment::unselected));
    chess_separator_scheduler();
    readincr(control); // packet header
    const unsigned count=unsigned(readincr(control));
    // Full words need neither a seed-ID copy nor four per-lane bounds checks.
    for (unsigned word=0; word<count/4; ++word) {
        const uint32_t packed=uint32_t(readincr(control));
        seed_ranks[packed&127]=word*4;
        seed_ranks[(packed>>8)&127]=word*4+1;
        seed_ranks[(packed>>16)&127]=word*4+2;
        seed_ranks[(packed>>24)&127]=word*4+3;
    }
    const unsigned remainder=count&3;
    if(remainder) {
        const uint32_t packed=uint32_t(readincr(control));
        const unsigned first=count-remainder;
        seed_ranks[packed&127]=first;
        if(remainder>1) seed_ranks[(packed>>8)&127]=first+1;
        if(remainder>2) seed_ranks[(packed>>16)&127]=first+2;
    }
    chess_separator_scheduler();
    assignment::assign(cache,seed_ranks,labels);
    chess_separator_scheduler();
    writeHeader(output, 2, id);
    for (unsigned h=0; h<5; ++h) {
        const uint32_t packed=(uint32_t(labels[h*4])&assignment::rank_mask)
                            |((uint32_t(labels[h*4+1])&assignment::rank_mask)<<8)
                            |((uint32_t(labels[h*4+2])&assignment::rank_mask)<<16)
                            |((uint32_t(labels[h*4+3])&assignment::rank_mask)<<24);
        writeincr(output,int32(packed),h==4 && !extra_hit);
    }
    if constexpr (extra_hit) {
        V16 best = aie::broadcast<int32,16>(0x7fffffff);
        for (unsigned block=0; block<8; ++block)
                chess_prepare_for_pipelining chess_loop_range(8,8) {
            const V16 distances = aie::load_v<16>(extra_distances+16*block);
            const V16 ranks = aie::load_v<16>(seed_ranks+16*block);
            const V16 keys = aie::add(aie::upshift(distances,assignment::rank_bits),ranks);
            best = aie::min(best,keys);
        }
        const int32 winner = aie::reduce_min(best);
        writeincr(output, int32(winner & assignment::rank_mask), true);
    }
}

void cluster20(input_window<int32>* hits, input_window<int32>* landmarks,
               input_pktstream* control, output_pktstream* output) {
    process_tile<false>(hits, landmarks, control, output);
}

void cluster21(input_window<int32>* hits, input_window<int32>* landmarks,
               input_pktstream* control, output_pktstream* output) {
    process_tile<true>(hits, landmarks, control, output);
}

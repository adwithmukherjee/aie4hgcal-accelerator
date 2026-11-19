#include "density_core.hpp"
#include "assignment.hpp"

void column_density(input_window<int32>* hits, input_window<int32>* landmarks,
                    input_pktstream* control, output_pktstream* output) {
    alignas(32) int32 cache[density::distances];
    alignas(32) uint32_t counts[32];
    alignas(32) int32 seed_ranks[128];
    alignas(32) int32 labels[20];
    prepare_density(reinterpret_cast<const int8*>(hits->ptr),
                    reinterpret_cast<const int8*>(landmarks->ptr), cache, counts);
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
        writeincr(output,int32(packed),h==4);
    }
}

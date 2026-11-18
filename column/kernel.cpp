#include "density_core.hpp"

void column_density(input_window<int32>* hits, input_window<int32>* landmarks,
                    input_pktstream* readback, output_pktstream* output) {
    alignas(32) int32 cache[density::distances];
    alignas(32) uint32_t counts[32];
    prepare_density(reinterpret_cast<const int8*>(hits->ptr),
                    reinterpret_cast<const int8*>(landmarks->ptr), cache, counts);
    const unsigned id = getPacketid(output, 0);
    writeHeader(output, 0, id);
    for (unsigned r = 0; r < 32; ++r)
        writeincr(output, int32(counts[r]), r == 31);

    // PL sends this token only after every active tile's density is accumulated.
    // Diagnostic matrix traffic therefore cannot contend with timed returns.
    // Stream operations on different ports may otherwise be reordered: even
    // an early matrix header can reserve the shared route and deadlock gather.
    chess_separator_scheduler();
    readincr(readback); // Header-only, untimed readback request.
    chess_separator_scheduler();
    writeHeader(output, 1, id);
    for (unsigned h = 0; h < 20; ++h)
        for (unsigned r = 0; r < 32; ++r)
            for (unsigned j = 0; j < 4; ++j)
                writeincr(output, cache[(h / 4 * 32 + r) * 16 + (h % 4) * 4 + j],
                          h == 19 && r == 31 && j == 3);
}

#include "density_core.hpp"

void landmark_density(input_window<int32>* input, output_stream<int32>* output) {
    alignas(32) int32 cache[density::distances];
    alignas(32) uint32_t counts[32];
    const int8* values = reinterpret_cast<const int8*>(input->ptr);
    prepare_density(values, values + 160, cache, counts);
    for (unsigned r = 0; r < 32; ++r) writeincr(output, int32(counts[r]));
    // Restore row-major readback after density completion (outside timing).
    for (unsigned h = 0; h < 20; ++h)
        for (unsigned r = 0; r < 32; ++r)
            for (unsigned j = 0; j < 4; ++j)
                writeincr(output, cache[(h / 4 * 32 + r) * 16 + (h % 4) * 4 + j]);
}

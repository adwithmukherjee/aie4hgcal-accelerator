#include <adf.h>
#include <cstdlib>
#include "density.hpp"
#ifndef DENSITY_ROW
#define DENSITY_ROW 0
#endif
void landmark_density(input_window<int32> *, output_stream<int32> *);
class DensityGraph : public adf::graph {
public:
    adf::input_plio input;
    adf::output_plio output;
    adf::kernel worker;
    DensityGraph() {
        input = adf::input_plio::create("input", adf::plio_128_bits, "input.txt", 300);
        output = adf::output_plio::create("output", adf::plio_128_bits, "output.txt", 300);
        worker = adf::kernel::create(landmark_density);
        adf::source(worker) = "density.cpp";
        adf::runtime<adf::ratio>(worker) = 0.9;
        adf::connect<adf::window<density::payload_bytes>>(input.out[0], worker.in[0]);
        adf::connect<adf::stream>(worker.out[0], output.in[0]);
        adf::single_buffer(worker.in[0]);
        adf::location<adf::kernel>(worker) = adf::tile(24, DENSITY_ROW);
        adf::location<adf::buffer>(worker.in[0]) = adf::address(24, DENSITY_ROW, 0x6000);
    }
};
DensityGraph density_graph;
#if defined(__AIESIM__) || defined(__X86SIM__)
int main() {
    const char *value = std::getenv("DENSITY_EVENTS");
    int events = value ? std::atoi(value) : 4;
    if (events <= 0) return 2;
    density_graph.init();
    density_graph.run(events);
    density_graph.end();
    return 0;
}
#endif

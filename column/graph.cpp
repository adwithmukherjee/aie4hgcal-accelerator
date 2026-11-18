#include <adf.h>
#include <cstdlib>
#include "density.hpp"
#ifndef COLUMN_TILES
#define COLUMN_TILES 8
#endif

void column_density(input_window<int32>*, input_window<int32>*,
                    input_pktstream*, output_pktstream*);

class ColumnGraph : public adf::graph {
public:
    adf::input_plio input;
    adf::output_plio output;
    adf::kernel worker[COLUMN_TILES];
    // Unique hits, one common landmark multicast, then untimed readback requests.
    adf::pktsplit<2*COLUMN_TILES+1> ingress;
    adf::pktmerge<COLUMN_TILES> egress;

    ColumnGraph() {
        input = adf::input_plio::create("column_input", adf::plio_128_bits, "input.txt", 300);
        output = adf::output_plio::create("column_output", adf::plio_128_bits, "output.txt", 300);
        adf::location<adf::PLIO>(input) = adf::shim(24, 0);
        adf::location<adf::PLIO>(output) = adf::shim(24, 0);
        ingress = adf::pktsplit<2*COLUMN_TILES+1>::create();
        egress = adf::pktmerge<COLUMN_TILES>::create();
        adf::connect<adf::pktstream>(input.out[0], ingress.in[0]);
        adf::connect<adf::pktstream>(egress.out[0], output.in[0]);
        for (unsigned r = 0; r < COLUMN_TILES; ++r) {
            worker[r] = adf::kernel::create(column_density);
            adf::source(worker[r]) = "kernel.cpp";
            adf::runtime<adf::ratio>(worker[r]) = 0.9;
            adf::location<adf::kernel>(worker[r]) = adf::tile(24, r);
            adf::single_buffer(worker[r].in[0]);
            adf::single_buffer(worker[r].in[1]);
            adf::location<adf::buffer>(worker[r].in[0]) = adf::address(24, r, 0x6000);
            adf::location<adf::buffer>(worker[r].in[1]) = adf::address(24, r, 0x6100);
            adf::connect<adf::pktstream, adf::window<160>>(ingress.out[r], worker[r].in[0]);
            adf::connect<adf::pktstream, adf::window<1024>>(ingress.out[COLUMN_TILES], worker[r].in[1]);
            adf::connect<adf::pktstream>(ingress.out[COLUMN_TILES+1+r], worker[r].in[2]);
            adf::connect<adf::pktstream>(worker[r].out[0], egress.in[r]);
        }

    }
};
ColumnGraph column_graph;

#if defined(__AIESIM__) || defined(__X86SIM__)
int main() {
    const char* value = std::getenv("DENSITY_EVENTS");
    const int events = value ? std::atoi(value) : 4;
    if (events <= 0) return 2;
    column_graph.init();
    column_graph.run(events); // Every compiled row receives each native qualification frame.
    column_graph.end();
    return 0;
}
#endif

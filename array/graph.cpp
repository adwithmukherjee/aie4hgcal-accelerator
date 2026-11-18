#include <adf.h>
#include <cstdlib>
#include <string>
#ifndef ARRAY_COLUMNS
#define ARRAY_COLUMNS 4
#endif

void column_density(input_window<int32>*, input_window<int32>*,
                    input_pktstream*, output_pktstream*);

class ArrayGraph : public adf::graph {
public:
    adf::input_plio input[ARRAY_COLUMNS];
    adf::output_plio output[ARRAY_COLUMNS];
    adf::kernel worker[8*ARRAY_COLUMNS];
    adf::pktsplit<10> ingress[ARRAY_COLUMNS];
    adf::pktmerge<8> egress[ARRAY_COLUMNS];
    ArrayGraph() {
        for (unsigned c=0;c<ARRAY_COLUMNS;++c) {
            const std::string index=std::to_string(c);
            input[c]=adf::input_plio::create("array_input_"+index,adf::plio_128_bits,"input-"+index+".txt",300);
            output[c]=adf::output_plio::create("array_output_"+index,adf::plio_128_bits,"output-"+index+".txt",300);
            adf::location<adf::PLIO>(input[c])=adf::shim(24+c,0);
            adf::location<adf::PLIO>(output[c])=adf::shim(24+c,0);
            ingress[c]=adf::pktsplit<10>::create();
            egress[c]=adf::pktmerge<8>::create();
            adf::connect<adf::pktstream>(input[c].out[0],ingress[c].in[0]);
            adf::connect<adf::pktstream>(egress[c].out[0],output[c].in[0]);
            for (unsigned r=0;r<8;++r) {
                const unsigned i=c*8+r;
                worker[i]=adf::kernel::create(column_density);
                adf::source(worker[i])="kernel.cpp";
                adf::runtime<adf::ratio>(worker[i])=0.9;
                adf::location<adf::kernel>(worker[i])=adf::tile(24+c,r);
                adf::single_buffer(worker[i].in[0]);
                adf::single_buffer(worker[i].in[1]);
                adf::location<adf::buffer>(worker[i].in[0])=adf::address(24+c,r,0x6000);
                adf::location<adf::buffer>(worker[i].in[1])=adf::address(24+c,r,0x6100);
                adf::connect<adf::pktstream,adf::window<160>>(ingress[c].out[r],worker[i].in[0]);
                adf::connect<adf::pktstream,adf::window<1024>>(ingress[c].out[8],worker[i].in[1]);
                adf::connect<adf::pktstream>(ingress[c].out[9],worker[i].in[2]);
                adf::connect<adf::pktstream>(worker[i].out[0],egress[c].in[r]);
            }
        }
    }
};
ArrayGraph array_graph;

#if defined(__AIESIM__) || defined(__X86SIM__)
int main() {
    const char* value=std::getenv("DENSITY_EVENTS");
    const int events=value ? std::atoi(value) : 4;
    if(events<=0) return 2;
    array_graph.init();
    array_graph.run(events);
    array_graph.end();
    return 0;
}
#endif

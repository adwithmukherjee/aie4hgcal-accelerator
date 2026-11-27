#include <adf.h>
#include <cstdlib>
#include <string>
constexpr unsigned ARRAY_COLUMNS = 48;
constexpr unsigned long_columns = 40;
static_assert(8 * (long_columns * 21 + (ARRAY_COLUMNS - long_columns) * 20) == 8000);

void cluster20(input_window<int32>*, input_window<int32>*, input_pktstream*, output_pktstream*);
void cluster21(input_window<int32>*, input_window<int32>*, input_pktstream*, output_pktstream*);

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
            ingress[c]=adf::pktsplit<10>::create();
            egress[c]=adf::pktmerge<8>::create();
            adf::connect<adf::pktstream>(input[c].out[0],ingress[c].in[0]);
            adf::connect<adf::pktstream>(egress[c].out[0],output[c].in[0]);
            for (unsigned r=0;r<8;++r) {
                const unsigned i=c*8+r;
                if (c < long_columns) {
                    worker[i]=adf::kernel::create(cluster21);
                } else {
                    worker[i]=adf::kernel::create(cluster20);
                }
                adf::source(worker[i])="kernel.cpp";
                adf::runtime<adf::ratio>(worker[i])=0.9;
                adf::location<adf::kernel>(worker[i])=adf::tile(1+c,r);
                adf::single_buffer(worker[i].in[0]);
                adf::single_buffer(worker[i].in[1]);
                adf::location<adf::buffer>(worker[i].in[0])=adf::address(1+c,r,0x6000);
                adf::location<adf::buffer>(worker[i].in[1])=adf::address(1+c,r,0x6100);
                // A 21-hit window ends with eight transport padding bytes.
                if (c < long_columns) {
                    adf::connect<adf::pktstream,adf::window<176>>(ingress[c].out[r],worker[i].in[0]);
                } else {
                    adf::connect<adf::pktstream,adf::window<160>>(ingress[c].out[r],worker[i].in[0]);
                }
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

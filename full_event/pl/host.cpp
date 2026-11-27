#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xrt/xrt_device.h>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

template<class T> std::vector<T> load(const char* path, size_t n) {
    std::ifstream f(path,std::ios::binary | std::ios::ate);
    if (!f || f.tellg()!=std::streamoff(n*sizeof(T)))
        throw std::runtime_error(std::string("Unexpected file size: ")+path);
    std::vector<T> data(n);
    f.seekg(0);
    if (!f.read(reinterpret_cast<char*>(data.data()),n*sizeof(T)))
        throw std::runtime_error(std::string("Read failed: ")+path);
    return data;
}

int main() {
    try {
        const auto raw=load<uint32_t>("wire.bin",8000);
        const auto routes=load<uint32_t>("routes.bin",48*18);
        const auto expected=load<uint8_t>("labels.bin",8000);
        const xrt::xclbin image("integrated.xclbin");
        xrt::device device("0000:ca:00.1");
        auto uuid=device.load_xclbin(image);
        xrt::ip ip(device,uuid,"full_event_pl:{full_event_pl_1}");
        if (ip.read_register(8)!=0x38408000) throw std::runtime_error("Unexpected accelerator identity");
        for (unsigned c=0;c<48;++c)
            for (unsigned i=0;i<18;++i)
                ip.write_register(0x1000+c*128+i*4,routes[c*18+i]);
        std::vector<uint8_t> labels;
        labels.reserve(8000);
        using clock=std::chrono::steady_clock;
        const auto begin=clock::now();
        ip.write_register(0,2);
        for (unsigned i=0;i<raw.size();++i) ip.write_register(0x8000+4*i,raw[i]);
        if (ip.read_register(12)!=8000) throw std::runtime_error("Raw load incomplete");
        ip.write_register(0,1);
        const auto deadline=clock::now()+std::chrono::seconds(5);
        while (true) {
            const auto status=ip.read_register(4);
            if (status&4) throw std::runtime_error("PL reported packet or register fault");
            if (status&2) break;
            if (clock::now()>deadline) throw std::runtime_error("Completion timeout at phase "+std::to_string(ip.read_register(24)));
        }
        for (unsigned c=0;c<48;++c) {
            const unsigned n=c<40?21:20;
            for (unsigned row=0;row<8;++row)
                for (unsigned j=0;j<n;j+=4) {
                    const auto word=ip.read_register(0x4000+c*256+row*24+j);
                    for (unsigned b=0;b<4 && j+b<n;++b) labels.push_back((word>>(8*b))&255);
                }
        }
        const double host_us=std::chrono::duration<double,std::micro>(clock::now()-begin).count();
        if (labels.size()!=8000) throw std::runtime_error("Incomplete readback");
        for (unsigned i=0;i<8000;++i)
            if (labels[i]!=expected[i]) throw std::runtime_error("Label mismatch at event slot "+std::to_string(i));
        const auto cycles=ip.read_register(16);
        std::ofstream out("physical-labels.bin",std::ios::binary);
        out.write(reinterpret_cast<const char*>(labels.data()),labels.size());
        std::cout<<std::fixed<<std::setprecision(3)
                 <<"EVENT_LATENCY source=physical_hardware event=187 tiles=384 encoded_hits=8000 verified_labels=8000 seeds="<<ip.read_register(20)
                 <<" host_input_load_through_label_readback_us="<<host_us
                 <<" device_release_through_all_labels_cycles="<<cycles
                 <<" device_us_at_278MHz="<<cycles/278.0<<std::endl;
    } catch (const std::exception& e) {std::cerr<<e.what()<<std::endl;return 1;}
}

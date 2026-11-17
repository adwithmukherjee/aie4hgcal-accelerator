#include <xrt/xrt_device.h>
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xclhal2.h>
#include "density.hpp"
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>
namespace fs = std::filesystem;
int main(int argc, char **argv) {
 try {
    if(argc!=4) throw std::runtime_error("Usage: density_host design.xclbin data_dir results_dir");
    std::ifstream input(fs::path(argv[2])/"payloads.bin",std::ios::binary|std::ios::ate);
    if(!input) throw std::runtime_error("Cannot open payloads.bin");
    const auto bytes=input.tellg();
    if(bytes<=0 || size_t(bytes)%density::payload_bytes) throw std::runtime_error("Malformed frames");
    std::vector<uint32_t> frames(size_t(bytes)/4);input.seekg(0);
    if(!input.read(reinterpret_cast<char*>(frames.data()),bytes)) throw std::runtime_error("Short fixture read");
    const unsigned count=frames.size()/density::payload_words;
    fs::create_directories(argv[3]);
    std::ofstream report(fs::path(argv[3])/"events.json");
    const char *mode=std::getenv("XCL_EMULATION_MODE");
    if(mode && std::string(mode)!="hw_emu")
        throw std::runtime_error("Use hw_emu or unset XCL_EMULATION_MODE");
    report<<"{\"measurement\":\""<<(mode?mode:"physical_board")<<"\",\"events\":[\n";
    std::cout<<"Opening device and loading density design"<<std::endl;
    xrt::device device(0);
    auto uuid=device.load_xclbin(argv[1]);
    xrt::ip pl(device,uuid,"transport_pl:{transport_pl_1}");
    if(pl.read_register(0x34)!=0x44454e31) throw std::runtime_error("Wrong PL register map");
    if(pl.read_register(0x38)!=density::radius_squared) throw std::runtime_error("Wrong density radius");
    // Batch untimed aperture traffic. In XRT 2022.2 xclRegRead/Write themselves
    // use these block APIs; one RPC per word is particularly slow in hw_emu.
    uint64_t base=0; bool found=false;
    for(const auto &ip:xrt::xclbin(argv[1]).get_ips())
        if(ip.get_name()=="transport_pl:transport_pl_1") {
            base=ip.get_base_address();found=true;
            if(ip.get_size()<0x5200) throw std::runtime_error("PL aperture too small");
        }
    if(!found) throw std::runtime_error("PL aperture absent from xclbin");
    auto raw_device=static_cast<xclDeviceHandle>(device);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    const char *driver_name=mode ? "libxrt_hwemu.so.2" : "libxrt_core.so.2";
    auto close_driver=[](void *handle) { dlclose(handle); };
    std::unique_ptr<void,decltype(close_driver)> driver(dlopen(driver_name,RTLD_NOW|RTLD_LOCAL),close_driver);
    if(!driver) throw std::runtime_error(dlerror());
    auto block_write=reinterpret_cast<decltype(&xclWrite)>(dlsym(driver.get(),"xclWrite"));
    auto block_read=reinterpret_cast<decltype(&xclRead)>(dlsym(driver.get(),"xclRead"));
    if(!block_write || !block_read) throw std::runtime_error("XRT block-access API unavailable");
    auto write_words=[&](unsigned offset,const uint32_t *data,unsigned words) {
        if(block_write(raw_device,XCL_ADDR_KERNEL_CTRL,base+offset,data,words*4)!=words*4)
            throw std::runtime_error("PL block write failed");
    };
    auto read_words=[&](unsigned offset,uint32_t *data,unsigned words) {
        if(block_read(raw_device,XCL_ADDR_KERNEL_CTRL,base+offset,data,words*4)!=words*4)
            throw std::runtime_error("PL block read failed");
    };
#pragma GCC diagnostic pop
    // VCK5000 PCIe does not expose host graph-control APIs. Packaging without
    // defer_aie_run starts the graph during PDI load; it then waits for input.
    auto counter=[&](unsigned address) {
        return uint64_t(pl.read_register(address)) | (uint64_t(pl.read_register(address+4))<<32);
    };
    for(unsigned event=0;event<count;++event) {
        const uint32_t *frame=frames.data()+event*density::payload_words;
        std::vector<int8_t> coordinates(density::payload_bytes);
        std::memcpy(coordinates.data(),frame,density::payload_bytes);
        std::vector<uint32_t> expected(density::landmarks,0);
        for(unsigned h=0;h<density::hits;++h)
            for(unsigned r=0;r<density::landmarks;++r) {
                int32_t squared=0;
                for(unsigned d=0;d<8;++d) {
                    int32_t difference=int32_t(coordinates[h*8+d])-int32_t(coordinates[160+r*8+d]);
                    squared+=difference*difference;
                }
                expected[r]+=uint32_t(squared)<=density::radius_squared;
            }
        std::cout<<"Load real sequence "<<event+1<<std::endl;
        pl.write_register(0,2); // Clear the event accumulator outside timing.
        write_words(0x1000,frame,density::payload_words);
        std::cout<<"Release sequence "<<event+1<<std::endl;
        pl.write_register(0,1);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(5);
        uint32_t status;
        do {
            status=pl.read_register(4);
            if(status&8) throw std::runtime_error("PL rejected command or register write");
            if(std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Density stage timeout");
            if(!(status&4)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } while(!(status&4)); // Readback finishes after the density timer stops.
        if(!(status&2)) throw std::runtime_error("Density result was not completed");
        std::vector<uint32_t> actual(density::landmarks);
        read_words(0x5000,actual.data(),density::landmarks);
        for(unsigned r=0;r<density::landmarks;++r)
            if(actual[r]!=expected[r]) throw std::runtime_error("PL density mismatch at landmark "+std::to_string(r));
        std::ofstream binary(fs::path(argv[3])/("density-"+std::to_string(event+1)+".bin"),std::ios::binary);
        binary.write(reinterpret_cast<char*>(actual.data()),actual.size()*4);
        if(!binary) throw std::runtime_error("Could not save density output");
        const auto elapsed=counter(0x10);
        if(!elapsed || pl.read_register(0x24)!=74 || pl.read_register(0x20)!=648)
            throw std::runtime_error("Invalid completion/beat count");
        if(event) report<<",\n";
        report<<"{\"sequence\":"<<event+1<<",\"full_latency_pl_cycles\":"<<elapsed
              <<",\"verified_pl_density_counts\":128}";
        report.flush();
        std::cout<<"PASS sequence "<<event+1<<": "<<elapsed<<" PL cycles; all 128 accumulated densities exact"<<std::endl;
    }
    report<<"\n],\"status\":\"passed\"}\n";
    if(!report) throw std::runtime_error("Could not save report");
    return 0;
 } catch(const std::exception &error) { std::cerr<<error.what()<<std::endl;return 1; }
}

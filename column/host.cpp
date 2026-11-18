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
namespace fs=std::filesystem;

static std::vector<uint32_t> words(const fs::path& path) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if(!file) throw std::runtime_error("Cannot open "+path.string());
    const auto length=file.tellg();
    if(length<=0 || size_t(length)%4) throw std::runtime_error("Invalid word file "+path.string());
    std::vector<uint32_t> data(size_t(length)/4);file.seekg(0);
    if(!file.read(reinterpret_cast<char*>(data.data()),length)) throw std::runtime_error("Short fixture read");
    return data;
}
static void save(const fs::path& path,const std::vector<uint32_t>& data) {
    std::ofstream file(path,std::ios::binary);
    file.write(reinterpret_cast<const char*>(data.data()),data.size()*4);
    if(!file) throw std::runtime_error("Cannot save "+path.string());
}

int main(int argc,char** argv) {
 try {
    if(argc!=6) throw std::runtime_error("Usage: column_host design.xclbin data config results tiles");
    const unsigned tiles=std::stoul(argv[5]);
    if(tiles!=1 && tiles!=2 && tiles!=4 && tiles!=8) throw std::runtime_error("Invalid tile count");
    auto frames=words(fs::path(argv[2])/"payloads.bin");
    if(frames.size()%576) throw std::runtime_error("Invalid compact column frames");
    auto headers=words(fs::path(argv[3])/"route_headers.bin");
    auto ids=words(fs::path(argv[3])/"output_ids.bin");
    if(headers.size()!=20 || ids.size()!=8) throw std::runtime_error("Invalid compiled packet map");
    fs::create_directories(argv[4]);
    const char* mode=std::getenv("XCL_EMULATION_MODE");
    if(mode && std::string(mode)!="hw_emu") throw std::runtime_error("Use hw_emu or unset XCL_EMULATION_MODE");
    std::ofstream report(fs::path(argv[4])/"events.json");
    report<<"{\"measurement\":\""<<(mode?mode:"physical_board")<<"\",\"tiles\":"<<tiles<<",\"events\":[\n";
    xrt::device device(0);
    auto uuid=device.load_xclbin(argv[1]);
    xrt::ip pl(device,uuid,"column_pl:{column_pl_1}");
    if(pl.read_register(0x34)!=0x434f4c31 || pl.read_register(0x38)!=645)
        throw std::runtime_error("Wrong column register map");
    uint64_t base=0;bool found=false;
    for(const auto& ip:xrt::xclbin(argv[1]).get_ips()) {
        if(ip.get_name()=="column_pl:column_pl_1") {
            base=ip.get_base_address();found=true;
            if(ip.get_size()<0x24000) throw std::runtime_error("Column aperture too small");
        }
    }
    if(!found) throw std::runtime_error("Column aperture absent");
    auto raw_device=static_cast<xclDeviceHandle>(device);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    const char* driver_name=mode?"libxrt_hwemu.so.2":"libxrt_core.so.2";
    auto closer=[](void* p){dlclose(p);};
    std::unique_ptr<void,decltype(closer)> driver(dlopen(driver_name,RTLD_NOW|RTLD_LOCAL),closer);
    if(!driver) throw std::runtime_error(dlerror());
    auto block_write=reinterpret_cast<decltype(&xclWrite)>(dlsym(driver.get(),"xclWrite"));
    auto block_read=reinterpret_cast<decltype(&xclRead)>(dlsym(driver.get(),"xclRead"));
    if(!block_write || !block_read) throw std::runtime_error("XRT block-access API unavailable");
    auto write_words=[&](unsigned offset,const uint32_t* data,unsigned count) {
        if(block_write(raw_device,XCL_ADDR_KERNEL_CTRL,base+offset,data,count*4)!=count*4)
            throw std::runtime_error("PL block write failed");
    };
    auto read_words=[&](unsigned offset,uint32_t* data,unsigned count) {
        if(block_read(raw_device,XCL_ADDR_KERNEL_CTRL,base+offset,data,count*4)!=count*4)
            throw std::runtime_error("PL block read failed");
    };
#pragma GCC diagnostic pop
    write_words(0x40,headers.data(),headers.size());
    write_words(0xa0,ids.data(),ids.size());
    pl.write_register(8,tiles);
    if(pl.read_register(8)!=tiles) throw std::runtime_error("Active count setup failed");
    for(unsigned event=0;event<frames.size()/576;++event) {
        const uint32_t* frame=frames.data()+event*576;
        std::vector<int8_t> coordinates(2304);std::memcpy(coordinates.data(),frame,2304);
        std::vector<uint32_t> expected_density(128),expected_distance(tiles*2560);
        for(unsigned h=0;h<tiles*20;++h) {
            for(unsigned r=0;r<128;++r) {
                int32_t squared=0;
                for(unsigned d=0;d<8;++d) {
                    const int32_t diff=int32_t(coordinates[h*8+d])-int32_t(coordinates[1280+r*8+d]);
                    squared+=diff*diff;
                }
                expected_distance[h*128+r]=squared;
                expected_density[r]+=squared<=645;
            }
        }
        pl.write_register(0,2);
        write_words(0x1000,frame,576);
        std::cout<<"Release column sequence "<<event+1<<", "<<tiles<<" tiles"<<std::endl;
        pl.write_register(0,1);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(10);
        uint32_t status;
        do {
            status=pl.read_register(4);
            if(status&8) throw std::runtime_error("Column protocol fault");
            if(std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Column completion timeout");
            if(!(status&4)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } while(!(status&4));
        if(!(status&2)) throw std::runtime_error("Missing timed density completion");
        const uint64_t cycles=uint64_t(pl.read_register(0x10))|(uint64_t(pl.read_register(0x14))<<32);
        if(pl.read_register(0x28)!=(1u<<tiles)-1 || pl.read_register(0x2c)!=(1u<<tiles)-1)
            throw std::runtime_error("Incomplete tile masks");
        if(pl.read_register(0x20)!=65+12*tiles || pl.read_register(0x24)!=650*tiles)
            throw std::runtime_error("Incorrect packet beat counts");
        std::vector<uint32_t> density(128),distance(tiles*2560);
        read_words(0x2000,density.data(),density.size());
        if(density!=expected_density) throw std::runtime_error("Accumulated landmark densities differ from CPU");
        // Hardware emulation already records every matrix word on the PL RX
        // stream. The CPU trace checker verifies these after simulation; avoid
        // 20,480 slow register transactions per eight-tile emulated event.
        if(!mode) {
            read_words(0x10000,distance.data(),distance.size());
            if(distance!=expected_distance) throw std::runtime_error("Per-tile distances differ from CPU");
            save(fs::path(argv[4])/("distances-"+std::to_string(event+1)+".bin"),distance);
        }
        const uint64_t after=uint64_t(pl.read_register(0x10))|(uint64_t(pl.read_register(0x14))<<32);
        if(cycles!=after) throw std::runtime_error("Timer advanced during untimed correctness readback");
        save(fs::path(argv[4])/("density-"+std::to_string(event+1)+".bin"),density);
        uint32_t total=0;for(auto count:density)total+=count;
        if(event) report<<",\n";
        report<<"{\"sequence\":"<<event+1<<",\"full_latency_pl_cycles\":"<<cycles
              <<",\"exact_distances\":"<<(mode?0:distance.size())<<",\"matrix_validation\":\""
              <<(mode?"pending_trace_check":"host_register_readback")<<"\",\"exact_pl_accumulated_densities\":128"
              <<",\"density_sum\":"<<total<<"}";
        report.flush();
        std::cout<<"PASS: "<<cycles<<" PL cycles, 128 exact accumulated densities; "
                 <<(mode?"matrix comparison pending trace check":"matrices checked")<<std::endl;
    }
    report<<"\n],\"status\":\"passed\"}\n";
    return 0;
 } catch(const std::exception& error) {
    std::cerr<<"ERROR: "<<error.what()<<std::endl;
    return 1;
 }
}

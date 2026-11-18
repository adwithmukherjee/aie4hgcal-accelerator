#include <xrt/xrt_device.h>
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xclhal2.h>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <sstream>
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
    if(argc!=6) throw std::runtime_error("Usage: array_host design.xclbin data config results columns");
    const unsigned columns=std::stoul(argv[5]);
    const unsigned tiles=columns*8;
    if(columns!=1 && columns!=2 && columns!=4) throw std::runtime_error("Invalid column count");
    auto frames=words(fs::path(argv[2])/"payloads.bin");
    if(frames.size()%1536) throw std::runtime_error("Invalid compact column frames");
    auto headers=words(fs::path(argv[3])/"route_headers.bin");
    auto ids=words(fs::path(argv[3])/"output_ids.bin");
    if(headers.size()!=17*columns || ids.size()!=8*columns) throw std::runtime_error("Invalid compiled packet map");
    fs::create_directories(argv[4]);
    const char* mode=std::getenv("XCL_EMULATION_MODE");
    if(mode && std::string(mode)!="hw_emu") throw std::runtime_error("Use hw_emu or unset XCL_EMULATION_MODE");
    std::ofstream report(fs::path(argv[4])/"events.json");
    report<<"{\"measurement\":\""<<(mode?mode:"physical_board")<<"\",\"columns\":"<<columns<<",\"events\":[\n";
    xrt::device device(0);
    auto uuid=device.load_xclbin(argv[1]);
    xrt::ip pl(device,uuid,"array_pl:{array_pl_1}");
    const auto signature=pl.read_register(0x34),radius=pl.read_register(0x38);
    if(signature!=0x41525231 || radius!=645) {
        std::ostringstream error;
        error<<"Wrong array register map: signature=0x"<<std::hex<<signature<<", radius=0x"<<radius;
        throw std::runtime_error(error.str());
    }
    uint64_t base=0;bool found=false;
    for(const auto& ip:xrt::xclbin(argv[1]).get_ips()) {
        if(ip.get_name()=="array_pl:array_pl_1") {
            base=ip.get_base_address();found=true;
            if(ip.get_size()<0x10000) throw std::runtime_error("Array aperture too small");
        }
    }
    if(!found) throw std::runtime_error("Array aperture absent");
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
    for(unsigned c=0;c<columns;++c) {
        write_words(0x440+c*0x100,headers.data()+c*17,17);
        write_words(0x4a0+c*0x100,ids.data()+c*8,8);
    }
    if(pl.read_register(8)!=columns) throw std::runtime_error("Compiled column count differs");
    for(unsigned event=0;event<frames.size()/1536;++event) {
        const uint32_t* frame=frames.data()+event*1536;
        std::vector<int8_t> coordinates(6144);std::memcpy(coordinates.data(),frame,6144);
        std::vector<uint32_t> expected_density(128),expected_distance(tiles*2560);
        for(unsigned h=0;h<tiles*20;++h) {
            for(unsigned r=0;r<128;++r) {
                int32_t squared=0;
                for(unsigned d=0;d<8;++d) {
                    const int32_t diff=int32_t(coordinates[h*8+d])-int32_t(coordinates[5120+r*8+d]);
                    squared+=diff*diff;
                }
                expected_distance[h*128+r]=squared;
                expected_density[r]+=squared<=645;
            }
        }
        pl.write_register(0,2);
        for(unsigned c=0;c<columns;++c) {
            std::vector<uint32_t> bank(576);
            std::memcpy(bank.data(),frame+c*320,1280);
            std::memcpy(bank.data()+320,frame+1280,1024);
            write_words(0x8000+c*0x1000,bank.data(),576);
        }
        std::cout<<"Release array sequence "<<event+1<<", "<<columns<<" columns"<<std::endl;
        pl.write_register(0,1);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(10);
        uint32_t status;
        do {
            status=pl.read_register(4);
            if(status&8) throw std::runtime_error("Array protocol fault");
            if(std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Array completion timeout");
            if(!(status&4)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } while(!(status&4));
        if(!(status&2)) throw std::runtime_error("Missing timed density completion");
        const uint64_t cycles=uint64_t(pl.read_register(0x10))|(uint64_t(pl.read_register(0x14))<<32);
        if(pl.read_register(0x28)!=(1u<<columns)-1 || pl.read_register(0x2c)!=(1u<<columns)-1)
            throw std::runtime_error("Incomplete tile masks");
        for(unsigned c=0;c<columns;++c) {
            const unsigned offset=0x400+c*0x100;
            if(pl.read_register(offset)!=161 || pl.read_register(offset+4)!=5200 ||
               pl.read_register(offset+8)!=255 || pl.read_register(offset+12)!=255)
                throw std::runtime_error("Incomplete column traffic or tile masks");
        }
        std::vector<uint32_t> density(128),distance(tiles*2560);
        read_words(0x2000,density.data(),density.size());
        if(density!=expected_density) throw std::runtime_error("Accumulated landmark densities differ from CPU");
        // Hardware emulation already records every matrix word on the PL RX
        // stream. The CPU trace checker verifies these after simulation; avoid
        // 20,480 slow register transactions per eight-tile emulated event.
        if(!mode) {
            for(unsigned tile=0;tile<tiles;++tile) {
                pl.write_register(0x3c,tile);
                read_words(0xc000,distance.data()+tile*2560,2560);
            }
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

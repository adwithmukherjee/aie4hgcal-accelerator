#include <xrt/xrt_device.h>
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xclhal2.h>
#include <chrono>
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
namespace fs=std::filesystem;
static std::vector<uint64_t> hex_words(const fs::path& path,size_t count) {
 std::ifstream f(path);if(!f) throw std::runtime_error("Cannot read "+path.string());
 std::vector<uint64_t> v;std::string s;
 while(f>>s) v.push_back(std::stoull(s,nullptr,16));
 if(v.size()!=count) throw std::runtime_error("Fixture length: "+path.string());
 return v;
}
static std::vector<uint32_t> binary_words(const fs::path& path,size_t count) {
 std::ifstream f(path,std::ios::binary|std::ios::ate);
 if(!f || f.tellg()!=std::streamoff(count*4)) throw std::runtime_error("Binary length: "+path.string());
 std::vector<uint32_t> v(count);f.seekg(0);
 if(!f.read(reinterpret_cast<char*>(v.data()),count*4)) throw std::runtime_error("Short fixture read");
 return v;
}
template<class T> static void save(const fs::path& path,const std::vector<T>& v) {
 std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(v.data()),v.size()*sizeof(T));
 if(!f) throw std::runtime_error("Cannot save "+path.string());
}
int main(int argc,char** argv) {
 try {
  if(argc!=5) throw std::runtime_error("Usage: kan_cluster_host design.xclbin data config results");
  const char* mode=std::getenv("XCL_EMULATION_MODE");
  if(!mode || std::string(mode)!="hw_emu") throw std::runtime_error("This qualification requires hw_emu");
  const bool sim_memory=std::getenv("KAN_CLUSTER_SIM_MEMORY") && std::string(std::getenv("KAN_CLUSTER_SIM_MEMORY"))=="1";
  const fs::path fixture=fs::path(argv[2])/"event-00187",config=argv[3],results=argv[4];
  auto raw=binary_words(fixture/"wire.bin",8000),roles=binary_words(fixture/"roles.bin",768);
  auto landmark_ids=binary_words(fixture/"landmark_ids.bin",128);
  auto expected=hex_words(fixture/"expected.mem",8000);
  auto headers=binary_words(config/"route_headers.bin",40),ids=binary_words(config/"output_ids.bin",32);
  fs::create_directories(results);
  xrt::device device(0);auto uuid=device.load_xclbin(argv[1]);
  xrt::ip ip(device,uuid,"kan_cluster_pl:{kan_cluster_pl_1}");
  if(ip.read_register(0x34)!=0x4b434c31 || ip.read_register(8)!=64 || ip.read_register(12)!=8000)
   throw std::runtime_error("Wrong integrated kernel identity");
  uint64_t base=0;bool found=false;
  for(const auto& k:xrt::xclbin(argv[1]).get_ips()) if(k.get_name()=="kan_cluster_pl:kan_cluster_pl_1") {
   if(k.get_size()<0x40000) throw std::runtime_error("Integrated aperture too small");
   base=k.get_base_address();found=true;
  }
  if(!found) throw std::runtime_error("Missing integrated kernel aperture");
  auto close=[](void* p){dlclose(p);};
  std::unique_ptr<void,decltype(close)> driver(dlopen("libxrt_hwemu.so.2",RTLD_NOW|RTLD_LOCAL),close);
  if(!driver) throw std::runtime_error(dlerror());
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto bw=reinterpret_cast<decltype(&xclWrite)>(dlsym(driver.get(),"xclWrite"));
  auto br=reinterpret_cast<decltype(&xclRead)>(dlsym(driver.get(),"xclRead"));
  if(!bw || !br) throw std::runtime_error("Missing block MMIO API");
  auto handle=static_cast<xclDeviceHandle>(device);
  auto write=[&](unsigned offset,const std::vector<uint32_t>& v,size_t start,size_t n) {
   if(bw(handle,XCL_ADDR_KERNEL_CTRL,base+offset,v.data()+start,n*4)!=n*4) throw std::runtime_error("MMIO load failed");
  };
  auto read=[&](unsigned offset,std::vector<uint32_t>& v) {
   if(br(handle,XCL_ADDR_KERNEL_CTRL,base+offset,v.data(),v.size()*4)!=v.size()*4) throw std::runtime_error("MMIO read failed");
  };
  ip.write_register(0,2);
  for(unsigned c=0;c<4;++c) {write(0x440+c*256,headers,c*10,10);write(0x4a0+c*256,ids,c*8,8);}
  write(0x3000,landmark_ids,0,128);write(0x20000,roles,0,768);
  if(sim_memory) {
   // One real AXI write triggers simulator deposits into the resident raw FFs.
   // This changes setup wall time only; every operation after release is RTL/AIE.
   ip.write_register(0x8000,raw[0]);
   if(ip.read_register(0x1c)!=8000) throw std::runtime_error("Simulator raw setup did not complete");
  } else write(0x8000,raw,0,8000);
  if(ip.read_register(0x1c)!=8000 || ip.read_register(0x20)!=768 || (ip.read_register(4)&8))
   throw std::runtime_error("Incomplete or invalid raw/role load");
  std::ofstream report(results/"events.json");
  report<<"{\"measurement\":\"VCK5000 hw_emu; resident raw register release to final AIE label capture\","
        <<"\"setup_readback\":\""<<(sim_memory?"simulator_memory_with_AXI_spot_checks":"full_AXI_MMIO")<<"\","
        <<"\"lanes\":64,\"raw_hits\":8000,\"aie_hits\":640,\"aie_tiles\":32,\"events\":[\n";
  for(unsigned trial=0;trial<2;++trial) {
   auto cluster=hex_words(fixture/(trial?"cluster_forced.mem":"cluster_normal.mem"),370);
   ip.write_register(0x40,trial);std::cout<<"Release event 187 mode="<<(trial?"force64":"normal")<<std::endl;
   ip.write_register(0,1);
   auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(30);
   unsigned status;
   do {
    status=ip.read_register(4);
    if(status&8) throw std::runtime_error("Integrated protocol fault");
    if(std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Integrated completion timeout");
    if(!(status&4)) std::this_thread::sleep_for(std::chrono::milliseconds(10));
   } while(!(status&4));
   if((status&0x7f)!=0x76 || ip.read_register(0x24)!=8000 || ip.read_register(0x18)!=137 ||
      ip.read_register(0x28)!=15 || ip.read_register(0x2c)!=15) throw std::runtime_error("Bad integrated final status/counters");
   uint64_t cycles=uint64_t(ip.read_register(0x10))|(uint64_t(ip.read_register(0x14))<<32);
   const unsigned seeds=cluster[128],overflow=cluster[129];
   if(ip.read_register(0x3c)!=(seeds|(overflow<<7))) throw std::runtime_error("Seed count/overflow mismatch");
   std::vector<uint32_t> density(128),slots(16),seed_ids(64),labels(160);
   read(0x2000,density);read(0x2400,slots);read(0x2500,seed_ids);read(0x1000,labels);
   auto check=[&](const std::vector<uint32_t>& v,unsigned offset,const char* what) {
    for(unsigned i=0;i<v.size();++i) if(v[i]!=cluster[offset+i]) throw std::runtime_error(std::string(what)+" mismatch at "+std::to_string(i));
   };
   check(density,0,"density");check(slots,130,"seed slot");check(seed_ids,146,"seed ID");check(labels,210,"label");
   std::vector<uint64_t> embeddings(8000);
   if(sim_memory) {
    embeddings=hex_words(results/("capture-"+std::to_string(trial)+".mem"),8000);
    for(unsigned i:{0u,1u,63u,64u,127u,128u,767u,768u,7999u}) {
     uint64_t value=0;
     if(br(handle,XCL_ADDR_KERNEL_CTRL,base+0x10000+i*8,&value,8)!=8 || value!=embeddings[i])
      throw std::runtime_error("AXI capture spot check differs from simulator RAM read");
    }
   } else if(br(handle,XCL_ADDR_KERNEL_CTRL,base+0x10000,embeddings.data(),8000*8)!=8000*8) throw std::runtime_error("Embedding readback failed");
   if(embeddings!=expected) throw std::runtime_error("Full-event embedding mismatch");
   save(results/("embeddings-"+std::to_string(trial)+".bin"),embeddings);
   save(results/("labels-"+std::to_string(trial)+".bin"),labels);
   save(results/("density-"+std::to_string(trial)+".bin"),density);
   if(trial) report<<",\n";
   report<<"{\"trial\":"<<trial<<",\"event\":187,\"force64\":"<<(trial?"true":"false")
         <<",\"encoder_cycles\":137,\"final_cycles\":"<<cycles<<",\"seeds\":"<<seeds
         <<",\"verified_embeddings\":8000,\"verified_labels\":640}";report.flush();
   std::cout<<"PASS integrated trial="<<trial<<" cycles="<<cycles<<" encoder=137 seeds="<<seeds<<" embeddings=8000 labels=640"<<std::endl;
  }
#pragma GCC diagnostic pop
  report<<"\n]}\n";report.close();
  std::cout<<"PASS: integrated raw KAN and AIE clustering"<<std::endl;
  return 0;
 } catch(const std::exception& e) {std::cerr<<e.what()<<std::endl;return 1;}
}

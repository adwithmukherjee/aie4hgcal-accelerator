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
static std::vector<uint64_t> words(const fs::path& path) {
 std::ifstream f(path);if(!f) throw std::runtime_error("Cannot read "+path.string());
 std::vector<uint64_t> v;std::string s;
 while(f>>s) v.push_back(std::stoull(s,nullptr,16));
 if(v.size()!=8000) throw std::runtime_error("Expected 8000 fixture words");
 return v;
}
int main(int argc,char** argv) {
 try {
  if(argc!=5) throw std::runtime_error("Usage: kan_host kernel.xclbin generated results lanes");
  const char* mode=std::getenv("XCL_EMULATION_MODE");
  if(!mode || std::string(mode)!="hw_emu") throw std::runtime_error("This qualification host requires hw_emu");
  unsigned lanes=std::stoul(argv[4]);
  auto input=words(fs::path(argv[2])/"wire.mem"),expected=words(fs::path(argv[2])/"expected.mem");
  std::vector<uint32_t> raw;for(auto x:input) raw.push_back(uint32_t(x));
  fs::create_directories(argv[3]);
  xrt::device device(0);auto uuid=device.load_xclbin(argv[1]);
  xrt::ip ip(device,uuid,"kan_pl:{kan_pl_1}");
  if(ip.read_register(44)!=0x4b414e31 || ip.read_register(8)!=lanes) throw std::runtime_error("Kernel identity");
  uint64_t base=0;bool found=false;
  for(const auto& k:xrt::xclbin(argv[1]).get_ips()) if(k.get_name()=="kan_pl:kan_pl_1") {
   if(k.get_size()<0x20000) throw std::runtime_error("Aperture too small");
   base=k.get_base_address();found=true;
  }
  if(!found) throw std::runtime_error("Missing kernel aperture");
  auto close=[](void* p){dlclose(p);};
  std::unique_ptr<void,decltype(close)> driver(dlopen("libxrt_hwemu.so.2",RTLD_NOW|RTLD_LOCAL),close);
  if(!driver) throw std::runtime_error(dlerror());
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto bw=reinterpret_cast<decltype(&xclWrite)>(dlsym(driver.get(),"xclWrite"));
  auto br=reinterpret_cast<decltype(&xclRead)>(dlsym(driver.get(),"xclRead"));
  if(!bw || !br) throw std::runtime_error("Missing block MMIO API");
  auto handle=static_cast<xclDeviceHandle>(device);
  ip.write_register(0,2);
  if(bw(handle,XCL_ADDR_KERNEL_CTRL,base+0x8000,raw.data(),raw.size()*4)!=raw.size()*4)
   throw std::runtime_error("Raw register load failed");
  if(ip.read_register(16)!=8000) throw std::runtime_error("Loaded count mismatch");
  std::ofstream report(fs::path(argv[3])/"events.json");
  report<<"{\"measurement\":\"VCK5000 hw_emu; resident raw registers to final capture write\",\"lanes\":"<<lanes<<",\"events\":[\n";
  const unsigned counts[]={33,8000,8000,7};
  for(unsigned trial=0;trial<4;++trial) {
   unsigned n=counts[trial],period=trial==2?8:0;
   ip.write_register(12,n);ip.write_register(40,period);ip.write_register(0,1);
   auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(20);
   unsigned status=0;
   while(!((status=ip.read_register(4))&2)) {
    if(status&4) throw std::runtime_error("Kernel fault");
    if(std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Completion timeout");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
   }
   if(status!=2) throw std::runtime_error("Bad final status");
   unsigned cycles=ip.read_register(20),first=ip.read_register(24),stalls=ip.read_register(32);
   unsigned captured=ip.read_register(28),groups=ip.read_register(36),read_stages=2;
   if(captured!=n || groups!=(n+lanes-1)/lanes || first!=read_stages+11 ||
      cycles!=(n+lanes-1)/lanes+read_stages+10+stalls || (!period && stalls))
    throw std::runtime_error("Counter/timing endpoint mismatch");
   std::vector<uint64_t> out(n);
   if(br(handle,XCL_ADDR_KERNEL_CTRL,base+0x10000,out.data(),n*8)!=n*8)
    throw std::runtime_error("Capture readback failed");
   for(unsigned i=0;i<n;++i) if(out[i]!=expected[i]) throw std::runtime_error("Embedding mismatch at hit "+std::to_string(i));
   std::ofstream dump(fs::path(argv[3])/("embeddings-"+std::to_string(trial)+".bin"),std::ios::binary);
   dump.write(reinterpret_cast<const char*>(out.data()),n*8);
   if(!dump) throw std::runtime_error("Cannot save embeddings");
   if(trial) report<<",\n";
   report<<"{\"trial\":"<<trial<<",\"hits\":"<<n<<",\"first_cycles\":"<<first<<",\"final_cycles\":"<<cycles<<",\"stall_cycles\":"<<stalls<<",\"groups\":"<<groups<<",\"verified_embeddings\":"<<n<<"}";
   report.flush();
   std::cout<<"PASS event lanes="<<lanes<<" hits="<<n<<" first="<<first<<" final="<<cycles<<" stalls="<<stalls<<std::endl;
  }
#pragma GCC diagnostic pop
  report<<"\n]}\n";report.close();
  std::cout<<"PASS: integrated KAN PL hardware emulation lanes="<<lanes<<std::endl;
  return 0;
 } catch(const std::exception& e) {std::cerr<<e.what()<<std::endl;return 1;}
}

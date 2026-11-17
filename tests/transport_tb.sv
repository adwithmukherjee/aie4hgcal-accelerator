`timescale 1ns/1ps
module transport_tb;
 reg clk=0, resetn=0;
 always #5 clk=~clk;
 reg [15:0] awaddr=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg [31:0] wdata=0; reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;
 wire [1:0] bresp,rresp; wire [31:0] rdata;
 wire [127:0] txdata; wire [15:0] txkeep; wire txvalid,txlast;
 reg txready=0; reg [127:0] rxdata=0; reg rxvalid=0;
 wire rxready;
 transport_pl dut(.ap_clk(clk),.ap_rst_n(resetn),
 .s_axi_control_awaddr(awaddr),.s_axi_control_awvalid(awvalid),.s_axi_control_awready(awready),
 .s_axi_control_wdata(wdata),.s_axi_control_wstrb(wstrb),.s_axi_control_wvalid(wvalid),.s_axi_control_wready(wready),
 .s_axi_control_bresp(bresp),.s_axi_control_bvalid(bvalid),.s_axi_control_bready(bready),
 .s_axi_control_araddr(araddr),.s_axi_control_arvalid(arvalid),.s_axi_control_arready(arready),
 .s_axi_control_rdata(rdata),.s_axi_control_rresp(rresp),.s_axi_control_rvalid(rvalid),.s_axi_control_rready(rready),
 .m_axis_tx_tdata(txdata),.m_axis_tx_tkeep(txkeep),.m_axis_tx_tlast(txlast),.m_axis_tx_tvalid(txvalid),.m_axis_tx_tready(txready),
 .s_axis_rx_tdata(rxdata),.s_axis_rx_tkeep(16'hffff),.s_axis_rx_tlast(1'b0),.s_axis_rx_tvalid(rxvalid),.s_axis_rx_tready(rxready));
 reg [31:0] frames[0:1183],golden[0:10367],received[0:295],sums[0:127];
 string path,input_path,golden_path;
 integer input_file,golden_file;
 integer tick=0,words_received=0,rx_beats=0;
 time release_time,finish_time;
 reg held=0; reg [127:0] held_data;
 always @(posedge dut.release_strobe) begin
  release_time=$time;words_received=0;rx_beats=0;
 end
 always @(posedge clk) if(resetn) begin
  tick=tick+1;
  if(held && (!txvalid || txdata!==held_data)) $fatal(1,"AXIS changed under backpressure");
  held=txvalid&&!txready;held_data=txdata;
  if(txvalid&&txready) begin
   if(txkeep!==16'hffff || txlast!==(words_received==292)) $fatal(1,"Invalid input sidebands");
   for(integer k=0;k<4;k=k+1) received[words_received+k]=txdata[k*32+:32];
   words_received=words_received+4;
  end
  if(rxvalid&&rxready) begin
   rx_beats=rx_beats+1;
   if(rx_beats==8) finish_time=$time;
  end
 end
 always @(negedge clk) txready=(tick%7!=1 && tick%7!=2);
 task automatic write_reg(input [15:0] address,input [31:0] value,input bit bad=0);
 begin
  // Exercise independent AXI address/data arrival and delayed responses.
  @(negedge clk);awaddr=address;awvalid=1;
  do @(posedge clk); while(!awready);
  @(negedge clk);awvalid=0;
  repeat(2) @(negedge clk);
  wdata=value;wvalid=1;
  do @(posedge clk); while(!wready);
  @(negedge clk);wvalid=0;
  wait(bvalid);repeat(2) @(negedge clk);
  if(bresp!==(bad?2'b10:2'b00)) $fatal(1,"Unexpected AXI write response");
  bready=1;@(negedge clk);bready=0;
 end
 endtask
 task automatic read_reg(input [15:0] address,output [31:0] value);
 reg [31:0] stable;
 begin
  @(negedge clk);araddr=address;arvalid=1;
  do @(posedge clk);while(!arready);
  @(negedge clk);arvalid=0;
  wait(rvalid);stable=rdata;repeat(2) @(negedge clk);
  if(rdata!==stable || !rvalid) $fatal(1,"AXI read changed under backpressure");
  value=rdata;rready=1;@(negedge clk);rready=0;
 end
 endtask
 task automatic send_beat(input [127:0] value);
 begin
  @(negedge clk);rxdata=value;rxvalid=1;
  do @(posedge clk);while(!rxready);
  @(negedge clk);rxvalid=0;
 end
 endtask
 reg [31:0] value,timed_cycles;
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA is required");
  input_path={path,"/payloads.mem"};golden_path={path,"/expected.mem"};
  input_file=$fopen(input_path,"r");golden_file=$fopen(golden_path,"r");
  if(!input_file || !golden_file) $fatal(1,"Missing input/reference files");
  $fclose(input_file);$fclose(golden_file);
  $readmemh(input_path,frames);$readmemh(golden_path,golden);
  for(integer j=0;j<1184;j=j+1) if(^frames[j]===1'bx) $fatal(1,"Uninitialized fixture word");
  for(integer j=0;j<10368;j=j+1) if(^golden[j]===1'bx) $fatal(1,"Uninitialized reference word");
  repeat(5) @(negedge clk);resetn=1;
  write_reg(0,1,1);
  for(integer event_id=0;event_id<4;event_id=event_id+1) begin
   // Event 3 accumulates onto event 2, proving addition rather than overwrite.
   if(event_id!=2) begin
    write_reg(0,2);
    for(integer j=0;j<128;j=j+1) sums[j]=0;
   end
   for(integer j=0;j<128;j=j+1)
    sums[j]=sums[j]+((golden[event_id*2592+j/4]>>(8*(j%4)))&255);
   for(integer j=0;j<295;j=j+1) write_reg(16'h1000+4*j,frames[event_id*296+j]);
   wstrb=7;write_reg(16'h149c,frames[event_id*296+295]);wstrb=15;
   write_reg(0,1,1);
   if(dut.busy) $fatal(1,"Partially loaded input was released");
   write_reg(16'h149c,frames[event_id*296+295]);
   write_reg(0,1);
   write_reg(16'h1000,32'hbadbad00,1);
   wait(words_received==296);
   for(integer j=0;j<296;j=j+1)
    if(received[j]!==frames[event_id*296+j]) $fatal(1,"TX payload mismatch");
   repeat(17) @(negedge clk); // Fake compute latency, never a reported measurement.
   for(integer j=0;j<8;j=j+1)
    send_beat({golden[event_id*2592+j*4+3],golden[event_id*2592+j*4+2],golden[event_id*2592+j*4+1],golden[event_id*2592+j*4]});
   if(!dut.density_done) $fatal(1,"Density completion missing");
   read_reg(16'h10,timed_cycles);
   if(timed_cycles!==(finish_time-release_time)/10) $fatal(1,"Timer endpoint mismatch");
   for(integer j=0;j<128;j=j+1) begin
    read_reg(16'h5000+4*j,value);
    if(value!==sums[j]) $fatal(1,"PL accumulation mismatch at landmark %0d",j);
   end
   repeat(37) @(negedge clk);
   for(integer j=8;j<648;j=j+1)
    send_beat({golden[event_id*2592+j*4+3],golden[event_id*2592+j*4+2],golden[event_id*2592+j*4+1],golden[event_id*2592+j*4]});
   read_reg(4,value);if(value!==14) $fatal(1,"Completion status mismatch");
   read_reg(16'h10,value);if(value!==timed_cycles) $fatal(1,"Readback changed timer");
   read_reg(16'h20,value);if(value!==648) $fatal(1,"RX count mismatch");
   read_reg(16'h24,value);if(value!==74) $fatal(1,"TX count mismatch");
   for(integer j=0;j<2560;j=j+1) begin
    read_reg(16'h2000+4*j,value);
    if(value!==golden[event_id*2592+32+j]) $fatal(1,"Distance readback mismatch");
   end
   write_reg(0,1,1);
  end
  $display("PASS: four real events, exact densities/distances, nonzero accumulation, frozen full-stage timer, backpressure and load guards");
  $finish;
 end
 initial begin #5000000;$fatal(1,"Testbench timeout");end
endmodule

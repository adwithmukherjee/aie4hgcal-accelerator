`timescale 1ns/1ps
module column_tb;
 reg clk=0, resetn=0;
 always #5 clk=~clk;
 reg [17:0] awaddr=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg [31:0] wdata=0; reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;
 wire [1:0] bresp,rresp; wire [31:0] rdata;
 wire [127:0] txdata; wire [15:0] txkeep; wire txvalid,txlast;
 reg txready=0; reg [127:0] rxdata=0; reg rxvalid=0;
 wire rxready;
 reg [15:0] rxkeep=0; reg rxlast=0;
 column_pl dut(.ap_clk(clk),.ap_rst_n(resetn),
 .s_axi_control_awaddr(awaddr),.s_axi_control_awvalid(awvalid),.s_axi_control_awready(awready),
 .s_axi_control_wdata(wdata),.s_axi_control_wstrb(wstrb),.s_axi_control_wvalid(wvalid),.s_axi_control_wready(wready),
 .s_axi_control_bresp(bresp),.s_axi_control_bvalid(bvalid),.s_axi_control_bready(bready),
 .s_axi_control_araddr(araddr),.s_axi_control_arvalid(arvalid),.s_axi_control_arready(arready),
 .s_axi_control_rdata(rdata),.s_axi_control_rresp(rresp),.s_axi_control_rvalid(rvalid),.s_axi_control_rready(rready),
 .m_axis_tx_tdata(txdata),.m_axis_tx_tkeep(txkeep),.m_axis_tx_tlast(txlast),.m_axis_tx_tvalid(txvalid),.m_axis_tx_tready(txready),
 .s_axis_rx_tdata(rxdata),.s_axis_rx_tkeep(rxkeep),.s_axis_rx_tlast(rxlast),.s_axis_rx_tvalid(rxvalid),.s_axis_rx_tready(rxready));
 task automatic write_reg(input [17:0] address,input [31:0] value,input bit bad=0);
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
 reg [31:0] frames[0:2303],golden[0:82943],sums[0:127];
 reg [31:0] headers[0:19];
 integer tiles=1,current_frame=0,tick=0;
 integer phase=0,tx_row=0,packet_word=0,controls=0;
 bit inputs_done=0,held=0;
 reg [144:0] held_beat;
 time release_time,finish_time;
 reg [8191:0] path;
 reg [8191:0] input_path, expected_path;

 function automatic [31:0] header(input integer id,input integer kind);
 reg [31:0] v;
 begin
  v=(id&31)|(kind<<12)|(31<<16)|(127<<21);
  v[31]=~^v[30:0];header=v;
 end
 endfunction
 function automatic integer group_for(input integer count);
 begin case(count) 1:group_for=0;2:group_for=1;4:group_for=2;default:group_for=3;endcase end
 endfunction

 always @(posedge dut.release_strobe) begin
  release_time=$time;phase=0;tx_row=0;packet_word=0;controls=0;inputs_done=0;
 end
 always @(posedge dut.density_done) finish_time=$time;
 always @(negedge clk) txready=(tick%7!=1 && tick%7!=2);
 always @(posedge clk) if(resetn) begin: check_tx
  integer count,offset,expected_length,route;
  tick=tick+1;
  if(held && (!txvalid || {txlast,txkeep,txdata}!==held_beat)) $fatal(1,"TX changed under backpressure");
  held=txvalid&&!txready;held_beat={txlast,txkeep,txdata};
  if(txvalid&&txready) begin
   count=0;
   case(phase)
    0:begin expected_length=257;route=8+group_for(tiles);end
    1:begin expected_length=41;route=tx_row;end
    2:begin expected_length=1;route=12+tx_row;end
    default:$fatal(1,"Unexpected extra input packet");
   endcase
   if(phase==2 && !dut.density_done) $fatal(1,"Readback requested inside timing window");
   for(integer k=0;k<4;k=k+1) begin
    if(txkeep[k*4+:4]==15) begin
     if(packet_word+count==0) begin
      if(txdata[k*32+:32]!==headers[route]) $fatal(1,"Wrong routed header");
     end else begin
      offset=(phase==0?320:tx_row*40)+packet_word+count-1;
      if(txdata[k*32+:32]!==frames[current_frame*576+offset]) $fatal(1,"Wrong input payload");
     end
     count=count+1;
    end else if(txkeep[k*4+:4]!=0) $fatal(1,"Partial word TKEEP");
   end
   if(count==0 || txkeep!==((17'b1<<(count*4))-1)) $fatal(1,"Noncontiguous TKEEP");
   if(txlast!==(packet_word+count==expected_length)) $fatal(1,"Wrong packet length/TLAST");
   packet_word=packet_word+count;
   if(txlast) begin
    packet_word=0;
    if(phase==0) begin phase=1;tx_row=0;end
    else if(phase==1) begin
     if(tx_row==tiles-1) begin phase=2;tx_row=0;inputs_done=1;end
     else tx_row=tx_row+1;
    end else begin
     controls=controls+1;
     if(tx_row==tiles-1) phase=3;else tx_row=tx_row+1;
    end
   end
  end
 end

 task automatic send_packet(input integer row,input integer kind);
 integer length,count,offset,base;
 reg [127:0] beat;
 reg [15:0] keep;
 begin
  length=(kind==0?33:2561);
  base=(current_frame*8+row)*2592+(kind==0?0:32);
  for(offset=0;offset<length;offset=offset+4) begin
   beat=0;keep=0;count=0;
   for(integer k=0;k<4;k=k+1) begin
    if(offset+k<length) begin
     keep[k*4+:4]=15;count=count+1;
     beat[k*32+:32]=(offset+k==0 ? header((row*3+1)%32,kind) : golden[base+offset+k-1]);
    end
   end
   if(offset%28==0) repeat(3) @(negedge clk);
   @(negedge clk);rxdata=beat;rxkeep=keep;rxlast=(offset+count==length);rxvalid=1;
   do @(posedge clk);while(!rxready);
   @(negedge clk);rxvalid=0;
  end
 end
 endtask

 reg [31:0] value,timed_cycles;
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA required");
  $sformat(input_path,"%0s/payloads.mem",path);
  $sformat(expected_path,"%0s/expected.mem",path);
  $readmemh(input_path,frames);
  $readmemh(expected_path,golden);
  for(integer j=0;j<2304;j=j+1) if(^frames[j]===1'bx) $fatal(1,"Missing input word");
  for(integer j=0;j<82944;j=j+1) if(^golden[j]===1'bx) $fatal(1,"Missing reference word");
  repeat(5) @(negedge clk);resetn=1;
  write_reg(0,1,1);
  for(integer j=0;j<20;j=j+1) begin
   headers[j]=header((j*7+3)%32,j>=12?2:0);
   write_reg(18'h40+j*4,headers[j]);
  end
  for(integer j=0;j<8;j=j+1) write_reg(18'ha0+j*4,(j*3+1)%32);
  for(integer trial=0;trial<8;trial=trial+1) begin
   tiles=1<<(trial/2);current_frame=trial%4;
   write_reg(8,tiles);
   if(trial!=2) begin
    write_reg(0,2);
    for(integer j=0;j<128;j=j+1) sums[j]=0;
   end
   for(integer row=0;row<tiles;row=row+1)
    for(integer j=0;j<128;j=j+1)
     sums[j]=sums[j]+((golden[(current_frame*8+row)*2592+j/4]>>(8*(j%4)))&255);
   for(integer j=0;j<575;j=j+1) write_reg(18'h1000+j*4,frames[current_frame*576+j]);
   wstrb=7;write_reg(18'h18fc,frames[current_frame*576+575]);wstrb=15;
   write_reg(0,1,1);
   if(dut.busy) $fatal(1,"Incomplete input released");
   write_reg(18'h18fc,frames[current_frame*576+575]);
   write_reg(0,1);
   write_reg(18'h1000,32'hbadbad00,1);
   wait(inputs_done);
   repeat(17) @(negedge clk); // Simulated response delay, never benchmark timing.
   for(integer row=tiles-1;row>=0;row=row-1) begin
    send_packet(row,0); // Deliberately return contributions out of tile order.
    if(row!=0 && dut.density_done) $fatal(1,"Timer stopped before all contributions");
   end
   if(!dut.density_done) $fatal(1,"Missing global density completion");
   read_reg(18'h10,timed_cycles);
   if(timed_cycles!==(finish_time-release_time)/10) $fatal(1,"Full-stage timer endpoint mismatch");
   for(integer j=0;j<128;j=j+1) begin
    read_reg(18'h2000+4*j,value);
    if(value!==sums[j]) $fatal(1,"Density accumulation mismatch at %0d",j);
   end
   wait(controls==tiles);
   repeat(37) @(negedge clk);
   for(integer row=0;row<tiles;row=row+1) send_packet(row,1);
   read_reg(4,value);if(value!==14) $fatal(1,"Completion/guard status mismatch");
   read_reg(18'h10,value);if(value!==timed_cycles) $fatal(1,"Readback changed timer");
   read_reg(18'h20,value);if(value!==65+12*tiles) $fatal(1,"TX beat mismatch");
   read_reg(18'h24,value);if(value!==650*tiles) $fatal(1,"RX beat mismatch");
   for(integer row=0;row<tiles;row=row+1)
    for(integer j=0;j<2560;j=j+1) begin
     read_reg(18'h10000+(row*2560+j)*4,value);
     if(value!==golden[(current_frame*8+row)*2592+32+j]) $fatal(1,"Matrix readback mismatch row %0d word %0d",row,j);
    end
   $display("PASS column RTL: %0d tiles, event fixture %0d",tiles,current_frame);
  end
  $display("PASS: column packet routing, out-of-order density accumulation, frozen timer, matrix readback, backpressure, nonzero sums and load guards");
  $finish;
 end
 initial begin #20000000;$fatal(1,"Testbench timeout");end
 task automatic read_reg(input [17:0] address,output [31:0] value);
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
endmodule

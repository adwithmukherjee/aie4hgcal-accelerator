`timescale 1ns/1ps
`ifndef TEST_COLUMNS
`define TEST_COLUMNS 4
`endif
module array_tb;
 localparam C=`TEST_COLUMNS;
 reg clk=0,resetn=0;
 always #5 clk=~clk;
 reg [15:0] awaddr=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg [31:0] wdata=0;reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;
 wire [1:0] bresp,rresp;wire [31:0] rdata;
 wire [C*128-1:0] txdata;wire [C*16-1:0] txkeep;wire [C-1:0] txvalid,txlast;
 reg [C-1:0] txready=0,rxvalid=0,rxlast=0;
 reg [C*128-1:0] rxdata=0;reg [C*16-1:0] rxkeep=0;
 wire [C-1:0] rxready;
 array_control #(.COLUMNS(C)) dut(.ap_clk(clk),.ap_rst_n(resetn),
 .s_axi_control_awaddr(awaddr),.s_axi_control_awvalid(awvalid),.s_axi_control_awready(awready),
 .s_axi_control_wdata(wdata),.s_axi_control_wstrb(wstrb),.s_axi_control_wvalid(wvalid),.s_axi_control_wready(wready),
 .s_axi_control_bresp(bresp),.s_axi_control_bvalid(bvalid),.s_axi_control_bready(bready),
 .s_axi_control_araddr(araddr),.s_axi_control_arvalid(arvalid),.s_axi_control_arready(arready),
 .s_axi_control_rdata(rdata),.s_axi_control_rresp(rresp),.s_axi_control_rvalid(rvalid),.s_axi_control_rready(rready),
 .tx_data(txdata),.tx_keep(txkeep),.tx_last(txlast),.tx_valid(txvalid),.tx_ready(txready),
 .rx_data(rxdata),.rx_keep(rxkeep),.rx_last(rxlast),.rx_valid(rxvalid),.rx_ready(rxready));
 reg [31:0] frames[0:6143],golden[0:331775],sums[0:127],column_sums[0:C*128-1];
 reg [31:0] headers[0:C*10-1];
 reg [31:0] expected_cluster[0:1479],landmark_ids[0:511];
 integer current_frame=0,tick=0;
 integer phase[0:C-1],tx_row[0:C-1],packet_word[0:C-1],controls[0:C-1];
 reg [C-1:0] inputs_done=0,held=0;
 reg [144:0] held_beat[0:C-1];
 time release_time,finish_time,last_column_time;
 reg [8191:0] path,input_path,expected_path;
 function automatic [31:0] header(input integer id,input integer kind);
 reg [31:0] v;
 begin v=(id&31)|(kind<<12)|(31<<16)|(127<<21);v[31]=~^v[30:0];header=v;end
 endfunction
 function automatic integer output_id(input integer col,input integer row);
 begin output_id=(row*3+1+col*5)%32;end
 endfunction
 task automatic write_reg(input [15:0] address,input [31:0] value,input bit bad=0);
 begin
  @(negedge clk);awaddr=address;awvalid=1;
  do @(posedge clk);while(!awready);
  @(negedge clk);awvalid=0;repeat(2) @(negedge clk);
  wdata=value;wvalid=1;do @(posedge clk);while(!wready);
  @(negedge clk);wvalid=0;wait(bvalid);repeat(2) @(negedge clk);
  if(bresp!==(bad?2'b10:2'b00)) $fatal(1,"Unexpected AXI write response at %h",address);
  bready=1;@(negedge clk);bready=0;
 end
 endtask
 task automatic read_reg(input [15:0] address,output [31:0] value);
 reg [31:0] stable;
 begin
  @(negedge clk);araddr=address;arvalid=1;do @(posedge clk);while(!arready);
  @(negedge clk);arvalid=0;wait(rvalid);stable=rdata;repeat(2) @(negedge clk);
  if(rdata!==stable || !rvalid) $fatal(1,"AXI read response changed under backpressure");
  value=rdata;rready=1;@(negedge clk);rready=0;
 end
 endtask
 always @(posedge dut.release_strobe) begin
  release_time=$time;inputs_done=0;
  for(integer col=0;col<C;col=col+1) begin phase[col]=0;tx_row[col]=0;packet_word[col]=0;controls[col]=0;end
 end
 always @(dut.column_density_done) if(&dut.column_density_done) last_column_time=$time;
 always @(posedge dut.cluster_done) finish_time=$time;
 always @(posedge dut.density_done) begin
  if(($time-last_column_time)!==(C==4?20:10)) $fatal(1,"Wrong reduction pipeline depth");
 end
 always @(negedge clk) for(integer col=0;col<C;col=col+1)
  txready[col]=((tick+col*2)%7!=1 && (tick+col*2)%7!=2);
 always @(posedge clk) if(resetn) begin: monitor
  integer count,offset,length,route;
  tick=tick+1;
  if(dut.cluster_done && !(&dut.column_labels_done)) $fatal(1,"Global timer ended before all columns");
  for(integer col=0;col<C;col=col+1) begin
   if(held[col] && (!txvalid[col] || {txlast[col],txkeep[col*16+:16],txdata[col*128+:128]}!==held_beat[col]))
    $fatal(1,"Column %0d TX changed under backpressure",col);
   held[col]=txvalid[col]&&!txready[col];held_beat[col]={txlast[col],txkeep[col*16+:16],txdata[col*128+:128]};
   if(txvalid[col]&&txready[col]) begin
    count=0;
    case(phase[col])
     0:begin length=257;route=8;end
     1:begin length=41;route=tx_row[col];end
     2:begin length=2+((expected_cluster[current_frame*370+128]+3)/4);route=9;end
     default:$fatal(1,"Unexpected extra packet");
    endcase
    if(phase[col]==2 && !dut.seeds_done) $fatal(1,"Seed packet before selection");
    for(integer k=0;k<4;k=k+1) begin
     if(txkeep[col*16+k*4+:4]==15) begin
      if(packet_word[col]+count==0) begin
       if(txdata[col*128+k*32+:32]!==headers[col*10+route]) $fatal(1,"Wrong column packet header");
      end else if(phase[col]==2) begin
       if(packet_word[col]+count==1) begin
        if(txdata[col*128+k*32+:32]!==expected_cluster[current_frame*370+128]) $fatal(1,"Wrong seed count broadcast");
       end else if(txdata[col*128+k*32+:32]!==expected_cluster[current_frame*370+130+packet_word[col]+count-2]) $fatal(1,"Wrong seed ID broadcast");
      end else begin
       offset=(phase[col]==0?1280:col*320+tx_row[col]*40)+packet_word[col]+count-1;
       if(txdata[col*128+k*32+:32]!==frames[current_frame*1536+offset]) $fatal(1,"Wrong distinct hit/common landmark payload");
      end
      count=count+1;
     end else if(txkeep[col*16+k*4+:4]!=0) $fatal(1,"Partial word TKEEP");
    end
    if(count==0 || txkeep[col*16+:16]!==((17'b1<<(count*4))-1)) $fatal(1,"Noncontiguous TKEEP");
    if(txlast[col]!==(packet_word[col]+count==length)) $fatal(1,"Packet length mismatch");
    packet_word[col]=packet_word[col]+count;
    if(txlast[col]) begin
     packet_word[col]=0;
     if(phase[col]==0) begin phase[col]=1;tx_row[col]=0;end
     else if(phase[col]==1) begin
      if(tx_row[col]==7) begin phase[col]=2;tx_row[col]=0;inputs_done[col]=1;end
      else tx_row[col]=tx_row[col]+1;
     end else begin
      controls[col]=controls[col]+1;
      phase[col]=3;
     end
    end
   end
  end
 end
 task automatic send_packet(input integer col,input integer row,input integer kind);
 integer length,count,offset,base;
 reg [127:0] beat;reg [15:0] keep;
 begin
  length=(kind==0?33:6);base=(kind==0?(current_frame*32+col*8+row)*2592:current_frame*370+210+(col*8+row)*5);
  for(offset=0;offset<length;offset=offset+4) begin
   beat=0;keep=0;count=0;
   for(integer k=0;k<4;k=k+1) if(offset+k<length) begin
    keep[k*4+:4]=15;count=count+1;
    beat[k*32+:32]=(offset+k==0?header(output_id(col,row),kind):(kind==0?golden[base+offset+k-1]:expected_cluster[base+offset+k-1]));
   end
   if(offset%28==0) repeat(3+col) @(negedge clk);
   @(negedge clk);rxdata[col*128+:128]=beat;rxkeep[col*16+:16]=keep;
   rxlast[col]=(offset+count==length);rxvalid[col]=1;
   do @(posedge clk);while(!rxready[col]);
   @(negedge clk);rxvalid[col]=0;
  end
 end
 endtask
 generate for(genvar col=0;col<C;col=col+1) begin: responders
  always @(posedge dut.release_strobe) begin
   @(negedge clk);wait(inputs_done[col]);
   repeat(17+col*43) @(negedge clk);
   for(integer row=7;row>=0;row=row-1) send_packet(col,row,0);
   wait(controls[col]==1);
   repeat(37+col*11) @(negedge clk);
   for(integer row=0;row<8;row=row+1) send_packet(col,row,2);
  end
 end endgenerate
 reg [31:0] value,timed_cycles;
 integer offset;
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA required");
  $sformat(input_path,"%0s/payloads.mem",path);$sformat(expected_path,"%0s/expected.mem",path);
  $readmemh(input_path,frames);$readmemh(expected_path,golden);
  $sformat(expected_path,"%0s/cluster_expected.mem",path);$readmemh(expected_path,expected_cluster);
  $sformat(expected_path,"%0s/landmark_ids.mem",path);$readmemh(expected_path,landmark_ids);
  for(integer j=0;j<6144;j=j+1) if(^frames[j]===1'bx) $fatal(1,"Missing input word");
  for(integer j=0;j<331776;j=j+1) if(^golden[j]===1'bx) $fatal(1,"Missing reference word");
  repeat(5) @(negedge clk);resetn=1;write_reg(0,1,1);
  for(integer col=0;col<C;col=col+1) begin
   for(integer j=0;j<10;j=j+1) begin
    headers[col*10+j]=header((j*7+3+col)%32,j>=9?2:0);
    write_reg(16'h440+col*256+j*4,headers[col*10+j]);
   end
   for(integer j=0;j<8;j=j+1) write_reg(16'h4a0+col*256+j*4,output_id(col,j));
  end
  for(integer trial=0;trial<2;trial=trial+1) begin
   current_frame=trial;
   if(trial==0) write_reg(0,2); // The next event must overwrite all old partial/final sums.
   for(integer j=0;j<128;j=j+1) sums[j]=0;
   for(integer col=0;col<C;col=col+1) begin
    for(integer j=0;j<128;j=j+1) begin
     column_sums[col*128+j]=0;
     for(integer row=0;row<8;row=row+1)
      column_sums[col*128+j]+=((golden[(current_frame*32+col*8+row)*2592+j/4]>>(8*(j%4)))&255);
     sums[j]+=column_sums[col*128+j];
    end
    for(integer j=0;j<576;j=j+1) begin
     offset=(j<320?col*320+j:1280+j-320);
     if(col==C-1 && j==575) wstrb=7;
     write_reg(16'h8000+col*4096+j*4,frames[current_frame*1536+offset]);
     wstrb=15;
    end
   end
   for(integer j=0;j<128;j=j+1) write_reg(16'h3000+j*4,landmark_ids[current_frame*128+j]);
   write_reg(0,1,1);if(dut.busy) $fatal(1,"Partially loaded array released");
   write_reg(16'h8000+(C-1)*4096+575*4,frames[current_frame*1536+1535]);
   write_reg(0,1);write_reg(16'h8000,32'hbadbad00,1);
   wait(dut.cluster_done);
   read_reg(16'h10,timed_cycles);
   if(timed_cycles!==(finish_time-release_time)/10) $fatal(1,"Global counter endpoint mismatch");
   for(integer j=0;j<128;j=j+1) begin
    read_reg(16'h2000+j*4,value);if(value!==sums[j]) $fatal(1,"Global sum mismatch landmark %0d",j);
    for(integer col=0;col<C;col=col+1) begin
     read_reg(16'h4000+col*1024+j*4,value);
     if(value!==column_sums[col*128+j]) $fatal(1,"Column sum mismatch");
    end
   end
   read_reg(4,value);if(value!==62) $fatal(1,"Completion/load-guard status mismatch: %h",value);
   read_reg(16'h3c,value);if(value!==expected_cluster[current_frame*370+128]) $fatal(1,"Seed metadata mismatch");
   for(integer j=0;j<16;j=j+1) begin
    read_reg(16'h2400+j*4,value);if(value!==expected_cluster[current_frame*370+130+j]) $fatal(1,"Seed slots mismatch");
   end
   for(integer j=0;j<64;j=j+1) begin
    read_reg(16'h2500+j*4,value);if(value!==expected_cluster[current_frame*370+146+j]) $fatal(1,"Seed hit identities mismatch");
   end
   for(integer j=0;j<160;j=j+1) begin
    read_reg(16'h1000+j*4,value);if(value!==expected_cluster[current_frame*370+210+j]) $fatal(1,"Original-order label mismatch");
   end
   for(integer col=0;col<C;col=col+1) begin
    read_reg(16'h400+col*256,value);if(value!==154) $fatal(1,"Column TX beat count");
    read_reg(16'h404+col*256,value);if(value!==88) $fatal(1,"Column RX beat count");
   end
   read_reg(16'h10,value);if(value!==timed_cycles) $fatal(1,"Timer changed during readback");
   $display("PASS array RTL: %0d columns, fixture %0d",C,trial);
  end
  $display("PASS: four-column clustering, seeds, identity table, labels, skew, reverse tile order, backpressure, load guards and exact timer boundaries");
  $finish;
 end
 initial begin #100000000;$fatal(1,"Testbench timeout");end
endmodule

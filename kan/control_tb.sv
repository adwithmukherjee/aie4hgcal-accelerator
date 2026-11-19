`timescale 1ns/1ps
`ifndef TEST_LANES
`define TEST_LANES 64
`endif
module control_tb;
 localparam P=`TEST_LANES;
 reg clk=0,rst_n=0;
 always #5 clk=~clk;
 reg [16:0] aw=0,ar=0;
 reg av=0,wv=0,br=0,arv=0,rr=0;
 wire awr,wr,bv,arr,rv;
 reg [31:0] wd=0;
 reg [3:0] st=15;
 wire [1:0] bp,rp;
 wire [31:0] rd;
 kan_control #(.LANES(P)) dut(clk,rst_n,aw,av,awr,wd,st,wv,wr,bp,bv,br,ar,arv,arr,rd,rp,rv,rr);
 reg [31:0] x[0:7999];reg [63:0] y[0:7999];
 integer i,trial,n,expected_cycles,reads;
 reg [31:0] value,lo,hi,latency,first,stalls;
 task write_reg(input [16:0] address,input [31:0] data,input integer skew,input [1:0] expected_response);
  begin
   @(negedge clk);aw=address;wd=data;av=1;wv=0;br=0;
   @(posedge clk);if(!awr) $fatal(1,"AW not ready");
   @(negedge clk);av=0;
   repeat(skew) @(negedge clk);
   wv=1;@(posedge clk);if(!wr) $fatal(1,"W not ready");
   @(negedge clk);wv=0;
   while(!bv) @(negedge clk);
   repeat(2) begin @(posedge clk);if(!bv || bp!==expected_response) $fatal(1,"write response");end
   @(negedge clk);br=1;
   @(posedge clk);@(negedge clk);br=0;
  end
 endtask
 task read_reg(input [16:0] address,output [31:0] data);
  begin
   @(negedge clk);ar=address;arv=1;rr=0;
   @(posedge clk);if(!arr) $fatal(1,"AR not ready");
   @(negedge clk);arv=0;ar=17'h1ffff;
   while(!rv) @(negedge clk);
   data=rd;
   repeat(2) begin @(posedge clk);if(!rv || rp!==0 || rd!==data) $fatal(1,"read response");end
   @(negedge clk);rr=1;@(posedge clk);@(negedge clk);rr=0;
  end
 endtask
 initial begin
  $readmemh("wire.mem",x);$readmemh("expected.mem",y);
  repeat(3) @(negedge clk);rst_n=1;
  read_reg(44,value);if(value!==32'h4b414e31) $fatal(1,"signature");
  read_reg(8,value);if(value!==P) $fatal(1,"lanes");
  write_reg(0,1,2,2); // Reject an unloaded/zero-count event.
  write_reg(0,2,0,0);
  for(i=0;i<8000;i=i+1) write_reg(17'h08000+i*4,x[i],i%3,0);
  read_reg(16,value);if(value!=8000) $fatal(1,"loaded count");
  for(trial=0;trial<4;trial=trial+1) begin
   case(trial) 0:n=33;1:n=8000;2:n=8000;3:n=7;endcase
   write_reg(12,n,0,0);write_reg(40,trial==2 ? 8 : 0,1,0);
   write_reg(0,1,2,0);
   reads=0;value=0;
   while(!(value&2)) begin read_reg(4,value);reads=reads+1;if(reads>1000) $fatal(1,"timeout");end
   if(value!=2) $fatal(1,"status fault/busy %h",value);
   read_reg(20,latency);read_reg(24,first);read_reg(32,stalls);
   read_reg(28,value);if(value!=n) $fatal(1,"captured count");
   read_reg(36,value);if(value!=(n+P-1)/P) $fatal(1,"groups");
   expected_cycles=(n+P-1)/P+12;
   if(latency!=expected_cycles+stalls || first!=13) $fatal(1,"timer boundary latency=%0d first=%0d stalls=%0d",latency,first,stalls);
   for(i=0;i<n;i=i+1) begin
    read_reg(17'h10000+i*8,lo);read_reg(17'h10004+i*8,hi);
    if({hi,lo}!==y[i]) $fatal(1,"capture mismatch hit=%0d",i);
   end
   $display("CONTROL lanes=%0d hits=%0d first_cycles=%0d final_cycles=%0d stalls=%0d",P,n,first,latency,stalls);
  end
  $display("PASS: AXI control and capture lanes=%0d",P);$finish;
 end
 initial begin #100000000;$fatal(1,"watchdog");end
endmodule

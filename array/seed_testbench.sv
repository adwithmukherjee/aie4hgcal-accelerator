`timescale 1ns/1ps
module seed_tb;
 reg clk=0,rst_n=0,start=0,force_64=0;always #5 clk=~clk;
 reg [4095:0] density,ids;reg [8191:0] landmarks;
 wire done,overflow;wire [6:0] count;wire [511:0] slots;wire [2047:0] hit_ids;
 seed_select dut(.clk(clk),.rst_n(rst_n),.start(start),.force_64(force_64),.densities(density),.landmarks(landmarks),
  .landmark_hit_ids(ids),.done(done),.overflow(overflow),.seed_count(count),.seed_slots(slots),.seed_hit_ids(hit_ids));
 reg [31:0] cases[0:20575];reg [8191:0] path,filename;integer base,passes;
 always @(posedge clk) if(rst_n) begin
  if(start) passes<=0;
  else if(dut.state==5) passes<=passes+1;
 end
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA required");
  $sformat(filename,"%0s/seed_cases.mem",path);$readmemh(filename,cases);
  repeat(4) @(negedge clk);rst_n=1;
  for(integer test=0;test<32;test=test+1) begin
   force_64=cases[test*643];base=test*643+1;
   for(integer i=0;i<128;i=i+1) begin density[i*32+:32]=cases[base+i];ids[i*32+:32]=cases[base+384+i];end
   for(integer i=0;i<256;i=i+1) landmarks[i*32+:32]=cases[base+128+i];
   start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
   if(passes!==count) $fatal(1,"Separation work skipped for case %0d",test);
   if(count!==cases[base+512] || overflow!==cases[base+513]) $fatal(1,"Seed count/cap mismatch case %0d: %0d expected %0d",test,count,cases[base+512]);
   for(integer i=0;i<64;i=i+1) begin
    if(slots[i*8+:8]!==cases[base+514+i]) $fatal(1,"Seed order mismatch case %0d slot %0d",test,i);
    if(hit_ids[i*32+:32]!==cases[base+578+i]) $fatal(1,"Seed identity mismatch");
   end
  end
  $display("PASS: seed priority, normal/forced mode switching, all 64 separation passes, fraction boundaries, inclusive separation, signed extremes, duplicates, zero density, cap, repeat events");$finish;
 end
 initial begin #1000000;$fatal(1,"Seed test timeout");end
endmodule

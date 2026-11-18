`timescale 1ns/1ps
module seed_tb;
 reg clk=0,rst_n=0,prepare=0,start=0,force_64=0;always #5 clk=~clk;
 reg [4095:0] density,ids;reg [8191:0] landmarks;
 wire done,overflow;wire [6:0] count;wire [511:0] slots;wire [2047:0] hit_ids;
 seed_select dut(.clk(clk),.rst_n(rst_n),.prepare(prepare),.start(start),.force_64(force_64),.densities(density),.landmarks(landmarks),
  .landmark_hit_ids(ids),.done(done),.overflow(overflow),.seed_count(count),.seed_slots(slots),.seed_hit_ids(hit_ids));
 reg [31:0] cases[0:20575];reg [8191:0] path,filename;integer base,passes,rows,distance_squared,delta;
 always @(posedge clk) if(rst_n) begin
  if(prepare) begin passes<=0;rows<=0;end
  else begin
   if(dut.state==dut.SUPPRESS) begin
    if(!dut.masks_ready) $fatal(1,"Selection used an incomplete table");
    passes<=passes+1;
   end
   if(dut.preparing && dut.phase==6) begin
    rows<=rows+1;
    for(integer i=0;i<128;i=i+1) begin
     distance_squared=0;
     for(integer d=0;d<8;d=d+1) begin
      delta=$signed(landmarks[i*64+d*8+:8])-$signed(landmarks[dut.prep_row*64+d*8+:8]);
      distance_squared=distance_squared+delta*delta;
     end
     if(dut.row_mask[i]!==(distance_squared<3267)) $fatal(1,"Incorrect precomputed separation mask");
    end
   end
  end
 end
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA required");
  $sformat(filename,"%0s/seed_cases.mem",path);$readmemh(filename,cases);
  repeat(4) @(negedge clk);rst_n=1;
  for(integer test=0;test<32;test=test+1) begin
   force_64=cases[test*643];base=test*643+1;
   for(integer i=0;i<128;i=i+1) begin density[i*32+:32]=cases[base+i];ids[i*32+:32]=cases[base+384+i];end
   for(integer i=0;i<256;i=i+1) landmarks[i*32+:32]=cases[base+128+i];
   prepare=1;@(negedge clk);prepare=0;
   // Exercise density arriving before and after geometry is ready.
   repeat(test%3==0?8:1100) @(negedge clk);
   start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
   if(passes!==count || rows!==128) $fatal(1,"Missing mask preparation/selection case %0d",test);
   if(count!==cases[base+512] || overflow!==cases[base+513]) $fatal(1,"Seed count/cap mismatch case %0d: %0d expected %0d",test,count,cases[base+512]);
   for(integer i=0;i<64;i=i+1) begin
    if(slots[i*8+:8]!==cases[base+514+i]) $fatal(1,"Seed order mismatch case %0d slot %0d",test,i);
    if(hit_ids[i*32+:32]!==cases[base+578+i]) $fatal(1,"Seed identity mismatch");
   end
  end
  $display("PASS: seed priority, normal/forced switching, all 128 exact separation masks, early/late density arrival, fraction boundaries, inclusive separation, signed extremes, duplicates, zero density, cap, repeat events");$finish;
 end
 initial begin #1000000;$fatal(1,"Seed test timeout");end
endmodule

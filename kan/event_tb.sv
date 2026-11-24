`timescale 1ns/1ps
`ifndef TEST_LANES
`define TEST_LANES 1
`endif
module event_tb #(parameter bit PIPELINE_WRITE=0);
 localparam P=`TEST_LANES;
 reg clk=0,rst_n=0,clear=0,lv=0,sv=0,orr=0;
 reg [31:0] hit=0;
 reg [13:0] count=0;
 wire lr,sr,busy,done,ov,ol;
 wire [31:0] cycles;
 wire [13:0] loaded;
 wire [P*64-1:0] emb;
 wire [12:0] id;
 wire [P-1:0] mask;
 kan_event #(.LANES(P),.PIPELINE_WRITE(PIPELINE_WRITE)) dut(clk,rst_n,clear,lv,lr,hit,sv,sr,count,
  busy,done,cycles,loaded,ov,orr,emb,id,mask,ol);
 always #5 clk=~clk;
 reg [31:0] x[0:7999];reg [63:0] y[0:7999];
 integer i,received,tick,lane,offset,stalls;
 reg [31:0] rng=32'h461839;
 reg prev_stall;
 reg [P*64+13+P:0] saved;
 wire [P*64+13+P:0] payload={emb,id,mask,ol};
 task reset;
  begin
   @(negedge clk);rst_n=0;lv=0;sv=0;orr=0;clear=0;
   repeat(3) @(negedge clk);
   if(ov || busy || loaded!=0) $fatal(1,"reset status");
   rst_n=1;
  end
 endtask
 task load(input integer size,input integer off);
  begin
   @(negedge clk);clear=1;
   @(negedge clk);clear=0;
   for(i=0;i<size;i=i+1) begin
    lv=1;hit=x[i+off];
    @(posedge clk);if(!lr) $fatal(1,"load blocked");
    @(negedge clk);
   end
   lv=0;offset=off;count=size;#1;
   if(PIPELINE_WRITE) begin
    repeat(4) begin
     if(sr) $fatal(1,"start_ready asserted with a raw write in flight");
     @(negedge clk);
    end
    if(!sr) $fatal(1,"start_ready held after last raw write committed");
   end
   if(loaded!=size) $fatal(1,"load count");
  end
 endtask
 task run(input integer size,input integer backpressure);
  begin
   @(negedge clk);count=size;sv=1;orr=0;
   @(posedge clk);if(!sr) $fatal(1,"start blocked");
   @(negedge clk);sv=0;received=0;tick=0;stalls=0;prev_stall=0;
   while(received<size) begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    orr=!backpressure || (tick%89>=19 && rng[4:2]!=0);
    // Offer writes while busy: ready must stay low and raw data must survive.
    lv=1;hit=32'hbad0bad0;clear=1;
    @(posedge clk);
    if(lr) $fatal(1,"write accepted busy");
    if(prev_stall && (!ov || payload!==saved)) $fatal(1,"event output changed stalled");
    prev_stall=ov && !orr;saved=payload;
    if(ov && !orr) stalls=stalls+1;
    if(ov && orr) begin
     if(id!==received || ol!==(received+P>=size)) $fatal(1,"event metadata mismatch");
     for(lane=0;lane<P;lane=lane+1) begin
      if(mask[lane]!==(received+lane<size)) $fatal(1,"tail mask");
      if(mask[lane] && emb[lane*64+:64]!==y[received+lane+offset])
       $fatal(1,"event embedding hit=%0d lane=%0d actual=%h expected=%h",received,lane,emb[lane*64+:64],y[received+lane+offset]);
     end
     received=received+P;
    end
    tick=tick+1;
    if(tick>100000) $fatal(1,"event timeout");
    @(negedge clk);lv=0;clear=0;
   end
   if(busy || !done || cycles!=tick) $fatal(1,"completion endpoint cycles=%0d tick=%0d",cycles,tick);
   if(!backpressure && cycles!=(size+P-1)/P+dut.READ_STAGES+10)
    $fatal(1,"event latency/II cycles=%0d",cycles);
   $display("EVENT lanes=%0d hits=%0d stalls=%0d cycles=%0d read_stages=%0d blocked=%0d",P,size,backpressure,cycles,dut.READ_STAGES,stalls);
   orr=1;
   repeat(15) begin @(posedge clk);if(ov) $fatal(1,"extra event output");end
  end
 endtask
 initial begin
  $readmemh("wire.mem",x);$readmemh("expected.mem",y);
  reset();
  @(negedge clk);count=1;sv=1;
  @(posedge clk);if(sr) $fatal(1,"empty event accepted");
  @(negedge clk);sv=0;
  load(8000,0);
  count=8001;#1;if(sr) $fatal(1,"oversize accepted");
  count=0;#1;if(sr) $fatal(1,"zero accepted");
  run(1,0);run(3,1);run(33,0);run(8000,0);run(8000,1);
  // Reset while work is in flight, then load new raw values and start again.
  @(negedge clk);count=33;sv=1;orr=0;
  @(posedge clk);
  @(negedge clk);sv=0;
  repeat(7) @(negedge clk);
  reset();load(31,2111);run(31,1);run(7,0);
  $display("PASS: event lanes=%0d capacity=8000",P);$finish;
 end
endmodule

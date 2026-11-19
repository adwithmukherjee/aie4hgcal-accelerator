`timescale 1ns/1ps
`ifndef TEST_LANES
`define TEST_LANES 1
`endif
module stream_tb;
 localparam P=`TEST_LANES;
 reg clk=0,rst_n=0,iv=0,orr=0,il=0;
 reg [P*32-1:0] hits=0;
 reg [12:0] id=0;
 reg [P-1:0] mask=0;
 wire ir,ov,ol;
 wire [P*64-1:0] emb;
 wire [12:0] oid;
 wire [P-1:0] om;
 kan_stream #(.LANES(P)) dut(clk,rst_n,iv,ir,hits,id,mask,il,ov,orr,emb,oid,om,ol);
 always #5 clk=~clk;
 reg [31:0] x[0:7999];reg [63:0] y[0:7999];
 integer sent,received,n,tick,lane,stall_mode,first_tick,blocked;
 reg [31:0] rng=32'h3192026;
 reg previous_stall, accepted;
 reg [P*64+13+P:0] saved;
 wire [P*64+13+P:0] payload={emb,oid,om,ol};
 task reset;
  begin
   @(negedge clk);rst_n=0;iv=0;orr=0;
   repeat(3) @(negedge clk);
   if(ov!==0) $fatal(1,"reset did not clear valid");
   rst_n=1;
  end
 endtask
 task run(input integer size,input integer stalls);
  begin
   sent=0;received=0;n=size;tick=0;stall_mode=stalls;
   first_tick=-1;blocked=0;previous_stall=0;accepted=0;
   while(received<n) begin
    @(negedge clk);
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    // After a non-accepted offer, preserve every input field.
    if(!iv || accepted) begin
     iv=sent<n && (!stalls || rng[2:0]!=0);
     id=sent;il=sent+P>=n;
     for(lane=0;lane<P;lane=lane+1) begin
      mask[lane]=sent+lane<n;
      hits[lane*32+:32]=sent+lane<n ? x[sent+lane] : 32'hffffffff;
     end
    end
    orr=!stalls || (tick%97>=21 && rng[5:3]!=0);
    @(posedge clk);
    if(previous_stall && (!ov || payload!==saved)) $fatal(1,"output changed under backpressure");
    previous_stall=ov && !orr;saved=payload;
    accepted=iv && ir;
    if(accepted) begin if(first_tick<0) first_tick=tick;sent=sent+P;end
    if(ov && !orr) blocked=blocked+1;
    if(ov && orr) begin
     if(oid!==received || ol!==(received+P>=n)) $fatal(1,"metadata mismatch");
     if(!stalls && tick != first_tick+10+received/P) $fatal(1,"latency/II mismatch %0d",tick);
     for(lane=0;lane<P;lane=lane+1) begin
      if(om[lane]!==(received+lane<n)) $fatal(1,"lane mask mismatch");
      if(om[lane] && emb[lane*64+:64]!==y[received+lane])
       $fatal(1,"embedding mismatch hit=%0d lane=%0d actual=%h expected=%h",received,lane,emb[lane*64+:64],y[received+lane]);
     end
     received=received+P;
    end
    tick=tick+1;
    if(tick>100000) $fatal(1,"timeout");
   end
   @(negedge clk);iv=0;orr=1;
   repeat(12) begin @(posedge clk);if(ov) $fatal(1,"duplicate output");end
   if(stalls && blocked==0) $fatal(1,"backpressure unexercised");
   $display("STREAM lanes=%0d hits=%0d stalls=%0d cycles=%0d blocked=%0d latency=10 II=1",P,n,stalls,tick,blocked);
  end
 endtask
 initial begin
  $readmemh("wire.mem",x);$readmemh("expected.mem",y);
  reset();run(33,0);
  // Abort a partially filled pipeline. No pre-reset item may leak afterward.
  @(negedge clk);iv=1;orr=0;mask='1;hits=0;
  repeat(5) @(negedge clk);
  reset();run(8000,1);run(7,0);
  $display("PASS: stream lanes=%0d",P);$finish;
 end
endmodule

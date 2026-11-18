`timescale 1ns/1ps
// Equivalent to density sorting followed by greedy separation checks:
// select the best active candidate and suppress all close neighbors in parallel.
module seed_select (
 input wire clk, rst_n, start, force_64,
 input wire [4095:0] densities,
 input wire [8191:0] landmarks,
 input wire [4095:0] landmark_hit_ids,
 output reg done, overflow,
 output reg [6:0] seed_count,
 output reg [511:0] seed_slots,
 output reg [2047:0] seed_hit_ids
);
 localparam IDLE=0, INITIAL=1, ELIGIBLE=2, PICK=3, DISTANCE=4, SUPPRESS=5;
 reg [2:0] state;
 reg [127:0] active;
 reg [3:0] wait_cycles, phase;
 reg [6:0] chosen;
 reg [9:0] maximum;
 reg forced;
 // Valid, density (<=640), inverted slot for lowest-ID ties.
 wire [17:0] leaf [0:127];
 reg [17:0] tree [1:127];
 generate for(genvar i=0;i<128;i=i+1) begin: candidates
  assign leaf[i]={active[i],densities[i*32+:10],7'd127-i[6:0]};
 end
 for(genvar i=64;i<128;i=i+1) begin: first_level
  always @(posedge clk) tree[i]<=leaf[(i-64)*2]>=leaf[(i-64)*2+1]?leaf[(i-64)*2]:leaf[(i-64)*2+1];
 end
 for(genvar i=1;i<64;i=i+1) begin: upper_levels
  always @(posedge clk) tree[i]<=tree[i*2]>=tree[i*2+1]?tree[i*2]:tree[i*2+1];
 end endgenerate
 // Two coordinates/cycle across 128 landmarks: 256 small multipliers.
 // Subtraction, square, and accumulation are separate pipeline stages.
 reg signed [8:0] delta0[0:127],delta1[0:127];
 reg [17:0] square0[0:127],square1[0:127];
 reg [19:0] squared[0:127];
 wire [127:0] remaining;
 generate for(genvar i=0;i<128;i=i+1) begin: separation
  // Stress mode retains every distance pass but overrides neighbor rejection.
  assign remaining[i]=active[i] && (forced || squared[i]>=20'd3267) && i!=chosen;
 end endgenerate
 integer i;
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;done<=0;overflow<=0;seed_count<=0;seed_slots<=0;seed_hit_ids<=0;
   active<=0;wait_cycles<=0;phase<=0;chosen<=0;maximum<=0;forced<=0;
  end else if(start) begin
   state<=INITIAL;active<=~128'b0;wait_cycles<=7;done<=0;overflow<=0;
   seed_count<=0;seed_slots<=0;seed_hit_ids<=0;
   forced<=force_64;
  end else case(state)
   INITIAL: if(wait_cycles!=0) wait_cycles<=wait_cycles-1;
    else begin maximum<=tree[1][16:7];state<=ELIGIBLE;end
   ELIGIBLE: begin
    for(i=0;i<128;i=i+1) active[i]<=forced || ({3'b0,densities[i*32+:10]}*13'd5 >= maximum);
    wait_cycles<=7;state<=PICK;
   end
   PICK: if(wait_cycles!=0) wait_cycles<=wait_cycles-1;
    else if(!tree[1][17]) begin done<=1;state<=IDLE;end
    else begin
     chosen<=~tree[1][6:0];
     seed_slots[seed_count*8+:8]<={1'b0,~tree[1][6:0]};
     seed_hit_ids[seed_count*32+:32]<=landmark_hit_ids[(7'd127-tree[1][6:0])*32+:32];
     seed_count<=seed_count+1;
     for(i=0;i<128;i=i+1) squared[i]<=0;
     phase<=0;state<=DISTANCE;
    end
   DISTANCE: begin
    if(phase<4) for(i=0;i<128;i=i+1) begin
     delta0[i]<=$signed({landmarks[i*64+phase*16+7],landmarks[i*64+phase*16+:8]})
                 -$signed({landmarks[chosen*64+phase*16+7],landmarks[chosen*64+phase*16+:8]});
     delta1[i]<=$signed({landmarks[i*64+phase*16+15],landmarks[i*64+phase*16+8+:8]})
                 -$signed({landmarks[chosen*64+phase*16+15],landmarks[chosen*64+phase*16+8+:8]});
    end
    if(phase>=1 && phase<=4) for(i=0;i<128;i=i+1) begin
     square0[i]<=delta0[i]*delta0[i];square1[i]<=delta1[i]*delta1[i];
    end
    if(phase>=2) for(i=0;i<128;i=i+1)
     squared[i]<=squared[i]+{2'b0,square0[i]}+{2'b0,square1[i]};
    if(phase==5) state<=SUPPRESS;else phase<=phase+1;
   end
   SUPPRESS: begin
    active<=remaining;
    if(seed_count==64 || remaining==0) begin
     done<=1;overflow<=seed_count==64 && remaining!=0;state<=IDLE;
    end else begin wait_cycles<=7;state<=PICK;end
   end
   default:;
  endcase
 end
endmodule

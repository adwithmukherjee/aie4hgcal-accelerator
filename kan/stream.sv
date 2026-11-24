`timescale 1ns/1ps
// A group can be replicated independently: no global event-wide serializer.
// Lowest byte is coordinate 0; lane l is hit base_id+l when lane_mask[l].
module kan_stream #(
 parameter integer LANES=1, ID_WIDTH=13,
 parameter bit GATE_IDLE=1
)(
 input wire clk, rst_n,
 input wire in_valid, output wire in_ready,
 input wire [LANES*32-1:0] in_hits,
 input wire [ID_WIDTH-1:0] in_base_id,
 input wire [LANES-1:0] in_mask, input wire in_last,
 output wire out_valid, input wire out_ready,
 output wire [LANES*64-1:0] out_embeddings,
 output wire [ID_WIDTH-1:0] out_base_id,
 output wire [LANES-1:0] out_mask, output wire out_last
);
 localparam integer STAGES=10;
 reg [STAGES-1:0] valid;
 reg [ID_WIDTH-1:0] ids[0:STAGES-1];
 reg [LANES-1:0] masks[0:STAGES-1];
 reg [STAGES-1:0] last;
 wire advance=!valid[STAGES-1] || out_ready;
 // The integrated sink is continuously ready. Disabling idle gating there
 // lets synthesis tie every lane CE high while valid bits mark bubbles.
 wire run=advance && (!GATE_IDLE || in_valid || (|valid));
 assign in_ready=rst_n && advance;
 assign out_valid=rst_n && valid[STAGES-1];
 assign out_base_id=ids[STAGES-1];
 assign out_mask=masks[STAGES-1];
 assign out_last=last[STAGES-1];
 for(genvar lane=0;lane<LANES;lane=lane+1) begin: lanes
  kan_lane core(.clk(clk),.ce(run),.din(in_hits[lane*32+:32]),
                .dout(out_embeddings[lane*64+:64]));
 end
 integer i;
 always @(posedge clk) begin
  if(!rst_n) begin valid<=0;last<=0;end
  else if(run) begin
   valid<={valid[STAGES-2:0],in_valid};
   last<={last[STAGES-2:0],in_last};
   ids[0]<=in_base_id;masks[0]<=in_mask;
   for(i=1;i<STAGES;i=i+1) begin ids[i]<=ids[i-1];masks[i]<=masks[i-1];end
  end
 end
endmodule

`timescale 1ns/1ps
// Equivalent to density sorting followed by greedy separation checks:
// Prepare geometry at input release; select/suppress after densities arrive.
module seed_select (
 input wire clk, rst_n, prepare, start, force_64,
 input wire [4095:0] densities,
 input wire [8191:0] landmarks,
 input wire [4095:0] landmark_hit_ids,
 output reg done, overflow,
 output reg [6:0] seed_count,
 output reg [511:0] seed_slots,
 output reg [2047:0] seed_hit_ids
);
 localparam IDLE=0, INITIAL=1, ELIGIBLE=2, PICK=3, SUPPRESS=4;
 reg [2:0] state;
 reg [127:0] active;
 reg [3:0] wait_cycles;
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
 // All 128 rows are prepared during AIE density computation, including in
 // forced mode. Seven clocks/row: six arithmetic clocks and one mask write.
 // The synchronous 128-bit read replaces arithmetic on the selection path.
 (* ram_style="block" *) reg [127:0] too_close [0:127];
 reg [127:0] suppress;
 reg preparing, masks_ready;
 reg [6:0] prep_row;
 reg [2:0] phase;
 // Two coordinates/cycle across 128 landmarks: 256 small multipliers.
 // Subtraction, square, and accumulation are separate pipeline stages.
 reg signed [8:0] delta0[0:127],delta1[0:127];
 reg [17:0] square0[0:127],square1[0:127];
 reg [19:0] squared[0:127];
 wire [127:0] remaining;
 wire [127:0] row_mask;
 generate for(genvar i=0;i<128;i=i+1) begin: separation
  assign row_mask[i]=squared[i]<20'd3267;
  assign remaining[i]=active[i] && (forced || !suppress[i]) && i!=chosen;
 end endgenerate
 integer i,p;
 always @(posedge clk) begin
  if(!rst_n) begin preparing<=0;masks_ready<=0;prep_row<=0;phase<=0;end
  else if(prepare) begin
   preparing<=1;masks_ready<=0;prep_row<=0;phase<=0;
   for(p=0;p<128;p=p+1) squared[p]<=0;
  end else if(preparing) begin
   if(phase<4) for(p=0;p<128;p=p+1) begin
    delta0[p]<=$signed({landmarks[p*64+phase*16+7],landmarks[p*64+phase*16+:8]})
                -$signed({landmarks[prep_row*64+phase*16+7],landmarks[prep_row*64+phase*16+:8]});
    delta1[p]<=$signed({landmarks[p*64+phase*16+15],landmarks[p*64+phase*16+8+:8]})
                -$signed({landmarks[prep_row*64+phase*16+15],landmarks[prep_row*64+phase*16+8+:8]});
   end
   if(phase>=1 && phase<=4) for(p=0;p<128;p=p+1) begin
    square0[p]<=delta0[p]*delta0[p];square1[p]<=delta1[p]*delta1[p];
   end
   if(phase>=2 && phase<=5) for(p=0;p<128;p=p+1)
    squared[p]<=squared[p]+{2'b0,square0[p]}+{2'b0,square1[p]};
   if(phase==6) begin
    too_close[prep_row]<=row_mask;
    for(p=0;p<128;p=p+1) squared[p]<=0;
    phase<=0;
    if(prep_row==127) begin preparing<=0;masks_ready<=1;end
    else prep_row<=prep_row+1;
   end else phase<=phase+1;
  end
 end
 always @(posedge clk)
  if(state==PICK && wait_cycles==0 && masks_ready && tree[1][17])
   suppress<=too_close[7'd127-tree[1][6:0]];
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;done<=0;overflow<=0;seed_count<=0;seed_slots<=0;seed_hit_ids<=0;
   active<=0;wait_cycles<=0;chosen<=0;maximum<=0;forced<=0;
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
    else if(!masks_ready) begin end
    else if(!tree[1][17]) begin done<=1;state<=IDLE;end
    else begin
     chosen<=~tree[1][6:0];
     seed_slots[seed_count*8+:8]<={1'b0,~tree[1][6:0]};
     seed_hit_ids[seed_count*32+:32]<=landmark_hit_ids[(7'd127-tree[1][6:0])*32+:32];
     seed_count<=seed_count+1;
     state<=SUPPRESS;
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

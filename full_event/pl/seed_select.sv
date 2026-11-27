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
 reg [12:0] maximum;
 reg forced;
 // Valid, density (<=8000), inverted slot for lowest-ID ties.
 wire [20:0] leaf [0:127];
 reg [20:0] tree [1:127];
 generate for(genvar i=0;i<128;i=i+1) begin: candidates
  assign leaf[i]={active[i],densities[i*32+:13],7'd127-i[6:0]};
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
 // The low two bytes feed every subtractor. Load a complete row on the
 // preceding mask-write edge, then shift the next pair into place each clock.
 // Limit the fanout of reference bits shared by all 128 subtractors.
 (* max_fanout=32 *) reg [63:0] reference_coords;
 reg [6:0] next_reference_row;
 always @(posedge clk) begin
  if(prepare) begin
   reference_coords<=landmarks[63:0];
   next_reference_row<=1;
  end else if(preparing) begin
   if(phase==6) begin
    reference_coords<=landmarks[next_reference_row*64+:64];
    next_reference_row<=next_reference_row+1'b1;
   end else if(phase<3) reference_coords<=reference_coords>>16;
  end
 end
 integer i,p;
 always @(posedge clk) begin
  if(!rst_n) begin preparing<=0;masks_ready<=0;prep_row<=0;phase<=0;end
  else if(prepare) begin
   preparing<=1;masks_ready<=0;prep_row<=0;phase<=0;
   for(p=0;p<128;p=p+1) squared[p]<=0;
  end else if(preparing) begin
   if(phase<4) for(p=0;p<128;p=p+1) begin
    delta0[p]<=$signed({landmarks[p*64+phase*16+7],landmarks[p*64+phase*16+:8]})
                -$signed({reference_coords[7],reference_coords[7:0]});
    delta1[p]<=$signed({landmarks[p*64+phase*16+15],landmarks[p*64+phase*16+8+:8]})
                -$signed({reference_coords[15],reference_coords[15:8]});
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
  if(state==PICK && wait_cycles==0 && masks_ready && tree[1][20])
   suppress<=too_close[7'd127-tree[1][6:0]];
 // Each root child covers 64 slots. Fetch its finalist ID on the
 // same clock that the root chooses between the two children.
 wire [31:0] finalist_id[0:1];
 for(genvar half=0;half<2;half=half+1) begin: finalist_lookup
  wire [5:0] slot=~tree[2+half][5:0];
  reg [31:0] id;
  always @(posedge clk) id<=landmark_hit_ids[(half*64+slot)*32+:32];
  assign finalist_id[half]=id;
 end
 // Arm the destination in the last countdown cycle. Keep it armed if
 // geometry is late, then disarm as soon as PICK can retire.
 wire arm_destination=rst_n && !start && state==PICK &&
                      (wait_cycles==1 || (wait_cycles==0 && !masks_ready));
 for(genvar dest=0;dest<64;dest=dest+1) begin: seed_ids
  reg selected;
  always @(posedge clk) selected<=arm_destination && seed_count==dest;
  always @(posedge clk) begin
   if(!rst_n || start) seed_hit_ids[dest*32+:32]<=0;
   else if(selected && masks_ready && tree[1][20])
    seed_hit_ids[dest*32+:32]<=finalist_id[~tree[1][6]];
  end
 end
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;done<=0;overflow<=0;seed_count<=0;seed_slots<=0;
   active<=0;wait_cycles<=0;chosen<=0;maximum<=0;forced<=0;
  end else if(start) begin
   state<=INITIAL;active<=~128'b0;wait_cycles<=7;done<=0;overflow<=0;
   seed_count<=0;seed_slots<=0;
   forced<=force_64;
  end else case(state)
   INITIAL: if(wait_cycles!=0) wait_cycles<=wait_cycles-1;
    else begin maximum<=tree[1][19:7];state<=ELIGIBLE;end
   ELIGIBLE: begin
    for(i=0;i<128;i=i+1) active[i]<=forced || ({3'b0,densities[i*32+:13]}*16'd5 >= maximum);
    wait_cycles<=7;state<=PICK;
   end
   PICK: if(wait_cycles!=0) wait_cycles<=wait_cycles-1;
    else if(!masks_ready) begin end
    else if(!tree[1][20]) begin done<=1;state<=IDLE;end
    else begin
     chosen<=~tree[1][6:0];
     seed_slots[seed_count*8+:8]<={1'b0,~tree[1][6:0]};
     seed_count<=seed_count+1;
     state<=SUPPRESS;
    end
   SUPPRESS: begin
    active<=remaining;
    // Reload for the next pick. START initializes the counter after a terminal pick.
    wait_cycles<=7;
    if(seed_count==64 || remaining==0) begin
     done<=1;overflow<=seed_count==64 && remaining!=0;state<=IDLE;
    end else state<=PICK;
   end
   default:;
  endcase
 end
endmodule

`timescale 1ns/1ps
// Sequential host/test loading is outside the event timer. clear_load allows a
// fresh event; resident data can also be replayed. All writes are blocked busy.
module kan_event #(
 parameter integer LANES=1, MAX_HITS=8000, ID_WIDTH=13,
 parameter integer DEPTH=(MAX_HITS+LANES-1)/LANES,
 parameter integer ROW_WIDTH=$clog2(DEPTH+1),
 parameter integer READ_STAGES=($clog2(DEPTH)+3)/4 > 0 ? ($clog2(DEPTH)+3)/4 : 1,
 parameter bit GATE_IDLE=1,
 // Set only when the caller decodes load and start as mutually exclusive commands.
 parameter bit EXCLUSIVE_LOAD_START=0, PIPELINE_WRITE=0
)(
 input wire clk,rst_n,clear_load,
 input wire load_valid,output wire load_ready,input wire [31:0] load_hit,
 input wire start_valid,output wire start_ready,input wire [ID_WIDTH:0] event_count,
 output reg busy,output reg done,output reg [31:0] cycles,
 output wire [ID_WIDTH:0] loaded_count,
 output wire out_valid,input wire out_ready,
 output wire [LANES*64-1:0] out_embeddings,
 output wire [ID_WIDTH-1:0] out_base_id,
 output wire [LANES-1:0] out_mask,output wire out_last
);
 reg [ID_WIDTH:0] loaded,issued,count;
 reg [READ_STAGES-1:0] valid,last;
 reg [ID_WIDTH-1:0] ids[0:READ_STAGES-1];
 reg [LANES-1:0] masks[0:READ_STAGES-1];
 wire ready;
 wire advance=!valid[READ_STAGES-1] || ready;
 wire issue=busy && issued<count;
 wire read_run=advance && (issue || (|valid));
 // Non-gated banks may shift invalid payload during bubbles or reset.
 // During a valid stall they hold in step with the read metadata.
 wire bank_advance=GATE_IDLE ? read_run : (!rst_n || advance);
 wire [LANES*32-1:0] read_hits;
 wire [LANES-1:0] issue_mask;
 assign loaded_count=loaded;
 assign load_ready=rst_n && !busy && (EXCLUSIVE_LOAD_START || !start_valid) && !clear_load && loaded<MAX_HITS;
 wire accepted_write=load_valid && load_ready;
 wire [LANES-1:0] bank_write;
 wire [ROW_WIDTH-1:0] write_row;
 wire [31:0] write_hit;
 wire writes_drained;
 if(PIPELINE_WRITE) begin: write_command
  // Capture the accepted index before loaded advances. Payload flops sample
  // unconditionally so AXI validation only drives the command-valid bit.
  reg [ID_WIDTH:0] command_index;
  reg [31:0] command_data,dispatch_data;
  reg [ROW_WIDTH-1:0] dispatch_row;
  reg [3:0] pending;
  always @(posedge clk) begin
   command_index<=loaded;
   command_data<=load_hit;
   dispatch_row<=ROW_WIDTH'(command_index/LANES);
   dispatch_data<=command_data;
   if(!rst_n) pending<=0;
   else pending<={pending[2:0],accepted_write};
  end
  for(genvar lane=0;lane<LANES;lane=lane+1) begin: dispatch
   reg selected;
   always @(posedge clk) selected<=pending[0] && command_index%LANES==lane;
   assign bank_write[lane]=selected;
  end
  assign write_row=dispatch_row;
  assign write_hit=dispatch_data;
  // Command, dispatch, bank capture, word strobe. The last strobe
  // commits on the edge that shifts the final pending bit out.
  assign writes_drained=!(|pending);
 end else begin: direct_command
  for(genvar lane=0;lane<LANES;lane=lane+1)
   assign bank_write[lane]=accepted_write && loaded%LANES==lane;
  assign write_row=ROW_WIDTH'(loaded/LANES);
  assign write_hit=load_hit;
  assign writes_drained=1'b1;
 end
 assign start_ready=writes_drained && rst_n && !busy && !clear_load && event_count>0 && event_count<=MAX_HITS && event_count<=loaded;
 for(genvar lane=0;lane<LANES;lane=lane+1) begin: banks
  // Keep the sequential read address at each bank. Payload and metadata advance
  // on the same accepted issue, including when downstream applies backpressure.
  (* dont_touch="true" *) reg [ROW_WIDTH-1:0] read_row;
  always @(posedge clk) begin
   if(!rst_n || !busy) read_row<=0;
   else if(advance && issue) read_row<=read_row+1'b1;
  end
  // Each first-stage mux group has its own four-bit address copy.
  // Sample the next address on the same issue edge as the bank counter.
  wire [((DEPTH+15)/16)*4-1:0] group_digits;
  for(genvar group=0;group<(DEPTH+15)/16;group=group+1) begin: read_groups
   (* dont_touch="true" *) reg [3:0] digit;
   always @(posedge clk) begin
    if(!rst_n || !busy) digit<=0;
    else if(advance && issue) digit<=4'(read_row+1'b1);
   end
   assign group_digits[group*4+:4]=digit;
  end
  assign issue_mask[lane]=issued+lane<count;
  kan_register_bank #(.DEPTH(DEPTH),.ADDR_WIDTH(ROW_WIDTH),.PIPELINE_WRITE(PIPELINE_WRITE)) bank(
   .clk(clk),.write_en(bank_write[lane]),
   .write_row(write_row),.write_hit(write_hit),
   .read_row(read_row),.group_digits(group_digits),.advance(bank_advance),.read_hit(read_hits[lane*32+:32]));
 end
 kan_stream #(.LANES(LANES),.ID_WIDTH(ID_WIDTH),.GATE_IDLE(GATE_IDLE)) stream(
  .clk(clk),.rst_n(rst_n),.in_valid(valid[READ_STAGES-1]),.in_ready(ready),
  .in_hits(read_hits),.in_base_id(ids[READ_STAGES-1]),
  .in_mask(masks[READ_STAGES-1]),.in_last(last[READ_STAGES-1]),
  .out_valid(out_valid),.out_ready(out_ready),.out_embeddings(out_embeddings),
  .out_base_id(out_base_id),.out_mask(out_mask),.out_last(out_last));
 integer i;
 always @(posedge clk) begin
  if(!rst_n) begin
   loaded<=0;issued<=0;count<=0;busy<=0;done<=0;cycles<=0;valid<=0;last<=0;
  end else begin
   done<=0;
   if(clear_load && !busy) loaded<=0;
   else if(accepted_write) loaded<=loaded+1;
   if(start_valid && start_ready) begin
    count<=event_count;issued<=0;busy<=1;cycles<=0;
   end else if(busy) begin
    cycles<=cycles+1;
    if(out_valid && out_ready && out_last) begin busy<=0;done<=1;end
   end
   if(read_run) begin
    valid[0]<=issue;last[0]<=issue && issued+LANES>=count;
    ids[0]<=issued[ID_WIDTH-1:0];masks[0]<=issue_mask;
    if(issue) issued<=issued+LANES;
    for(i=1;i<READ_STAGES;i=i+1) begin
     valid[i]<=valid[i-1];last[i]<=last[i-1];ids[i]<=ids[i-1];masks[i]<=masks[i-1];
    end
   end
  end
 end
endmodule

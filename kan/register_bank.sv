`timescale 1ns/1ps
// Resident raw hits are flip-flops. Radix-16 registered read selection bounds
// mux fan-in at every stage; it adds ceil(log16(DEPTH)) cycles, II remains one.
module kan_register_bank #(
 parameter integer DEPTH=8000,
 parameter bit PIPELINE_WRITE=0,
 parameter integer ADDR_WIDTH=$clog2(DEPTH+1),
 parameter integer LEVELS=($clog2(DEPTH)+3)/4 > 0 ? ($clog2(DEPTH)+3)/4 : 1
)(
 input wire clk, write_en,
 input wire [ADDR_WIDTH-1:0] write_row, read_row,
 input wire [31:0] write_hit,
 input wire [((DEPTH+15)/16)*4-1:0] group_digits,
 input wire advance,
 output wire [31:0] read_hit
);
 (* ram_style="registers" *) reg [31:0] hits[0:DEPTH-1];
 if(PIPELINE_WRITE) begin: local_write
  reg bank_valid;
  reg [ADDR_WIDTH-1:0] bank_row;
  reg [31:0] bank_data;
  always @(posedge clk) begin
   bank_valid<=write_en;
   if(write_en) begin
    bank_row<=write_row;
    bank_data<=write_hit;
   end
  end
  // Each registered payload drives at most sixteen raw words. Its enable
  // uses the same captured row as the word strobe, so both arrive together.
  for(genvar group=0;group<(DEPTH+15)/16;group=group+1) begin: write_groups
   reg [31:0] data;
   always @(posedge clk) if(bank_valid && (bank_row >> 4)==group) data<=bank_data;
  end
  for(genvar row=0;row<DEPTH;row=row+1) begin: words
   reg select_word;
   always @(posedge clk) begin
    select_word<=bank_valid && bank_row==row;
    if(select_word) hits[row]<=write_groups[row/16].data;
   end
  end
 end else begin: direct_write
  always @(posedge clk) if(write_en) hits[write_row]<=write_hit;
 end
 reg [ADDR_WIDTH-1:0] address[0:LEVELS-1];
 integer i;
 always @(posedge clk) if(advance) begin
  address[0]<=read_row;
  for(i=1;i<LEVELS;i=i+1) address[i]<=address[i-1];
 end
 for(genvar level=0;level<LEVELS;level=level+1) begin: tree
  localparam integer STRIDE=16**level;
  localparam integer INPUTS=(DEPTH+STRIDE-1)/STRIDE;
  localparam integer OUTPUTS=(INPUTS+15)/16;
  reg [31:0] selected[0:OUTPUTS-1];
  for(genvar group=0;group<OUTPUTS;group=group+1) begin: groups
   wire [3:0] digit;
   if(level==0) assign digit=group_digits[group*4+:4];
   else assign digit=(address[level-1] >> (4*level)) % 16;
   wire [31:0] candidates[0:15];
   for(genvar slot=0;slot<16;slot=slot+1) begin: slots
    if(group*16+slot>=INPUTS) assign candidates[slot]=0;
    else if(level==0) assign candidates[slot]=hits[group*16+slot];
    else assign candidates[slot]=tree[level-1].selected[group*16+slot];
   end
   always @(posedge clk) if(advance) selected[group]<=candidates[digit];
  end
 end
 assign read_hit=tree[LEVELS-1].selected[0];
endmodule

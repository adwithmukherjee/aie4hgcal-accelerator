`timescale 1ns/1ps
// One independent eight-tile column. Only the parent owns the latency timer.
module column_lane (
 input wire clk, rst_n, start, allow_readback,
 input wire write_resident, write_route, write_id,
 input wire [9:0] write_index, resident_read_index,
 input wire [31:0] write_data, input wire [3:0] write_strobes,
 output wire [31:0] resident_read_data,
 input wire [12:0] matrix_read_index,
 output wire [127:0] matrix_read_data,
 output wire inputs_loaded, output wire [4095:0] density_counts,
 output reg density_done, readback_done, fault,
 output reg [31:0] tx_beats, rx_beats,
 output reg [7:0] density_mask, readback_mask,
 output reg [127:0] tx_data, output reg [15:0] tx_keep,
 output wire tx_last, tx_valid, input wire tx_ready,
 input wire [127:0] rx_data, input wire [15:0] rx_keep,
 input wire rx_last, rx_valid, output wire rx_ready
);
 localparam IDLE=0, LANDMARKS=1, HITS=2, WAIT_DENSITY=3, READBACK=4, SENT=5;
 (* ram_style="registers" *) reg [31:0] resident [0:575];
 reg [575:0] loaded;
 reg [31:0] density_sum [0:127];
 reg [31:0] route_header [0:16];
 reg [4:0] output_id [0:7];
 reg busy;
 reg [2:0] tx_state, tx_tile, rx_tile, rx_type;
 reg [8:0] tx_word, tx_length;
 reg [11:0] rx_words;
 assign inputs_loaded=&loaded;
 assign resident_read_data=resident[resident_read_index];
 generate for(genvar d=0;d<128;d=d+1) begin: density_export
  assign density_counts[d*32+:32]=density_sum[d];
 end endgenerate

 integer tw, source_word;
 always @* begin
  case(tx_state)
   LANDMARKS: tx_length=257;
   HITS: tx_length=41;
   READBACK: tx_length=1;
   default: tx_length=0;
  endcase
  tx_data=0; tx_keep=0; source_word=0;
  for(tw=0;tw<4;tw=tw+1) begin
   if(tx_word+tw<tx_length) begin
    tx_keep[tw*4+:4]=4'hf;
    if(tx_word+tw==0) begin
     case(tx_state)
      LANDMARKS: tx_data[tw*32+:32]=route_header[8];
      HITS: tx_data[tw*32+:32]=route_header[tx_tile];
      READBACK: tx_data[tw*32+:32]=route_header[9+tx_tile];
      default: tx_data[tw*32+:32]=0;
     endcase
    end else begin
     source_word=(tx_state==LANDMARKS ? 320 : tx_tile*40)+tx_word+tw-1;
     tx_data[tw*32+:32]=resident[source_word];
    end
   end
  end
 end
 assign tx_valid=busy && (tx_state==LANDMARKS || tx_state==HITS || tx_state==READBACK);
 assign tx_last=tx_word+4>=tx_length;
 assign rx_ready=busy;

 reg [2:0] beat_tile, beat_type, valid_words;
 reg beat_id_valid;
 integer r;
 always @* begin
  beat_tile=rx_tile; beat_type=rx_type; beat_id_valid=1;
  if(rx_words==0) begin
   beat_type=rx_data[14:12]; beat_id_valid=0; beat_tile=0;
   for(r=0;r<8;r=r+1) if(output_id[r]==rx_data[4:0]) begin
    beat_tile=r; beat_id_valid=1;
   end
  end
  case(rx_keep)
   16'h000f: valid_words=1;
   16'h00ff: valid_words=2;
   16'h0fff: valid_words=3;
   16'hffff: valid_words=4;
   default: valid_words=0;
  endcase
 end

 // Untimed matrix storage is retained for register readback and RTL checking.
 reg [3:0] matrix_we;
 reg [12:0] matrix_wa [0:3];
 reg [31:0] matrix_wd [0:3];
 integer b, rw, payload_word, bank;
 always @* begin
  matrix_we=0; payload_word=0; bank=0;
  for(b=0;b<4;b=b+1) begin matrix_wa[b]=0; matrix_wd[b]=0; end
  if(rx_valid && rx_ready && beat_id_valid && beat_type==1 && allow_readback) begin
   for(rw=0;rw<4;rw=rw+1) if(rw<valid_words && rx_words+rw>0 && rx_words+rw<=2560) begin
    payload_word=rx_words+rw-1; bank=payload_word%4;
    matrix_we[bank]=1;
    matrix_wa[bank]=beat_tile*640+(payload_word/4);
    matrix_wd[bank]=rx_data[rw*32+:32];
   end
  end
 end
 generate for(genvar mb=0;mb<4;mb=mb+1) begin: matrix_bank
  (* ram_style="block" *) reg [31:0] data [0:5119];
  always @(posedge clk) if(matrix_we[mb]) data[matrix_wa[mb]]<=matrix_wd[mb];
  assign matrix_read_data[mb*32+:32]=data[matrix_read_index];
 end endgenerate

 integer i, w, byte_lane, density_index;
 always @(posedge clk) begin
  if(!rst_n) begin
   loaded<=0; busy<=0; density_done<=0; readback_done<=0; fault<=0;
   tx_state<=IDLE; tx_tile<=0; tx_word<=0; tx_beats<=0; rx_beats<=0;
   rx_words<=0; rx_tile<=0; rx_type<=0; density_mask<=0; readback_mask<=0;
   for(i=0;i<128;i=i+1) density_sum[i]<=0;
   for(i=0;i<17;i=i+1) route_header[i]<=0;
   for(i=0;i<8;i=i+1) output_id[i]<=0;
  end else begin
   if(write_route) route_header[write_index]<=write_data;
   if(write_id) output_id[write_index]<=write_data[4:0];
   if(write_resident) begin
    for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
     if(write_strobes[byte_lane]) resident[write_index][byte_lane*8+:8]<=write_data[byte_lane*8+:8];
    loaded[write_index]<=(&write_strobes);
   end
   if(start) begin
    busy<=1; density_done<=0; readback_done<=0; fault<=0; loaded<=0;
    tx_state<=LANDMARKS; tx_tile<=0; tx_word<=0; tx_beats<=0; rx_beats<=0;
    rx_words<=0; density_mask<=0; readback_mask<=0;
    // Parallel register initialization on the release edge adds no startup cycle.
    for(i=0;i<128;i=i+1) density_sum[i]<=0;
   end else begin
    if(tx_valid && tx_ready) begin
     tx_beats<=tx_beats+1;
     if(tx_last) begin
      tx_word<=0;
      case(tx_state)
       LANDMARKS: begin tx_state<=HITS; tx_tile<=0; end
       HITS: if(tx_tile==7) tx_state<=WAIT_DENSITY; else tx_tile<=tx_tile+1;
       READBACK: if(tx_tile==7) tx_state<=SENT; else tx_tile<=tx_tile+1;
       default: tx_state<=SENT;
      endcase
     end else tx_word<=tx_word+4;
    end
    if(tx_state==WAIT_DENSITY && allow_readback) begin tx_state<=READBACK; tx_tile<=0; tx_word<=0; end
    if(rx_valid && rx_ready) begin
     rx_beats<=rx_beats+1;
     if(!beat_id_valid || valid_words==0 || (beat_type!=0 && beat_type!=1)) fault<=1;
     if(rx_words==0) begin
      rx_tile<=beat_tile; rx_type<=beat_type;
      if(beat_type==0 && density_mask[beat_tile]) fault<=1;
      if(beat_type==1 && (!allow_readback || readback_mask[beat_tile])) fault<=1;
     end
     if(beat_id_valid && beat_type==0) begin
      for(w=0;w<4;w=w+1) if(w<valid_words && rx_words+w>0 && rx_words+w<=32) begin
       for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1) begin
        density_index=(rx_words+w-1)*4+byte_lane;
        density_sum[density_index]<=density_sum[density_index]+{24'b0,rx_data[w*32+byte_lane*8+:8]};
       end
      end
     end
     if(rx_last) begin
      rx_words<=0;
      if(beat_type==0 && rx_words+valid_words==33 && beat_id_valid) begin
       density_mask<=density_mask | (8'b1<<beat_tile);
       if((density_mask | (8'b1<<beat_tile))==8'hff) density_done<=1;
      end else if(beat_type==1 && rx_words+valid_words==2561 && beat_id_valid && allow_readback) begin
       readback_mask<=readback_mask | (8'b1<<beat_tile);
       if((readback_mask | (8'b1<<beat_tile))==8'hff) begin readback_done<=1; busy<=0; end
      end else fault<=1;
     end else rx_words<=rx_words+valid_words;
    end
   end
  end
 end
endmodule

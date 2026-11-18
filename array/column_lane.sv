`timescale 1ns/1ps
module column_lane (
 input wire clk, rst_n, start, seeds_ready,
 input wire [6:0] seed_count, input wire [511:0] seed_slots,
 input wire write_resident, write_route, write_id,
 input wire [9:0] write_index, resident_read_index,
 input wire [31:0] write_data, input wire [3:0] write_strobes,
 output wire [31:0] resident_read_data,
 output wire [8191:0] landmarks,
 output wire inputs_loaded, output wire [4095:0] density_counts,
 output wire [1279:0] labels,
 output reg density_done, labels_done, fault,
 output wire labels_finishing,
 output reg [31:0] tx_beats, rx_beats,
 output reg [7:0] density_mask, label_mask,
 output reg [127:0] tx_data, output reg [15:0] tx_keep,
 output wire tx_last, tx_valid, input wire tx_ready,
 input wire [127:0] rx_data, input wire [15:0] rx_keep,
 input wire rx_last, rx_valid, output wire rx_ready
);
 localparam IDLE=0, LANDMARKS=1, HITS=2, WAIT_SEEDS=3, SEEDS=4, SENT=5;
 (* ram_style="registers" *) reg [31:0] resident [0:575];
 reg [575:0] loaded;
 reg [31:0] density_sum [0:127];
 reg [31:0] label_words[0:39];
 reg [31:0] route_header [0:9];
 reg [4:0] output_id [0:7];
 reg busy;
 reg [2:0] tx_state, tx_tile, rx_tile, rx_type;
 reg [8:0] tx_word, tx_length;
 reg [5:0] rx_words;
 assign inputs_loaded=&loaded;
 assign resident_read_data=resident[resident_read_index];
 generate for(genvar d=0;d<128;d=d+1) begin: density_export
  assign density_counts[d*32+:32]=density_sum[d];
 end
 for(genvar d=0;d<256;d=d+1) begin: landmark_export
  assign landmarks[d*32+:32]=resident[320+d];
 end
 for(genvar d=0;d<40;d=d+1) begin: label_export
  assign labels[d*32+:32]=label_words[d];
 end endgenerate
 integer tw, source_word;
 always @* begin
  case(tx_state)
   LANDMARKS: tx_length=257;
   HITS: tx_length=41;
   SEEDS: tx_length=2+((seed_count+3)>>2);
   default: tx_length=0;
  endcase
  tx_data=0;tx_keep=0;source_word=0;
  for(tw=0;tw<4;tw=tw+1) if(tx_word+tw<tx_length) begin
   tx_keep[tw*4+:4]=4'hf;
   if(tx_word+tw==0) begin
    case(tx_state)
     LANDMARKS:tx_data[tw*32+:32]=route_header[8];
     HITS:tx_data[tw*32+:32]=route_header[tx_tile];
     SEEDS:tx_data[tw*32+:32]=route_header[9];
     default:tx_data[tw*32+:32]=0;
    endcase
   end else if(tx_state==SEEDS) begin
    if(tx_word+tw==1) tx_data[tw*32+:32]=seed_count;
    else tx_data[tw*32+:32]=seed_slots[(tx_word+tw-2)*32+:32];
   end else begin
    source_word=(tx_state==LANDMARKS ? 320 : tx_tile*40)+tx_word+tw-1;
    tx_data[tw*32+:32]=resident[source_word];
   end
  end
 end
 assign tx_valid=busy && (tx_state==LANDMARKS || tx_state==HITS || tx_state==SEEDS);
 assign tx_last=tx_word+4>=tx_length;
 assign rx_ready=busy;
 reg [2:0] beat_tile,beat_type,valid_words;
 reg beat_id_valid;
 integer r;
 always @* begin
  beat_tile=rx_tile;beat_type=rx_type;beat_id_valid=1;
  if(rx_words==0) begin
   beat_type=rx_data[14:12];beat_id_valid=0;beat_tile=0;
   for(r=0;r<8;r=r+1) if(output_id[r]==rx_data[4:0]) begin beat_tile=r;beat_id_valid=1;end
  end
  case(rx_keep)
   16'h000f:valid_words=1;
   16'h00ff:valid_words=2;
   16'h0fff:valid_words=3;
   16'hffff:valid_words=4;
   default:valid_words=0;
  endcase
 end
 wire final_label=rx_valid && rx_ready && rx_last && beat_id_valid && beat_type==2
                    && rx_words+valid_words==6 && seeds_ready;
 assign labels_finishing=labels_done || (final_label && ((label_mask|(8'b1<<beat_tile))==8'hff));
 integer i,w,byte_lane,density_index;
 always @(posedge clk) begin
  if(!rst_n) begin
   loaded<=0;busy<=0;density_done<=0;labels_done<=0;fault<=0;
   tx_state<=IDLE;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
   rx_words<=0;rx_tile<=0;rx_type<=0;density_mask<=0;label_mask<=0;
   for(i=0;i<128;i=i+1) density_sum[i]<=0;
   for(i=0;i<40;i=i+1) label_words[i]<=0;
   for(i=0;i<10;i=i+1) route_header[i]<=0;
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
    busy<=1;density_done<=0;labels_done<=0;fault<=0;loaded<=0;
    tx_state<=LANDMARKS;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
    rx_words<=0;density_mask<=0;label_mask<=0;
    for(i=0;i<128;i=i+1) density_sum[i]<=0;
   end else begin
    if(tx_valid && tx_ready) begin
     tx_beats<=tx_beats+1;
     if(tx_last) begin
      tx_word<=0;
      case(tx_state)
       LANDMARKS:begin tx_state<=HITS;tx_tile<=0;end
       HITS:if(tx_tile==7) tx_state<=WAIT_SEEDS;else tx_tile<=tx_tile+1;
       default:tx_state<=SENT;
      endcase
     end else tx_word<=tx_word+4;
    end
    if(tx_state==WAIT_SEEDS && seeds_ready) begin tx_state<=SEEDS;tx_word<=0;end
    if(rx_valid && rx_ready) begin
     rx_beats<=rx_beats+1;
     if(!beat_id_valid || valid_words==0 || (beat_type!=0 && beat_type!=2)) fault<=1;
     if(rx_words==0) begin
      rx_tile<=beat_tile;rx_type<=beat_type;
      if(beat_type==0 && density_mask[beat_tile]) fault<=1;
      if(beat_type==2 && (!seeds_ready || label_mask[beat_tile])) fault<=1;
     end
     if(beat_id_valid && beat_type==0) begin
      for(w=0;w<4;w=w+1) if(w<valid_words && rx_words+w>0 && rx_words+w<=32)
       for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1) begin
        density_index=(rx_words+w-1)*4+byte_lane;
        density_sum[density_index]<=density_sum[density_index]+{24'b0,rx_data[w*32+byte_lane*8+:8]};
       end
     end
     if(beat_id_valid && beat_type==2 && seeds_ready)
      for(w=0;w<4;w=w+1) if(w<valid_words && rx_words+w>0 && rx_words+w<=5)
       label_words[beat_tile*5+rx_words+w-1]<=rx_data[w*32+:32];
     if(rx_last) begin
      rx_words<=0;
      if(beat_type==0 && rx_words+valid_words==33 && beat_id_valid) begin
       density_mask<=density_mask|(8'b1<<beat_tile);
       if((density_mask|(8'b1<<beat_tile))==8'hff) density_done<=1;
      end else if(final_label) begin
       label_mask<=label_mask|(8'b1<<beat_tile);
       if(labels_finishing) begin labels_done<=1;busy<=0;end
      end else fault<=1;
     end else rx_words<=rx_words+valid_words;
    end
   end
  end
 end
endmodule

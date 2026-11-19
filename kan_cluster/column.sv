`timescale 1ns/1ps
// Live packetizer with one-write/one-read banked prefix storage. Each AIE column
// has a local replica of the 768-slot routing prefix. A same-bank pair takes
// one extra read cycle; there is no multiwrite register crossbar or event barrier.
module kan_cluster_column #(parameter integer COLUMN=0)(
 input wire clk,rst_n,start,seeds_ready,
 input wire [6:0] seed_count,input wire [511:0] seed_slots,
 input wire fill_valid,input wire [9:0] fill_base,input wire [63:0] fill_mask,
 input wire [4095:0] fill_embeddings,input wire [11:0] prefix_ready,
 input wire write_hit_map,input wire [7:0] map_hit_index,input wire [9:0] map_raw_slot,
 input wire write_route,write_id,input wire [3:0] write_index,input wire [31:0] write_data,
 output wire inputs_complete,output wire [4095:0] density_counts,output wire [1279:0] labels,
 output reg density_done,labels_done,fault,output wire labels_finishing,
 output reg [31:0] tx_beats,rx_beats,output reg [7:0] density_mask,label_mask,
 output wire [127:0] tx_data,output wire [15:0] tx_keep,output wire tx_last,tx_valid,input wire tx_ready,
 input wire [127:0] rx_data,input wire [15:0] rx_keep,input wire rx_last,rx_valid,output wire rx_ready
);
 localparam IDLE=0,LM_HEADER=1,LM_BODY=2,HIT_HEADER=3,HIT_BODY=4,WAIT_SEEDS=5,SEEDS=6,SENT=7,LM_TAIL=8,HIT_TAIL=9;
 (* ram_style="registers" *) reg [9:0] hit_source[0:159];
 reg [159:0] map_loaded;
 reg [31:0] density_sum[0:127],label_words[0:39],route_header[0:9];
 reg [4:0] output_id[0:7];
 reg busy;reg [3:0] tx_state;reg [2:0] tx_tile,rx_tile,rx_type;
 reg [8:0] tx_word;reg [5:0] rx_words;
 reg stage_valid,stage_body,stage_split,stage_last,collision_pending,stage_first,stage_tail;
 reg [31:0] carry_word,stage_header;
 reg [127:0] stage_control;reg [15:0] stage_keep;
 reg [5:0] stage_bank0,stage_bank1;reg [63:0] saved_first;
 wire space=!stage_valid || tx_ready;
 wire landmark_body=tx_state==LM_HEADER || tx_state==LM_BODY;
 wire body=landmark_body || tx_state==HIT_HEADER || tx_state==HIT_BODY;
 wire tail=tx_state==LM_TAIL || tx_state==HIT_TAIL;
 wire [9:0] source0=landmark_body ? tx_word/2 : hit_source[tx_tile*20+tx_word/2];
 wire [9:0] source1=landmark_body ? tx_word/2+1 : hit_source[tx_tile*20+tx_word/2+1];
 wire available=body && prefix_ready[source0/64] && prefix_ready[source1/64];
 wire bank_collision=source0%64==source1%64;
 wire read_request=busy && space && available;
 wire collision_begin=read_request && bank_collision && !collision_pending;
 wire issue=busy && space && (tail ||
            (tx_state==SEEDS && seeds_ready) || (available && (!bank_collision || collision_pending)));
 wire [63:0] bank_q[0:63];
 for(genvar lane=0;lane<64;lane=lane+1) begin: prefix_banks
  (* ram_style="block" *) reg [63:0] cache[0:11];
  reg [63:0] q;
  always @(posedge clk) begin
   if(fill_valid && fill_mask[lane]) cache[fill_base/64]<=fill_embeddings[lane*64+:64];
   if(read_request) begin
    if(!collision_pending && source0%64==lane) q<=cache[source0/64];
    else if(source1%64==lane) q<=cache[source1/64];
   end
  end
  assign bank_q[lane]=q;
 end
 assign tx_valid=busy && stage_valid;
 wire [127:0] pair_data={bank_q[stage_bank1],stage_split?saved_first:bank_q[stage_bank0]};
 // PLIO consumes full 128-bit interior beats. A one-word gearbox packs
 // header + 3 payload words, then carry + 3 words, and a one-word last beat.
 assign tx_data=stage_tail ? {96'b0,carry_word} : stage_body ? {pair_data[95:0],stage_first?stage_header:carry_word} : stage_control;
 assign tx_keep=stage_keep;assign tx_last=stage_last;
 assign inputs_complete=(&prefix_ready) && (&map_loaded);
 for(genvar d=0;d<128;d=d+1) begin: density_export
  assign density_counts[d*32+:32]=density_sum[d];
 end
 for(genvar d=0;d<40;d=d+1) begin: label_export
  assign labels[d*32+:32]=label_words[d];
 end
 reg [127:0] control_payload;reg [15:0] control_keep;
 integer tw,length_words;
 always @* begin
  control_payload=0;control_keep=0;length_words=0;
  if(tx_state==SEEDS) begin
   length_words=2+((seed_count+3)>>2);
   for(tw=0;tw<4;tw=tw+1) if(tx_word+tw<length_words) begin
    control_keep[tw*4+:4]=4'hf;
    if(tx_word+tw==0) control_payload[tw*32+:32]=route_header[9];
    else if(tx_word+tw==1) control_payload[tw*32+:32]=seed_count;
    else control_payload[tw*32+:32]=seed_slots[(tx_word+tw-2)*32+:32];
   end
  end
 end
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
   busy<=0;density_done<=0;labels_done<=0;fault<=0;map_loaded<=0;
   tx_state<=IDLE;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
   rx_words<=0;rx_tile<=0;rx_type<=0;density_mask<=0;label_mask<=0;
   stage_valid<=0;collision_pending<=0;stage_body<=0;stage_split<=0;stage_last<=0;stage_keep<=0;stage_first<=0;stage_tail<=0;carry_word<=0;stage_header<=0;
   for(i=0;i<128;i=i+1) density_sum[i]<=0;
   for(i=0;i<40;i=i+1) label_words[i]<=0;
   for(i=0;i<10;i=i+1) route_header[i]<=0;
   for(i=0;i<8;i=i+1) output_id[i]<=0;
  end else begin
   if(write_route) route_header[write_index]<=write_data;
   if(write_id) output_id[write_index]<=write_data[4:0];
   if(write_hit_map) begin hit_source[map_hit_index]<=map_raw_slot;map_loaded[map_hit_index]<=1;end
   if(start) begin
    busy<=1;density_done<=0;labels_done<=0;fault<=0;
    tx_state<=LM_HEADER;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
    rx_words<=0;density_mask<=0;label_mask<=0;stage_valid<=0;collision_pending<=0;
    for(i=0;i<128;i=i+1) density_sum[i]<=0;
   end else begin
    if(tx_valid && tx_ready) begin
     tx_beats<=tx_beats+1;
     if(stage_body) carry_word<=pair_data[127:96];
    end
    if(space && busy) begin
     stage_valid<=issue;
     if(collision_begin) collision_pending<=1;
     if(issue) begin
      stage_body<=body;stage_split<=collision_pending;stage_bank0<=source0%64;stage_bank1<=source1%64;
      stage_first<=tx_state==LM_HEADER || tx_state==HIT_HEADER;stage_tail<=tail;
      stage_header<=route_header[landmark_body?8:tx_tile];
      if(collision_pending) saved_first<=bank_q[source0%64];
      collision_pending<=0;stage_control<=control_payload;stage_keep<=body?16'hffff:(tail?16'h000f:control_keep);
      stage_last<=tail || (tx_state==SEEDS && tx_word+4>=length_words);
      case(tx_state)
       LM_HEADER:begin tx_state<=LM_BODY;tx_word<=4;end
       HIT_HEADER:begin tx_state<=HIT_BODY;tx_word<=4;end
       LM_BODY:if(tx_word+4>=256) tx_state<=LM_TAIL;else tx_word<=tx_word+4;
       HIT_BODY:if(tx_word+4>=40) tx_state<=HIT_TAIL;else tx_word<=tx_word+4;
       LM_TAIL:begin tx_state<=HIT_HEADER;tx_tile<=0;tx_word<=0;end
       HIT_TAIL:begin
        tx_word<=0;
        if(tx_tile==7) tx_state<=WAIT_SEEDS;
        else begin tx_tile<=tx_tile+1;tx_state<=HIT_HEADER;end
       end
       SEEDS:if(tx_word+4>=length_words) begin tx_state<=SENT;tx_word<=0;end else tx_word<=tx_word+4;
       default:begin end
      endcase
     end
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

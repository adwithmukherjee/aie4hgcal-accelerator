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
 // HIT_HEADER and HIT_BODY consume consecutive even/odd hits in each tile.
 // Each half needs one asynchronous read and one configuration write port.
 (* ram_style="distributed" *) reg [9:0] even_source[0:79];
 (* ram_style="distributed" *) reg [9:0] odd_source[0:79];
 reg [159:0] map_loaded;
 reg [31:0] density_sum[0:127],label_words[0:39],route_header[0:9];
 reg [4:0] output_id[0:7];
 reg busy;reg [3:0] tx_state;reg [2:0] tx_tile,rx_tile,rx_type;
 reg [8:0] tx_word;reg [5:0] rx_words;
 // Packet metadata takes the same command and response stages as the RAM data.
 typedef struct packed {
  logic body,split,last,first,tail;
  logic [5:0] bank0,bank1;
  logic [31:0] header;
  logic [127:0] control_data;
  logic [15:0] keep;
 } packet_meta;
 packet_meta command_meta,response_meta;
 reg command_valid,stage_valid,collision_pending;
 reg [31:0] carry_word;
 reg [63:0] saved_first;
 reg output_valid;
 reg [127:0] output_data;
 reg [15:0] output_keep;
 reg output_last;
 wire output_space=!output_valid || tx_ready;
 wire space=!stage_valid || output_space;
 wire landmark_body=tx_state==LM_HEADER || tx_state==LM_BODY;
 wire hit_body=tx_state==HIT_HEADER || tx_state==HIT_BODY;
 wire body=landmark_body || hit_body;
 wire tail=tx_state==LM_TAIL || tx_state==HIT_TAIL;
 reg [6:0] next_hit_pair;
 reg [9:0] even_slot,odd_slot;
 wire [9:0] source0=landmark_body ? tx_word/2 : even_slot;
 wire [9:0] source1=landmark_body ? tx_word/2+1 : odd_slot;
 wire available=body && prefix_ready[source0/64] && prefix_ready[source1/64];
 wire bank_collision=source0%64==source1%64;
 wire read_request=busy && available;
 wire collision_begin=space && read_request && bank_collision && !collision_pending;
 wire issue=busy && space && (tail ||
            (tx_state==SEEDS && seeds_ready) || (available && (!bank_collision || collision_pending)));
 // Prefetch pair zero while issuing the landmark tail. Each completed hit
 // pair fetches its successor, including across tile boundaries. A stall or
 // the first half of a same-bank request holds both source slots in place.
 always @(posedge clk) begin
  if(!rst_n || start) next_hit_pair<=0;
  else if(issue && (tx_state==LM_TAIL || hit_body)) begin
   even_slot<=even_source[next_hit_pair];
   odd_slot<=odd_source[next_hit_pair];
   next_hit_pair<=next_hit_pair==79 ? 0 : next_hit_pair+1'b1;
  end
 end
 // Register availability separately from bank selection so the request
 // decoder and the per-bank address decoder run in parallel.
 reg command_access;
 always @(posedge clk) begin
  if(!rst_n || start) command_access<=0;
  else if(space) command_access<=read_request;
 end
 wire [63:0] bank_q[0:63];
 for(genvar lane=0;lane<64;lane=lane+1) begin: prefix_banks
  (* ram_style="block" *) reg [63:0] cache[0:11];
  reg [63:0] q;
  wire select_first=!collision_pending && source0[5:0]==lane;
  wire selected=select_first || source1[5:0]==lane;
  wire [3:0] read_row=select_first ? source0[9:6] : source1[9:6];
  reg command_selected;
  reg [3:0] command_row;
  always @(posedge clk) if(space) begin
   command_selected<=selected;
   command_row<=read_row;
  end
  always @(posedge clk) begin
   if(fill_valid && fill_mask[lane]) cache[fill_base/64]<=fill_embeddings[lane*64+:64];
   if(space && command_access && command_selected) q<=cache[command_row];
  end
  assign bank_q[lane]=q;
 end
 assign tx_valid=busy && output_valid;
 // Decode the response bank and packet type on the RAM read edge. Only
 // selected body data participates in the output reduction.
 wire [63:0] first_parts[0:63],second_parts[0:63];
 for(genvar bank=0;bank<64;bank=bank+1) begin: response_banks
  reg first_selected,second_selected;
  always @(posedge clk) if(space && busy && command_valid) begin
   first_selected<=command_meta.body && !command_meta.split && command_meta.bank0==bank;
   second_selected<=command_meta.body && command_meta.bank1==bank;
  end
  assign first_parts[bank]=bank_q[bank] & {64{first_selected}};
  assign second_parts[bank]=bank_q[bank] & {64{second_selected}};
 end
 // Split the 64-bank reduction across the existing output register edge.
 // All groups hold their payload together when the receiver stalls.
 wire [95:0] group_payload[0:7];
 wire [31:0] group_carry[0:7];
 wire take_output=rst_n && !start && output_space && stage_valid && busy;
 for(genvar group=0;group<8;group=group+1) begin: output_groups
  reg [63:0] first,second;
  always @* begin
   first=0;
   second=0;
   for(integer i=0;i<8;i=i+1) begin
    first=first | first_parts[group*8+i];
    second=second | second_parts[group*8+i];
   end
  end
  reg [95:0] payload;
  reg [31:0] carry;
  always @(posedge clk) begin
   if(take_output) payload<={second[31:0],first};
   if(!rst_n) carry<=0;
   else if(take_output && response_meta.body) carry<=second[63:32];
  end
  assign group_payload[group]=payload;
  assign group_carry[group]=carry;
 end
 reg [95:0] body_payload;
 always @* begin
  body_payload=0;
  carry_word=0;
  for(integer group=0;group<8;group=group+1) begin
   body_payload=body_payload | group_payload[group];
   carry_word=carry_word | group_carry[group];
  end
 end
 wire [127:0] other_data=response_meta.tail ? {96'b0,carry_word} :
  response_meta.body ? {96'b0,response_meta.first?response_meta.header:carry_word} :
                       response_meta.control_data;
 always @(posedge clk) begin
  if(!rst_n || start) output_valid<=0;
  else if(output_space) begin
   output_valid<=busy && stage_valid;
   if(busy && stage_valid) begin
    output_data<=other_data | {32'b0,(response_meta.body && response_meta.split ? saved_first : 64'b0),32'b0};
    output_keep<=response_meta.keep;
    output_last<=response_meta.last;
   end
  end
 end
 assign tx_data=output_data | {body_payload,32'b0};
 assign tx_keep=output_keep;
 assign tx_last=output_last;
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
 // Each accepted return beat is decoded on the following clock. Stop accepting
 // new input while the final buffered label is committing to storage.
 reg beat_valid,beat_last,beat_seeds_ready;
 reg [127:0] beat_data;
 reg [2:0] valid_words;
 reg [2:0] incoming_words;
 always @* begin
  case(rx_keep)
   16'h000f: incoming_words=1;
   16'h00ff: incoming_words=2;
   16'h0fff: incoming_words=3;
   16'hffff: incoming_words=4;
   default: incoming_words=0;
  endcase
 end
 reg [7:0] header_matches;
 for(genvar row=0;row<8;row=row+1) begin: rx_header
  always @(posedge clk) if(rx_valid)
   header_matches[row]<=output_id[row]==rx_data[4:0];
 end
 assign rx_ready=busy && !labels_finishing;
 always @(posedge clk) begin
  if(!rst_n || start) beat_valid<=0;
  else beat_valid<=rx_valid && rx_ready;
  if(rx_valid) begin
   beat_data<=rx_data;
   valid_words<=incoming_words;
   beat_last<=rx_last;
   beat_seeds_ready<=seeds_ready;
  end
 end

 reg [2:0] beat_tile,beat_type;
 reg beat_id_valid;
 integer r;
 always @* begin
  beat_tile=rx_tile;beat_type=rx_type;beat_id_valid=1;
  if(rx_words==0) begin
   beat_type=beat_data[14:12];beat_id_valid=0;beat_tile=0;
   for(r=0;r<8;r=r+1) if(header_matches[r]) begin beat_tile=r;beat_id_valid=1;end
  end
 end
 wire final_label=beat_valid && beat_last && beat_id_valid && beat_type==2
                    && rx_words+valid_words==6 && beat_seeds_ready;
 assign labels_finishing=labels_done || (final_label && ((label_mask|(8'b1<<beat_tile))==8'hff));
 // Each payload word carries four independent landmark deltas. Decode the
 // destination word once and give every counter a local feedback adder.
 wire density_beat=beat_valid && beat_id_valid && beat_type==0;
 wire [4:0] label_word_selected;
 // Track the offset at ingress so each group can latch its word select
 // alongside the incoming beat. The buffered decoder still validates its type.
 reg [5:0] incoming_offset;
 always @(posedge clk) begin
  if(!rst_n || start) incoming_offset<=0;
  else if(rx_valid && rx_ready)
   incoming_offset<=rx_last ? 0 : incoming_offset+incoming_words;
 end
 wire [31:0] aligned_deltas[0:3];
 for(genvar phase=0;phase<4;phase=phase+1) begin: align_density_words
  wire [1:0] lane=2'(phase)-incoming_offset[1:0];
  reg [31:0] data;
  always @(posedge clk) if(rx_valid) data<=rx_data[lane*32+:32];
  assign aligned_deltas[phase]=data;
 end
 for(genvar group=0;group<32;group=group+1) begin: density_updates
  localparam integer PAYLOAD_WORD=group+1;
  wire [3:0] lane_match;
  for(genvar lane=0;lane<4;lane=lane+1) begin: lane_select
   if(PAYLOAD_WORD>=lane)
    assign lane_match[lane]=(incoming_offset==PAYLOAD_WORD-lane) && incoming_words>lane;
   else assign lane_match[lane]=0;
  end
  reg selected;
  always @(posedge clk) if(rx_valid) selected<=|lane_match;
  if(group<5) assign label_word_selected[group]=selected;
  // One clear register per four counters keeps the reset on the same
  // edge as the column clear while reducing its physical load.
  (* dont_touch="true" *) reg density_clear;
  always @(posedge clk) density_clear<=!rst_n || start;
  wire write_counts=density_beat && selected;
  wire [31:0] deltas=aligned_deltas[PAYLOAD_WORD%4];
  for(genvar octet=0;octet<4;octet=octet+1) begin: counters
   localparam integer SLOT=4*group+octet;
   always @(posedge clk) begin
    if(density_clear) density_sum[SLOT]<=0;
    else if(write_counts) density_sum[SLOT]<=density_sum[SLOT]+{24'b0,deltas[octet*8+:8]};
   end
  end
 end
 // Label and density packets use the same payload offsets and ingress alignment.
 wire label_beat=beat_valid && beat_id_valid && beat_type==2 && beat_seeds_ready;
 for(genvar tile=0;tile<8;tile=tile+1) begin: label_tiles
  for(genvar word_idx=0;word_idx<5;word_idx=word_idx+1) begin: words
   localparam integer PAYLOAD_WORD=word_idx+1;
   always @(posedge clk) begin
    if(!rst_n) label_words[tile*5+word_idx]<=0;
    else if(label_beat && beat_tile==tile && label_word_selected[word_idx])
     label_words[tile*5+word_idx]<=aligned_deltas[PAYLOAD_WORD%4];
   end
  end
 end
 integer i;
 always @(posedge clk) begin
  if(!rst_n) begin
   busy<=0;density_done<=0;labels_done<=0;fault<=0;map_loaded<=0;
   tx_state<=IDLE;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
   rx_words<=0;rx_tile<=0;rx_type<=0;density_mask<=0;label_mask<=0;
   command_valid<=0;stage_valid<=0;collision_pending<=0;response_meta<='0;
   for(i=0;i<10;i=i+1) route_header[i]<=0;
   for(i=0;i<8;i=i+1) output_id[i]<=0;
  end else begin
   if(write_route) route_header[write_index]<=write_data;
   if(write_id) output_id[write_index]<=write_data[4:0];
   if(write_hit_map) begin
    if(map_hit_index[0]) odd_source[map_hit_index[7:1]]<=map_raw_slot;
    else even_source[map_hit_index[7:1]]<=map_raw_slot;
    map_loaded[map_hit_index]<=1;
   end
   if(start) begin
    busy<=1;density_done<=0;labels_done<=0;fault<=0;
    tx_state<=LM_HEADER;tx_tile<=0;tx_word<=0;tx_beats<=0;rx_beats<=0;
    rx_words<=0;density_mask<=0;label_mask<=0;command_valid<=0;stage_valid<=0;collision_pending<=0;
   end else begin
    if(tx_valid && tx_ready) begin
     tx_beats<=tx_beats+1;
    end
    if(space && busy) begin
     stage_valid<=command_valid;
     if(command_valid) begin
      response_meta<=command_meta;
      // On a split pair q still holds the first read at this edge. The
      // second read replaces it after the edge, alongside response_meta.
      if(command_meta.split) saved_first<=bank_q[command_meta.bank0];
     end
     command_valid<=issue;
     if(collision_begin) collision_pending<=1;
     if(issue) begin
      command_meta.body<=body;command_meta.split<=collision_pending;command_meta.bank0<=source0%64;command_meta.bank1<=source1%64;
      command_meta.first<=tx_state==LM_HEADER || tx_state==HIT_HEADER;command_meta.tail<=tail;
      command_meta.header<=route_header[landmark_body?8:tx_tile];
      collision_pending<=0;command_meta.control_data<=control_payload;command_meta.keep<=body?16'hffff:(tail?16'h000f:control_keep);
      command_meta.last<=tail || (tx_state==SEEDS && tx_word+4>=length_words);
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
    if(rx_valid && rx_ready) rx_beats<=rx_beats+1;
    if(beat_valid) begin
     if(!beat_id_valid || valid_words==0 || (beat_type!=0 && beat_type!=2)) fault<=1;
     if(rx_words==0) begin
      rx_tile<=beat_tile;rx_type<=beat_type;
      if(beat_type==0 && density_mask[beat_tile]) fault<=1;
      if(beat_type==2 && (!beat_seeds_ready || label_mask[beat_tile])) fault<=1;
     end
     if(beat_last) begin
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

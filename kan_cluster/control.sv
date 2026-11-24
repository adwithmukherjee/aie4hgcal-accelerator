`timescale 1ns/1ps
// 8000 raw hits -> 64 PL KAN lanes -> live per-column packets -> 32 AIE workers.
// All model evaluation, landmark availability, seed geometry and communication
// occur after start. No embedding is supplied by the CPU.
module kan_cluster_control #(parameter bit CAPTURE_EMBEDDINGS=1) (
 input wire ap_clk,ap_rst_n,
 input wire [17:0] s_axi_control_awaddr,input wire s_axi_control_awvalid,output wire s_axi_control_awready,
 input wire [31:0] s_axi_control_wdata,input wire [3:0] s_axi_control_wstrb,
 input wire s_axi_control_wvalid,output wire s_axi_control_wready,
 output reg [1:0] s_axi_control_bresp,output reg s_axi_control_bvalid,input wire s_axi_control_bready,
 input wire [17:0] s_axi_control_araddr,input wire s_axi_control_arvalid,output wire s_axi_control_arready,
 output reg [31:0] s_axi_control_rdata,output reg [1:0] s_axi_control_rresp,
 output reg s_axi_control_rvalid,input wire s_axi_control_rready,
 output wire [511:0] tx_data,output wire [63:0] tx_keep,output wire [3:0] tx_last,tx_valid,input wire [3:0] tx_ready,
 input wire [511:0] rx_data,input wire [63:0] rx_keep,input wire [3:0] rx_last,rx_valid,output wire [3:0] rx_ready
);
 reg busy,density_done,cluster_done,fault,force_64,seed_start,seed_started,geometry_started,encoder_finished;
 reg [63:0] elapsed_cycles;
 reg [31:0] density_sum[0:127],pair_sum0[0:127],pair_sum1[0:127];
 reg reduce_valid;
 reg aw_pending,w_pending;
 reg [3:0] read_pending;
 reg [17:0] aw_address,ar_address;
 reg [31:0] write_data;reg [3:0] strobes;
 wire commit=aw_pending && w_pending && !s_axi_control_bvalid;
 wire full_write=strobes==15;
 reg [13:0] roles_loaded;reg [11:0] prefix_ready;
 reg [639:0] role_hits_seen;reg [127:0] role_landmarks_seen;
 reg [127:0] ids_loaded;
 reg [39:0] routes_loaded;reg [31:0] outputs_loaded;
 reg [4095:0] landmark_hit_ids;
 wire encoder_ready,encoder_busy,encoder_done,load_ready,out_valid,out_last;
 wire [13:0] raw_loaded;
 wire [31:0] encoder_cycles;
 wire [4095:0] embeddings;wire [12:0] base_id;wire [63:0] mask;
 reg [31:0] encoded_count;
 // The last role commits before BVALID. The next AW/W can handshake two
 // edges later, so both reduction stages settle before START commits.
 wire [767:0] role_seen={role_landmarks_seen,role_hits_seen};
 reg [23:0] role_groups_full;
 for(genvar group_idx=0;group_idx<24;group_idx=group_idx+1) begin: role_groups
  always @(posedge ap_clk) role_groups_full[group_idx]<=&role_seen[group_idx*32+:32];
 end
 reg roles_complete;
 // Capture the control-word decode with WDATA so it stays valid through
 // independent AW/W arrival, response stalls, and a pending raw-bank drain.
 reg start_word,clear_word;
 always @(posedge ap_clk) if(s_axi_control_wvalid && s_axi_control_wready) begin
  start_word<=s_axi_control_wdata==32'd1 && s_axi_control_wstrb==4'hf;
  clear_word<=s_axi_control_wdata==32'd2 && s_axi_control_wstrb==4'hf;
 end
 wire start_request=commit && aw_address==0 && start_word && !busy;
 // A START immediately after the final raw write can arrive while the bank
 // pipeline is draining. Keep that transaction pending through the last strobe.
 wire wait_for_raw_drain=start_request && raw_loaded==8000 && !encoder_busy && !encoder_ready;
 wire start=start_request && encoder_ready
            && roles_complete && (&ids_loaded) && (&routes_loaded) && (&outputs_loaded);
 wire clear_load=commit && aw_address==0 && clear_word && !busy;
 always @(posedge ap_clk) begin
  if(!ap_rst_n || clear_load) roles_complete<=0;
  else roles_complete<=roles_loaded==768 && (&role_groups_full);
 end
 wire raw_write=commit && full_write && !busy && aw_address==18'h08000+raw_loaded*4 && raw_loaded<8000;
 // This disjoint AXI window needs no role validation. Stage the data with
 // its word selects so each 32-bit ID has a local registered enable.
 wire landmark_id_write=commit && full_write && !busy && aw_address[17:9]==(18'h3000>>9) && aw_address[1:0]==0;
 reg [31:0] landmark_id_data;
 always @(posedge ap_clk) landmark_id_data<=write_data;
 for(genvar slot=0;slot<128;slot=slot+1) begin: landmark_id_words
  reg write_enable;
  always @(posedge ap_clk) begin
   write_enable<=ap_rst_n && landmark_id_write && aw_address[8:2]==slot;
   if(!ap_rst_n) landmark_hit_ids[slot*32+:32]<=0;
   else if(write_enable) landmark_hit_ids[slot*32+:32]<=landmark_id_data;
   if(!ap_rst_n || clear_load) ids_loaded[slot]<=0;
   else if(write_enable) ids_loaded[slot]<=1;
  end
 end
 // A role transaction retains both AXI payloads through validation and commit.
 // The slave accepts no other write between the W handshake and its response.
 reg role_checking,role_pending,role_write;
 wire role_lookup=commit && !role_checking && !role_pending && aw_address[17:12]==6'h20;
 wire role_address=aw_address[1:0]==0 && aw_address[11:2]==roles_loaded && roles_loaded<768;
 // Slots 0..127 must carry their own landmark ID. The sequential address
 // check makes a duplicate landmark impossible in an accepted transaction.
 reg [19:0] bank_hit_seen;
 wire hit_valid=!write_data[17] || (write_data[9:0]<640 && !bank_hit_seen[write_data[9:5]]);
 wire role_valid=full_write && !busy && role_address && write_data[31:19]==0 && hit_valid &&
                 (roles_loaded<128 ? write_data[18] && write_data[16:10]==roles_loaded : !write_data[18]);
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin role_checking<=0;role_pending<=0;role_write<=0;end
  else begin
   role_checking<=role_lookup;role_pending<=role_checking;role_write<=role_checking && role_valid;
  end
 end

 reg [31:0] role_bit_mask;
 always @(posedge ap_clk) role_bit_mask<=32'b1 << write_data[4:0];
 for(genvar bank=0;bank<20;bank=bank+1) begin: hit_role_banks
  wire [31:0] bits=role_hits_seen[bank*32+:32];
  reg set_bank;
  always @(posedge ap_clk) begin
   if(role_lookup) bank_hit_seen[bank]<=bits[write_data[4:0]];
   set_bank<=ap_rst_n && role_checking && role_valid && write_data[17] && write_data[9:5]==bank;
   if(!ap_rst_n || clear_load) role_hits_seen[bank*32+:32]<=0;
   else if(set_bank) role_hits_seen[bank*32+:32]<=bits | role_bit_mask;
  end
 end
 kan_event #(.LANES(64),.GATE_IDLE(0),.EXCLUSIVE_LOAD_START(1),.PIPELINE_WRITE(1)) encoder(.clk(ap_clk),.rst_n(ap_rst_n),.clear_load(clear_load),
  .load_valid(raw_write),.load_ready(load_ready),.load_hit(write_data),.start_valid(start),.start_ready(encoder_ready),
  .event_count(14'd8000),.busy(encoder_busy),.done(encoder_done),.cycles(encoder_cycles),.loaded_count(raw_loaded),
  .out_valid(out_valid),.out_ready(1'b1),.out_embeddings(embeddings),.out_base_id(base_id),.out_mask(mask),.out_last(out_last));
 // The seed selector consumes the first two rows in both targets.
 wire [8191:0] landmark_vectors;
 for(genvar lane=0;lane<64;lane=lane+1) begin: landmark_banks
  reg [63:0] landmark_pair[0:1];
  always @(posedge ap_clk) if(out_valid && mask[lane] && base_id<128)
   landmark_pair[base_id/64]<=embeddings[lane*64+:64];
  for(genvar row=0;row<2;row=row+1) assign landmark_vectors[(row*64+lane)*64+:64]=landmark_pair[row];
 end
 // Only the validation build stores a full-event copy for AXI readback.
 wire [63:0] capture_read[0:63];
 wire [17:0] capture_hit=(s_axi_control_araddr-18'h10000)>>3;
 for(genvar lane=0;lane<(CAPTURE_EMBEDDINGS ? 64 : 0);lane=lane+1) begin: banks
  (* ram_style="block" *) reg [63:0] capture[0:124];
  reg [63:0] read_q;
  always @(posedge ap_clk) begin
   if(out_valid && mask[lane]) capture[base_id/64]<=embeddings[lane*64+:64];
   if(s_axi_control_arvalid && s_axi_control_arready && s_axi_control_araddr>=18'h10000
      && s_axi_control_araddr<18'h1fa00 && cluster_done && !busy) read_q<=capture[capture_hit/64];
  end
  assign capture_read[lane]=read_q;
 end
 wire [3:0] landmarks_ready={4{&prefix_ready[1:0]}};
 wire [16383:0] partial_counts;
 wire [5119:0] labels;
 wire [3:0] column_density_done,column_labels_done,column_fault,column_labels_finishing,inputs_complete;
 wire [3:0] column_start_pending;
 wire [127:0] tx_beats,rx_beats;wire [31:0] tile_density_masks,tile_label_masks;
 wire [4095:0] final_counts;
 for(genvar d=0;d<128;d=d+1) assign final_counts[d*32+:32]=density_sum[d];
 wire prepare=busy && (&landmarks_ready) && !geometry_started;
 wire seeds_done,seed_overflow;wire [6:0] seed_count;wire [511:0] seed_slots;wire [2047:0] seed_hit_ids;
 seed_select select_seeds(.clk(ap_clk),.rst_n(ap_rst_n),.prepare(prepare),.start(seed_start),.force_64(force_64),
  .densities(final_counts),.landmarks(landmark_vectors),.landmark_hit_ids(landmark_hit_ids),
  .done(seeds_done),.overflow(seed_overflow),.seed_count(seed_count),.seed_slots(seed_slots),.seed_hit_ids(seed_hit_ids));
 wire seeds_ready=seeds_done && seed_started && !seed_start;
 // The extra word preserves byte-offset reads that span two adjacent columns.
 wire [5151:0] padded_labels={32'bx,labels};
 wire [31:0] label_read[0:3],partial_read[0:3];
 wire [31:0] density_read,slot_read,id_read;
 kan_cluster_read_window #(.BASE('h2000),.WORDS(128)) density_window
  (ap_clk,ar_address,{32'bx,final_counts},density_read);
 kan_cluster_read_window #(.BASE('h2400),.WORDS(16),.BYTE_OFFSET(1)) slot_window
  (ap_clk,ar_address,{32'bx,seed_slots},slot_read);
 kan_cluster_read_window #(.BASE('h2500),.WORDS(64),.BYTE_OFFSET(1)) id_window
  (ap_clk,ar_address,{32'bx,seed_hit_ids},id_read);
 // A newly available row first enters the column's registered read command.
 // Commit its buffered write on that edge, one clock before the RAM read.
 reg [9:0] prefix_fill_base;
 always @(posedge ap_clk) begin
  prefix_fill_base<=base_id[9:0];
 end
 for(genvar pair=0;pair<2;pair=pair+1) begin: prefix_write_pairs
  (* dont_touch="true" *) reg [4095:0] data;
  (* dont_touch="true" *) reg [63:0] write_enable;
  always @(posedge ap_clk) begin
   data<=embeddings;
   write_enable<=mask & {64{ap_rst_n && out_valid && base_id<768}};
  end
 end
 wire [3:0] config_column_write;
 for(genvar col=0;col<4;col=col+1) begin: columns
  kan_cluster_read_window #(.BASE('h1000+col*160),.WORDS(40),.BYTE_OFFSET(1)) label_window
   (ap_clk,ar_address,padded_labels[col*1280+:1312],label_read[col]);
  kan_cluster_read_window #(.BASE('h4000+col*1024),.WORDS(128)) partial_window
   (ap_clk,ar_address,{32'bx,partial_counts[col*4096+:4096]},partial_read[col]);
  // Capture the destination with AW, independently of the W channel.
  reg [9:0] route_select;
  reg [7:0] output_select;
  wire config_commit=commit && full_write && !busy;
  for(genvar word_idx=0;word_idx<10;word_idx=word_idx+1) begin: route_words
   always @(posedge ap_clk) begin
    if(s_axi_control_awvalid && s_axi_control_awready)
     route_select[word_idx]<=s_axi_control_awaddr==18'h440+col*256+4*word_idx;
    if(!ap_rst_n) routes_loaded[col*10+word_idx]<=0;
    else if(config_commit && route_select[word_idx]) routes_loaded[col*10+word_idx]<=1;
   end
  end
  for(genvar word_idx=0;word_idx<8;word_idx=word_idx+1) begin: output_words
   always @(posedge ap_clk) begin
    if(s_axi_control_awvalid && s_axi_control_awready)
     output_select[word_idx]<=s_axi_control_awaddr==18'h4a0+col*256+4*word_idx;
    if(!ap_rst_n) outputs_loaded[col*8+word_idx]<=0;
    else if(config_commit && output_select[word_idx]) outputs_loaded[col*8+word_idx]<=1;
   end
  end
  wire route_write=config_commit && (|route_select);
  wire id_write=config_commit && (|output_select);
  assign config_column_write[col]=route_write || id_write;
  wire [3:0] index=route_write ? aw_address[5:2] : {1'b0,aw_address[4:2]};
  // The role checker retains the transaction until role_write. Compute the
  // column-local hit address during its existing lookup cycle.
  reg map_selected;
  reg [7:0] local_hit_index;
  always @(posedge ap_clk) if(role_lookup) begin
   map_selected<=write_data[17] && write_data[9:0]>=col*160 && write_data[9:0]<(col+1)*160;
   local_hit_index<=8'(write_data[9:0]-col*160);
  end
  // The timer and encoder start immediately. Each packet column consumes its
  // own registered pulse one edge later, before the first embedding arrives.
  (* dont_touch="true" *) reg column_start;
  always @(posedge ap_clk) column_start<=ap_rst_n && start;
  assign column_start_pending[col]=column_start;
  wire lane_density_done,lane_labels_done,lane_labels_finishing,lane_fault;
  assign column_density_done[col]=!column_start && lane_density_done;
  assign column_labels_done[col]=!column_start && lane_labels_done;
  assign column_labels_finishing[col]=!column_start && lane_labels_finishing;
  assign column_fault[col]=!column_start && lane_fault;
  kan_cluster_column #(.COLUMN(col)) lane(.clk(ap_clk),.rst_n(ap_rst_n),.start(column_start),.seeds_ready(seeds_ready),
   .seed_count(seed_count),.seed_slots(seed_slots),.fill_valid(1'b1),.fill_base(prefix_fill_base),.fill_mask(prefix_write_pairs[col/2].write_enable),
   .fill_embeddings(prefix_write_pairs[col/2].data),.prefix_ready(prefix_ready),
   .write_hit_map(role_write && map_selected),
   .map_hit_index(local_hit_index),.map_raw_slot(roles_loaded[9:0]),.write_route(route_write),.write_id(id_write),
   .write_index(index),.write_data(write_data),.inputs_complete(inputs_complete[col]),
   .density_counts(partial_counts[col*4096+:4096]),.labels(labels[col*1280+:1280]),
   .density_done(lane_density_done),.labels_done(lane_labels_done),.fault(lane_fault),
   .labels_finishing(lane_labels_finishing),.tx_beats(tx_beats[col*32+:32]),.rx_beats(rx_beats[col*32+:32]),
   .density_mask(tile_density_masks[col*8+:8]),.label_mask(tile_label_masks[col*8+:8]),
   .tx_data(tx_data[col*128+:128]),.tx_keep(tx_keep[col*16+:16]),.tx_last(tx_last[col]),.tx_valid(tx_valid[col]),.tx_ready(tx_ready[col]),
   .rx_data(rx_data[col*128+:128]),.rx_keep(rx_keep[col*16+:16]),.rx_last(rx_last[col]),.rx_valid(rx_valid[col]),.rx_ready(rx_ready[col]));
 end
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!(|read_pending) && !s_axi_control_rvalid;
 function automatic [31:0] read_scalar(input [17:0] address);
 integer col,offset;
 begin
  read_scalar=32'hdeadbeef;
  case(address)
   0:read_scalar=0;
   4:read_scalar={25'b0,(&landmarks_ready),seeds_ready,encoder_finished,(fault || (|column_fault)),cluster_done,density_done,busy};
   8:read_scalar=64;
   12:read_scalar=8000;
   16:read_scalar=elapsed_cycles[31:0];20:read_scalar=elapsed_cycles[63:32];
   24:read_scalar=encoder_cycles;28:read_scalar=raw_loaded;32:read_scalar=roles_loaded;36:read_scalar=encoded_count;
   40:read_scalar=column_density_done;44:read_scalar=column_labels_done;
   52:read_scalar=32'h4b434c31;56:read_scalar=645;
   60:read_scalar={24'b0,seed_overflow,seed_count};64:read_scalar=force_64;
   default:begin
    if(address>=18'h1000 && address<18'h1280) read_scalar=0;
    if(address>=18'h2000 && address<18'h2200) read_scalar=0;
    if(address>=18'h2400 && address<18'h2440) read_scalar=0;
    if(address>=18'h2500 && address<18'h2600) read_scalar=0;
    if(CAPTURE_EMBEDDINGS && address>=18'h10000 && address<18'h1fa00 && cluster_done && !busy) read_scalar=capture_read[((address-18'h10000)>>3)%64]>>(address[2]*32);
    for(col=0;col<4;col=col+1) begin
     offset=address-18'h400-col*256;
     case(offset)
      0:read_scalar=column_start_pending[col]?0:tx_beats[col*32+:32];4:read_scalar=column_start_pending[col]?0:rx_beats[col*32+:32];
      8:read_scalar=column_start_pending[col]?0:tile_density_masks[col*8+:8];12:read_scalar=column_start_pending[col]?0:tile_label_masks[col*8+:8];
     endcase
     if(address>=18'h4000+col*1024 && address<18'h4200+col*1024)
      read_scalar=0;
    end
   end
  endcase
 end
 endfunction
 // Scalar/status values are sampled at the same edge as the window data.
 reg [31:0] scalar_q,scalar_q2,scalar_q3;
 always @(posedge ap_clk) begin
  scalar_q<=read_scalar(ar_address);
  scalar_q2<=scalar_q;
  scalar_q3<=scalar_q2;
 end
 wire [31:0] read_result=scalar_q3 | density_read | slot_read | id_read
                       | label_read[0] | label_read[1] | label_read[2] | label_read[3]
                       | partial_read[0] | partial_read[1] | partial_read[2] | partial_read[3];
 integer j;
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   busy<=0;density_done<=0;cluster_done<=0;fault<=0;force_64<=0;seed_start<=0;seed_started<=0;geometry_started<=0;encoder_finished<=0;
   elapsed_cycles<=0;encoded_count<=0;roles_loaded<=0;role_landmarks_seen<=0;
   aw_pending<=0;w_pending<=0;read_pending<=0;reduce_valid<=0;prefix_ready<=0;
   s_axi_control_bvalid<=0;s_axi_control_bresp<=0;s_axi_control_rvalid<=0;s_axi_control_rresp<=0;s_axi_control_rdata<=0;
   for(j=0;j<128;j=j+1) begin density_sum[j]<=0;pair_sum0[j]<=0;pair_sum1[j]<=0;end
  end else begin
   seed_start<=0;
   if(out_valid) begin
    encoded_count<=encoded_count+64;
    if(base_id<768) prefix_ready[base_id/64]<=1;
    if(base_id!=encoded_count || mask!=64'hffffffffffffffff || (out_last && encoded_count!=7936)) fault<=1;
   end
   if(encoder_done) encoder_finished<=1;
   if(encoder_finished && busy && !(&inputs_complete)) fault<=1;
   if(prepare) geometry_started<=1;
   if(busy && !cluster_done) elapsed_cycles<=elapsed_cycles+1;
   if(s_axi_control_awvalid && s_axi_control_awready) begin aw_pending<=1;aw_address<=s_axi_control_awaddr;end
   if(s_axi_control_wvalid && s_axi_control_wready) begin w_pending<=1;write_data<=s_axi_control_wdata;strobes<=s_axi_control_wstrb;end
   if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
   if(commit && !role_lookup && !role_checking) begin
    aw_pending<=wait_for_raw_drain;w_pending<=wait_for_raw_drain;
    s_axi_control_bvalid<=!wait_for_raw_drain;s_axi_control_bresp<=0;
    if(start) begin
     busy<=1;density_done<=0;cluster_done<=0;fault<=0;seed_started<=0;geometry_started<=0;encoder_finished<=0;
     elapsed_cycles<=0;encoded_count<=0;reduce_valid<=0;prefix_ready<=0;
    end else if(clear_load) begin
     roles_loaded<=0;role_landmarks_seen<=0;cluster_done<=0;density_done<=0;fault<=0;encoded_count<=0;encoder_finished<=0;
    end else if(raw_write && load_ready) begin end
    else if(role_write) begin
     roles_loaded<=roles_loaded+1;
     if(write_data[18]) role_landmarks_seen[write_data[16:10]]<=1;
    end else if(aw_address==64 && full_write && !busy && write_data<=1) force_64<=write_data[0];
    else if(landmark_id_write) begin end // Committed by the word registers above.
    else begin
     if(!(|config_column_write) && !wait_for_raw_drain) begin fault<=1;s_axi_control_bresp<=2;end
    end
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   read_pending<={read_pending[2:0],s_axi_control_arvalid && s_axi_control_arready};
   if(s_axi_control_arvalid && s_axi_control_arready) ar_address<=s_axi_control_araddr;
   if(read_pending[3]) begin
    s_axi_control_rvalid<=1;s_axi_control_rresp<=0;s_axi_control_rdata<=read_result;
   end
   if(busy && !density_done && (&column_density_done)) begin
    if(!reduce_valid) begin
     for(j=0;j<128;j=j+1) begin pair_sum0[j]<=partial_counts[j*32+:32]+partial_counts[4096+j*32+:32];pair_sum1[j]<=partial_counts[8192+j*32+:32]+partial_counts[12288+j*32+:32];end
     reduce_valid<=1;
    end else begin
     for(j=0;j<128;j=j+1) density_sum[j]<=pair_sum0[j]+pair_sum1[j];
     density_done<=1;reduce_valid<=0;
    end
   end
   if(busy && density_done && !seed_started) begin seed_start<=1;seed_started<=1;end
   if(busy && !cluster_done && (&column_labels_finishing) && encoded_count==8000) begin cluster_done<=1;busy<=0;end
  end
 end
endmodule

// Each 32-byte address group selects from eight nearby words. Register the pair
// before byte alignment, then combine only locally selected data in each window.
// All window bases are 32-byte aligned and WORDS is a multiple of eight.
module kan_cluster_read_window #(
 parameter integer BASE=0, WORDS=8,
 parameter bit BYTE_OFFSET=0
)(
 input wire clk,
 input wire [17:0] address,
 input wire [WORDS*32+31:0] data,
 output reg [31:0] result
);
 localparam GROUPS=WORDS/8;
 wire [31:0] group_data[0:GROUPS-1];
 for(genvar g=0;g<GROUPS;g=g+1) begin: groups
  wire [287:0] local_words=data[g*256+:288];
  reg [63:0] pair;
  reg selected;
  reg [1:0] byte_offset;
  reg [31:0] selected_word;
  always @(posedge clk) begin
   pair<=local_words[{address[4:2],5'b0}+:64];
   selected<=address[17:5]==(BASE/32+g);
   byte_offset<=address[1:0];
   selected_word<=selected ? (BYTE_OFFSET ? pair[{byte_offset,3'b0}+:32] : pair[31:0]) : 32'b0;
  end
  assign group_data[g]=selected_word;
 end
 reg [31:0] combined;
 always @* begin
  combined=0;
  for(integer g=0;g<GROUPS;g=g+1) combined=combined|group_data[g];
 end
 always @(posedge clk) result<=combined;
endmodule

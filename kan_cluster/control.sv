`timescale 1ns/1ps
// 8000 raw hits -> 64 PL KAN lanes -> live per-column packets -> 32 AIE workers.
// All model evaluation, landmark availability, seed geometry and communication
// occur after start. No embedding is supplied by the CPU.
module kan_cluster_control(
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
 reg aw_pending,w_pending,read_pending;
 reg [17:0] aw_address,ar_address;
 reg [31:0] write_data;reg [3:0] strobes;
 wire commit=aw_pending && w_pending && !s_axi_control_bvalid;
 wire full_write=strobes==15;
 reg [13:0] roles_loaded;reg [11:0] prefix_ready;
 reg [639:0] role_hits_seen;reg [127:0] role_landmarks_seen,ids_loaded;
 reg [39:0] routes_loaded;reg [31:0] outputs_loaded;
 reg [4095:0] landmark_hit_ids;
 wire encoder_ready,encoder_busy,encoder_done,load_ready,out_valid,out_last;
 wire [13:0] raw_loaded;
 wire [31:0] encoder_cycles;
 wire [4095:0] embeddings;wire [12:0] base_id;wire [63:0] mask;
 reg [31:0] encoded_count;
 wire roles_complete=roles_loaded==768 && (&role_hits_seen) && (&role_landmarks_seen);
 wire start=commit && aw_address==0 && write_data==1 && full_write && !busy && encoder_ready
            && roles_complete && (&ids_loaded) && (&routes_loaded) && (&outputs_loaded);
 wire clear_load=commit && aw_address==0 && write_data==2 && full_write && !busy;
 wire raw_write=commit && full_write && !busy && aw_address==18'h08000+raw_loaded*4 && raw_loaded<8000;
 wire role_address=aw_address==18'h20000+roles_loaded*4 && roles_loaded<768;
 wire role_valid=write_data[31:19]==0 && (roles_loaded<128 ? (write_data[18] && write_data[16:10]==roles_loaded) : !write_data[18]) && (!write_data[17] || (write_data[9:0]<640 && !role_hits_seen[write_data[9:0]]))
                 && (!write_data[18] || !role_landmarks_seen[write_data[16:10]]);
 wire role_write=commit && full_write && !busy && role_address && role_valid;
 kan_event #(.LANES(64)) encoder(.clk(ap_clk),.rst_n(ap_rst_n),.clear_load(clear_load),
  .load_valid(raw_write),.load_ready(load_ready),.load_hit(write_data),.start_valid(start),.start_ready(encoder_ready),
  .event_count(14'd8000),.busy(encoder_busy),.done(encoder_done),.cycles(encoder_cycles),.loaded_count(raw_loaded),
  .out_valid(out_valid),.out_ready(1'b1),.out_embeddings(embeddings),.out_base_id(base_id),.out_mask(mask),.out_last(out_last));
 // Capture all 8000 outputs; only the 768-slot routing prefix is replicated
 // into the column readers. Two small landmark rows also feed PL seed geometry.
 wire [63:0] capture_read[0:63];wire [8191:0] landmark_vectors;
 wire [17:0] capture_hit=(s_axi_control_araddr-18'h10000)>>3;
 for(genvar lane=0;lane<64;lane=lane+1) begin: banks
  (* ram_style="block" *) reg [63:0] capture[0:124];
  reg [63:0] landmark_pair[0:1];reg [63:0] read_q;
  always @(posedge ap_clk) begin
   if(out_valid && mask[lane]) begin
    capture[base_id/64]<=embeddings[lane*64+:64];
    if(base_id<128) landmark_pair[base_id/64]<=embeddings[lane*64+:64];
   end
   if(s_axi_control_arvalid && s_axi_control_arready && s_axi_control_araddr>=18'h10000
      && s_axi_control_araddr<18'h1fa00 && cluster_done && !busy) read_q<=capture[capture_hit/64];
  end
  assign capture_read[lane]=read_q;
  for(genvar row=0;row<2;row=row+1) assign landmark_vectors[(row*64+lane)*64+:64]=landmark_pair[row];
 end
 wire [3:0] landmarks_ready={4{&prefix_ready[1:0]}};
 wire [16383:0] partial_counts;
 wire [5119:0] labels;
 wire [3:0] column_density_done,column_labels_done,column_fault,column_labels_finishing,inputs_complete;
 wire [127:0] tx_beats,rx_beats;wire [31:0] tile_density_masks,tile_label_masks;
 wire [4095:0] final_counts;
 for(genvar d=0;d<128;d=d+1) assign final_counts[d*32+:32]=density_sum[d];
 wire prepare=busy && (&landmarks_ready) && !geometry_started;
 wire seeds_done,seed_overflow;wire [6:0] seed_count;wire [511:0] seed_slots;wire [2047:0] seed_hit_ids;
 seed_select select_seeds(.clk(ap_clk),.rst_n(ap_rst_n),.prepare(prepare),.start(seed_start),.force_64(force_64),
  .densities(final_counts),.landmarks(landmark_vectors),.landmark_hit_ids(landmark_hit_ids),
  .done(seeds_done),.overflow(seed_overflow),.seed_count(seed_count),.seed_slots(seed_slots),.seed_hit_ids(seed_hit_ids));
 wire seeds_ready=seeds_done && seed_started && !seed_start;
 for(genvar col=0;col<4;col=col+1) begin: columns
  wire route_write=commit && full_write && !busy && aw_address>=18'h440+col*256 && aw_address<18'h468+col*256 && aw_address[1:0]==0;
  wire id_write=commit && full_write && !busy && aw_address>=18'h4a0+col*256 && aw_address<18'h4c0+col*256 && aw_address[1:0]==0;
  wire [3:0] index=route_write ? (aw_address-18'h440-col*256)>>2 : (aw_address-18'h4a0-col*256)>>2;
  kan_cluster_column #(.COLUMN(col)) lane(.clk(ap_clk),.rst_n(ap_rst_n),.start(start),.seeds_ready(seeds_ready),
   .seed_count(seed_count),.seed_slots(seed_slots),.fill_valid(out_valid && base_id<768),.fill_base(base_id[9:0]),.fill_mask(mask),
   .fill_embeddings(embeddings),.prefix_ready(prefix_ready),
   .write_hit_map(role_write && write_data[17] && write_data[9:0]/160==col),
   .map_hit_index(8'(write_data[9:0]%160)),.map_raw_slot(roles_loaded[9:0]),.write_route(route_write),.write_id(id_write),
   .write_index(index),.write_data(write_data),.inputs_complete(inputs_complete[col]),
   .density_counts(partial_counts[col*4096+:4096]),.labels(labels[col*1280+:1280]),
   .density_done(column_density_done[col]),.labels_done(column_labels_done[col]),.fault(column_fault[col]),
   .labels_finishing(column_labels_finishing[col]),.tx_beats(tx_beats[col*32+:32]),.rx_beats(rx_beats[col*32+:32]),
   .density_mask(tile_density_masks[col*8+:8]),.label_mask(tile_label_masks[col*8+:8]),
   .tx_data(tx_data[col*128+:128]),.tx_keep(tx_keep[col*16+:16]),.tx_last(tx_last[col]),.tx_valid(tx_valid[col]),.tx_ready(tx_ready[col]),
   .rx_data(rx_data[col*128+:128]),.rx_keep(rx_keep[col*16+:16]),.rx_last(rx_last[col]),.rx_valid(rx_valid[col]),.rx_ready(rx_ready[col]));
 end
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!read_pending && !s_axi_control_rvalid;
 function automatic [31:0] read_register(input [17:0] address);
 integer col,offset;
 begin
  read_register=32'hdeadbeef;
  case(address)
   0:read_register=0;
   4:read_register={25'b0,(&landmarks_ready),seeds_ready,encoder_finished,(fault || (|column_fault)),cluster_done,density_done,busy};
   8:read_register=64;
   12:read_register=8000;
   16:read_register=elapsed_cycles[31:0];20:read_register=elapsed_cycles[63:32];
   24:read_register=encoder_cycles;28:read_register=raw_loaded;32:read_register=roles_loaded;36:read_register=encoded_count;
   40:read_register=column_density_done;44:read_register=column_labels_done;
   52:read_register=32'h4b434c31;56:read_register=645;
   60:read_register={24'b0,seed_overflow,seed_count};64:read_register=force_64;
   default:begin
    if(address>=18'h1000 && address<18'h1280) read_register=labels[(address-18'h1000)*8+:32];
    if(address>=18'h2000 && address<18'h2200) read_register=density_sum[(address-18'h2000)>>2];
    if(address>=18'h2400 && address<18'h2440) read_register=seed_slots[(address-18'h2400)*8+:32];
    if(address>=18'h2500 && address<18'h2600) read_register=seed_hit_ids[(address-18'h2500)*8+:32];
    if(address>=18'h10000 && address<18'h1fa00 && cluster_done && !busy) read_register=capture_read[((address-18'h10000)>>3)%64]>>(address[2]*32);
    for(col=0;col<4;col=col+1) begin
     offset=address-18'h400-col*256;
     case(offset)
      0:read_register=tx_beats[col*32+:32];4:read_register=rx_beats[col*32+:32];
      8:read_register=tile_density_masks[col*8+:8];12:read_register=tile_label_masks[col*8+:8];
     endcase
     if(address>=18'h4000+col*1024 && address<18'h4200+col*1024)
      read_register=partial_counts[col*4096+((address-18'h4000-col*1024)>>2)*32+:32];
    end
   end
  endcase
 end
 endfunction
 integer j,col,idx;reg config_valid;
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   busy<=0;density_done<=0;cluster_done<=0;fault<=0;force_64<=0;seed_start<=0;seed_started<=0;geometry_started<=0;encoder_finished<=0;
   elapsed_cycles<=0;encoded_count<=0;roles_loaded<=0;role_hits_seen<=0;role_landmarks_seen<=0;ids_loaded<=0;routes_loaded<=0;outputs_loaded<=0;landmark_hit_ids<=0;
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
   if(commit) begin
    aw_pending<=0;w_pending<=0;s_axi_control_bvalid<=1;s_axi_control_bresp<=0;config_valid=0;
    if(start) begin
     busy<=1;density_done<=0;cluster_done<=0;fault<=0;seed_started<=0;geometry_started<=0;encoder_finished<=0;
     elapsed_cycles<=0;encoded_count<=0;reduce_valid<=0;prefix_ready<=0;
    end else if(clear_load) begin
     roles_loaded<=0;role_hits_seen<=0;role_landmarks_seen<=0;ids_loaded<=0;cluster_done<=0;density_done<=0;fault<=0;encoded_count<=0;encoder_finished<=0;
    end else if(raw_write && load_ready) begin end
    else if(role_write) begin
     roles_loaded<=roles_loaded+1;
     if(write_data[17]) role_hits_seen[write_data[9:0]]<=1;
     if(write_data[18]) role_landmarks_seen[write_data[16:10]]<=1;
    end else if(aw_address==64 && full_write && !busy && write_data<=1) force_64<=write_data[0];
    else if(aw_address>=18'h3000 && aw_address<18'h3200 && aw_address[1:0]==0 && full_write && !busy) begin
     landmark_hit_ids[(aw_address-18'h3000)*8+:32]<=write_data;ids_loaded[(aw_address-18'h3000)>>2]<=1;
    end else begin
     for(col=0;col<4;col=col+1) if(!busy && full_write && aw_address[1:0]==0) begin
      if(aw_address>=18'h440+col*256 && aw_address<18'h468+col*256) begin
       idx=(aw_address-18'h440-col*256)>>2;routes_loaded[col*10+idx]<=1;config_valid=1;
      end
      if(aw_address>=18'h4a0+col*256 && aw_address<18'h4c0+col*256) begin
       idx=(aw_address-18'h4a0-col*256)>>2;outputs_loaded[col*8+idx]<=1;config_valid=1;
      end
     end
     if(!config_valid) begin fault<=1;s_axi_control_bresp<=2;end
    end
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   if(s_axi_control_arvalid && s_axi_control_arready) begin ar_address<=s_axi_control_araddr;read_pending<=1;end
   if(read_pending) begin
    read_pending<=0;s_axi_control_rvalid<=1;s_axi_control_rresp<=0;s_axi_control_rdata<=read_register(ar_address);
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

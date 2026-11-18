`timescale 1ns/1ps
module array_control #(parameter COLUMNS=4) (
 input wire ap_clk, ap_rst_n,
 input wire [15:0] s_axi_control_awaddr, input wire s_axi_control_awvalid,
 output wire s_axi_control_awready,
 input wire [31:0] s_axi_control_wdata, input wire [3:0] s_axi_control_wstrb,
 input wire s_axi_control_wvalid, output wire s_axi_control_wready,
 output reg [1:0] s_axi_control_bresp, output reg s_axi_control_bvalid,
 input wire s_axi_control_bready,
 input wire [15:0] s_axi_control_araddr, input wire s_axi_control_arvalid,
 output wire s_axi_control_arready, output reg [31:0] s_axi_control_rdata,
 output reg [1:0] s_axi_control_rresp, output reg s_axi_control_rvalid,
 input wire s_axi_control_rready,
 output wire [COLUMNS*128-1:0] tx_data, output wire [COLUMNS*16-1:0] tx_keep,
 output wire [COLUMNS-1:0] tx_last, tx_valid, input wire [COLUMNS-1:0] tx_ready,
 input wire [COLUMNS*128-1:0] rx_data, input wire [COLUMNS*16-1:0] rx_keep,
 input wire [COLUMNS-1:0] rx_last, rx_valid, output wire [COLUMNS-1:0] rx_ready
);
 reg busy, density_done, cluster_done, fault, release_strobe, reduce_valid;
 reg [63:0] elapsed_cycles;
 reg [31:0] density_sum [0:127];
 reg [31:0] pair_sum0 [0:127], pair_sum1 [0:127];
 reg seed_start, seed_started, force_64;
 wire seeds_done, seed_overflow;
 wire [6:0] seed_count;
 wire [511:0] seed_slots;
 wire [2047:0] seed_hit_ids;
 reg [4095:0] landmark_hit_ids;
 reg [127:0] ids_loaded;
 wire [COLUMNS*8192-1:0] landmarks;
 wire [COLUMNS*1280-1:0] labels;
 wire [4095:0] final_counts;
 generate for(genvar d=0;d<128;d=d+1) begin: export_density
  assign final_counts[d*32+:32]=density_sum[d];
 end endgenerate
 seed_select select_seeds(.clk(ap_clk),.rst_n(ap_rst_n),.start(seed_start),
  .force_64(force_64),
  .densities(final_counts),.landmarks(landmarks[0+:8192]),.landmark_hit_ids(landmark_hit_ids),
  .done(seeds_done),.overflow(seed_overflow),.seed_count(seed_count),.seed_slots(seed_slots),.seed_hit_ids(seed_hit_ids));
 wire [COLUMNS-1:0] column_density_done, column_labels_done, column_fault, inputs_loaded;
 wire [COLUMNS*4096-1:0] partial_counts;
 wire [16383:0] reduction_counts={{(4-COLUMNS)*4096{1'b0}},partial_counts};
 wire [COLUMNS*32-1:0] tx_beats, rx_beats, resident_read_data;
 wire [COLUMNS*8-1:0] tile_density_masks, tile_label_masks;
 wire [COLUMNS-1:0] column_labels_finishing;
 reg aw_pending, w_pending;
 reg [15:0] aw_address;
 reg [31:0] write_data;
 reg [3:0] write_strobes;
 wire write_commit=aw_pending && w_pending && !s_axi_control_bvalid;
 wire start=write_commit && aw_address==0 && write_strobes==4'hf && write_data==1 && !busy && (&inputs_loaded) && (&ids_loaded);
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!s_axi_control_rvalid;
 reg [COLUMNS-1:0] write_resident, write_route, write_id;
 reg [9:0] write_index;
 reg config_write_valid;
 integer c;
 always @* begin
  write_resident=0; write_route=0; write_id=0; write_index=0; config_write_valid=0;
  if(write_commit && !busy && aw_address[1:0]==0) begin
   for(c=0;c<COLUMNS;c=c+1) begin
    if(aw_address>=16'h8000+c*4096 && aw_address<16'h8900+c*4096) begin
     write_resident[c]=1; write_index=(aw_address-16'h8000-c*4096)>>2; config_write_valid=1;
    end
    if(write_strobes==4'hf && aw_address>=16'h0440+c*256 && aw_address<16'h0468+c*256) begin
     write_route[c]=1; write_index=(aw_address-16'h0440-c*256)>>2; config_write_valid=1;
    end
    if(write_strobes==4'hf && aw_address>=16'h04a0+c*256 && aw_address<16'h04c0+c*256) begin
     write_id[c]=1; write_index=(aw_address-16'h04a0-c*256)>>2; config_write_valid=1;
    end
   end
  end
 end
 generate for(genvar col=0;col<COLUMNS;col=col+1) begin: columns
  column_lane lane (
   .clk(ap_clk),.rst_n(ap_rst_n),.start(start),.seeds_ready(seeds_done && seed_started && !seed_start),.seed_count(seed_count),.seed_slots(seed_slots),
   .write_resident(write_resident[col]),.write_route(write_route[col]),.write_id(write_id[col]),
   .write_index(write_index),.write_data(write_data),.write_strobes(write_strobes),
   .resident_read_index(s_axi_control_araddr[11:2]),.resident_read_data(resident_read_data[col*32+:32]),
   .landmarks(landmarks[col*8192+:8192]),.labels(labels[col*1280+:1280]),.labels_finishing(column_labels_finishing[col]),
   .inputs_loaded(inputs_loaded[col]),.density_counts(partial_counts[col*4096+:4096]),
   .density_done(column_density_done[col]),.labels_done(column_labels_done[col]),.fault(column_fault[col]),
   .tx_beats(tx_beats[col*32+:32]),.rx_beats(rx_beats[col*32+:32]),
   .density_mask(tile_density_masks[col*8+:8]),.label_mask(tile_label_masks[col*8+:8]),
   .tx_data(tx_data[col*128+:128]),.tx_keep(tx_keep[col*16+:16]),.tx_last(tx_last[col]),
   .tx_valid(tx_valid[col]),.tx_ready(tx_ready[col]),
   .rx_data(rx_data[col*128+:128]),.rx_keep(rx_keep[col*16+:16]),.rx_last(rx_last[col]),
   .rx_valid(rx_valid[col]),.rx_ready(rx_ready[col])
  );
 end endgenerate

 function automatic [31:0] read_register(input [15:0] address);
 integer col, offset;
 begin
  read_register=32'hdeadbeef;
  case(address)
   16'h0000: read_register=0;
   16'h0004: read_register={26'b0,(seeds_done && seed_started && !seed_start),cluster_done,(fault || (|column_fault)),cluster_done,density_done,busy};
   16'h0008: read_register=COLUMNS;
   16'h0010: read_register=elapsed_cycles[31:0];
   16'h0014: read_register=elapsed_cycles[63:32];
   16'h0028: read_register=column_density_done;
   16'h002c: read_register=column_labels_done;
   16'h0034: read_register=32'h434c5332;
   16'h0038: read_register=645;
   16'h003c: read_register={24'b0,seed_overflow,seed_count};
   16'h0040: read_register={31'b0,force_64};
   default: begin
    if(address>=16'h2000 && address<16'h2200) read_register=density_sum[(address-16'h2000)>>2];
    if(address>=16'h1000 && address<16'h1280) read_register=labels[(address-16'h1000)*8+:32];
    if(address>=16'h2400 && address<16'h2440) read_register=seed_slots[(address-16'h2400)*8+:32];
    if(address>=16'h2500 && address<16'h2600) read_register=seed_hit_ids[(address-16'h2500)*8+:32];
    for(col=0;col<COLUMNS;col=col+1) begin
     offset=address-16'h0400-col*256;
     case(offset)
      0: read_register=tx_beats[col*32+:32];
      4: read_register=rx_beats[col*32+:32];
      8: read_register=tile_density_masks[col*8+:8];
      12: read_register=tile_label_masks[col*8+:8];
     endcase
     if(address>=16'h4000+col*1024 && address<16'h4200+col*1024)
      read_register=partial_counts[col*4096+((address-16'h4000-col*1024)>>2)*32+:32];
     if(address>=16'h8000+col*4096 && address<16'h8900+col*4096)
      read_register=resident_read_data[col*32+:32];
    end
   end
  endcase
 end
 endfunction

 integer j;
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   busy<=0; density_done<=0; cluster_done<=0; fault<=0; release_strobe<=0; reduce_valid<=0;
   elapsed_cycles<=0; aw_pending<=0; w_pending<=0; seed_start<=0;seed_started<=0;force_64<=0;ids_loaded<=0;landmark_hit_ids<=0;
   s_axi_control_bvalid<=0; s_axi_control_bresp<=0;
   s_axi_control_rvalid<=0; s_axi_control_rresp<=0; s_axi_control_rdata<=0;
   for(j=0;j<128;j=j+1) begin density_sum[j]<=0; pair_sum0[j]<=0; pair_sum1[j]<=0; end
  end else begin
   release_strobe<=0;seed_start<=0;
   if(busy && !cluster_done) elapsed_cycles<=elapsed_cycles+1;
   if(s_axi_control_awvalid && s_axi_control_awready) begin aw_pending<=1; aw_address<=s_axi_control_awaddr; end
   if(s_axi_control_wvalid && s_axi_control_wready) begin w_pending<=1; write_data<=s_axi_control_wdata; write_strobes<=s_axi_control_wstrb; end
   if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
   if(write_commit) begin
    aw_pending<=0; w_pending<=0; s_axi_control_bvalid<=1; s_axi_control_bresp<=0;
    if(start) begin
     busy<=1; density_done<=0; cluster_done<=0; fault<=0; release_strobe<=1;
     elapsed_cycles<=0; reduce_valid<=0;seed_started<=0;ids_loaded<=0;
    end else if(aw_address==0 && write_strobes==4'hf && write_data==2 && !busy) begin
     for(j=0;j<128;j=j+1) density_sum[j]<=0;
    end else if(aw_address==16'h0040 && write_strobes==4'hf && write_data<=1 && !busy) begin
     force_64<=write_data[0];
    end else if(aw_address>=16'h3000 && aw_address<16'h3200 && aw_address[1:0]==0 && write_strobes==4'hf && !busy) begin
     landmark_hit_ids[(aw_address-16'h3000)*8+:32]<=write_data;
     ids_loaded[(aw_address-16'h3000)>>2]<=1;
    end else if(!config_write_valid) begin fault<=1; s_axi_control_bresp<=2'b10; end
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   if(s_axi_control_arvalid && s_axi_control_arready) begin
    s_axi_control_rvalid<=1; s_axi_control_rresp<=0; s_axi_control_rdata<=read_register(s_axi_control_araddr);
   end
   if(busy && !density_done && (&column_density_done)) begin
    if(COLUMNS==4) begin
     if(!reduce_valid) begin
      for(j=0;j<128;j=j+1) begin
       pair_sum0[j]<=reduction_counts[j*32+:32]+reduction_counts[4096+j*32+:32];
       pair_sum1[j]<=reduction_counts[8192+j*32+:32]+reduction_counts[12288+j*32+:32];
      end
      reduce_valid<=1;
     end else begin
      for(j=0;j<128;j=j+1) density_sum[j]<=pair_sum0[j]+pair_sum1[j];
      density_done<=1; reduce_valid<=0;
     end
    end else begin
     for(j=0;j<128;j=j+1)
      if(COLUMNS==2) density_sum[j]<=reduction_counts[j*32+:32]+reduction_counts[4096+j*32+:32];
      else density_sum[j]<=reduction_counts[j*32+:32];
     density_done<=1;
    end
   end
   if(busy && density_done && !seed_started) begin seed_start<=1;seed_started<=1;end
   // Stop on the edge storing the final label word, not a later acknowledgement.
   if(busy && !cluster_done && (&column_labels_finishing)) begin cluster_done<=1;busy<=0;end
  end
 end
endmodule

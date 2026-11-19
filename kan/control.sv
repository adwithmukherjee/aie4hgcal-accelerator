`timescale 1ns/1ps
// Standalone benchmark adapter. The capture RAM is a replaceable stream sink;
// loading/readback through AXI-Lite are deliberately outside the event timer.
module kan_control #(parameter integer LANES=128, MAX_HITS=8000) (
 input wire ap_clk,ap_rst_n,
 input wire [16:0] s_axi_control_awaddr,input wire s_axi_control_awvalid,
 output wire s_axi_control_awready,
 input wire [31:0] s_axi_control_wdata,input wire [3:0] s_axi_control_wstrb,
 input wire s_axi_control_wvalid,output wire s_axi_control_wready,
 output reg [1:0] s_axi_control_bresp,output reg s_axi_control_bvalid,
 input wire s_axi_control_bready,
 input wire [16:0] s_axi_control_araddr,input wire s_axi_control_arvalid,
 output wire s_axi_control_arready,output reg [31:0] s_axi_control_rdata,
 output reg [1:0] s_axi_control_rresp,output reg s_axi_control_rvalid,
 input wire s_axi_control_rready
);
 localparam integer DEPTH=(MAX_HITS+LANES-1)/LANES;
 reg aw_pending,w_pending,read_pending;
 reg [16:0] aw_address,ar_address;
 reg [31:0] write_data;
 reg [3:0] strobes;
 wire start_ready,load_ready,busy,done,out_valid,out_last;
 wire [31:0] cycles;
 wire [13:0] loaded;
 wire commit=aw_pending && w_pending && !s_axi_control_bvalid;
 wire full_write=strobes==4'hf;
 wire start=commit && aw_address==0 && write_data==1 && full_write;
 wire clear_load=commit && aw_address==0 && write_data==2 && full_write && !busy;
 wire load=commit && full_write && (aw_address==16 ||
  (aw_address>=17'h08000 && aw_address<17'h08000+MAX_HITS*4 &&
   aw_address==17'h08000+loaded*4));
 wire [LANES*64-1:0] embeddings;
 wire [LANES-1:0] mask;
 wire [12:0] base_id;
 reg [13:0] count;
 reg complete,fault;
 reg [31:0] first_cycles,captured,stall_cycles,accepted_groups;
 reg [31:0] stall_period;
 wire capture_ready=stall_period==0 || (cycles & (stall_period-1))!=stall_period-1;
 wire accepted=out_valid && capture_ready;
 kan_event #(.LANES(LANES),.MAX_HITS(MAX_HITS)) encoder(
  .clk(ap_clk),.rst_n(ap_rst_n),.clear_load(clear_load),
  .load_valid(load),.load_ready(load_ready),.load_hit(write_data),
  .start_valid(start),.start_ready(start_ready),.event_count(count),
  .busy(busy),.done(done),.cycles(cycles),.loaded_count(loaded),
  .out_valid(out_valid),.out_ready(capture_ready),.out_embeddings(embeddings),
  .out_base_id(base_id),.out_mask(mask),.out_last(out_last));
 wire [63:0] read_bank[0:LANES-1];
 wire [16:0] read_hit=(s_axi_control_araddr-17'h10000)>>3;
 for(genvar lane=0;lane<LANES;lane=lane+1) begin: capture_banks
  (* ram_style="block" *) reg [63:0] captured_embeddings[0:DEPTH-1];
  reg [63:0] read_data;
  always @(posedge ap_clk) begin
   if(accepted && mask[lane]) captured_embeddings[base_id/LANES]<=embeddings[lane*64+:64];
   if(s_axi_control_arvalid && s_axi_control_arready && s_axi_control_araddr>=17'h10000 && read_hit<MAX_HITS && !busy)
    read_data<=captured_embeddings[read_hit/LANES];
  end
  assign read_bank[lane]=read_data;
 end
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!read_pending && !s_axi_control_rvalid;
 integer k,valid_lanes;
 always @* begin
  valid_lanes=0;
  for(k=0;k<LANES;k=k+1) valid_lanes=valid_lanes+mask[k];
 end
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   aw_pending<=0;w_pending<=0;read_pending<=0;
   s_axi_control_bvalid<=0;s_axi_control_bresp<=0;
   s_axi_control_rvalid<=0;s_axi_control_rresp<=0;s_axi_control_rdata<=0;
   complete<=0;fault<=0;count<=0;first_cycles<=0;captured<=0;
   stall_cycles<=0;accepted_groups<=0;stall_period<=0;
  end else begin
   if(s_axi_control_awvalid && s_axi_control_awready) begin aw_pending<=1;aw_address<=s_axi_control_awaddr;end
   if(s_axi_control_wvalid && s_axi_control_wready) begin w_pending<=1;write_data<=s_axi_control_wdata;strobes<=s_axi_control_wstrb;end
   if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
   if(commit) begin
    aw_pending<=0;w_pending<=0;s_axi_control_bvalid<=1;s_axi_control_bresp<=0;
    if(start && start_ready) begin
     complete<=0;fault<=0;first_cycles<=0;captured<=0;stall_cycles<=0;accepted_groups<=0;
    end else if(clear_load) begin complete<=0;fault<=0;captured<=0;first_cycles<=0;stall_cycles<=0;accepted_groups<=0;end
    else if(aw_address==12 && full_write && !busy && write_data<=MAX_HITS) count<=write_data[13:0];
    else if(load && load_ready) begin end
    else if(aw_address==40 && full_write && !busy && (write_data==0 || (write_data>=2 && (write_data & (write_data-1))==0))) stall_period<=write_data;
    else begin s_axi_control_bresp<=2;fault<=1;end
   end
   if(out_valid && !capture_ready) stall_cycles<=stall_cycles+1;
   if(accepted) begin
    if(captured==0) first_cycles<=cycles+1;
    captured<=captured+valid_lanes;accepted_groups<=accepted_groups+1;
    if(out_last) complete<=1;
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   if(s_axi_control_arvalid && s_axi_control_arready) begin read_pending<=1;ar_address<=s_axi_control_araddr;end
   if(read_pending) begin
    read_pending<=0;s_axi_control_rvalid<=1;s_axi_control_rresp<=0;
    case(ar_address)
     0:s_axi_control_rdata<=0;
     4:s_axi_control_rdata<={29'b0,fault,complete,busy};
     8:s_axi_control_rdata<=LANES;
     12:s_axi_control_rdata<=count;
     16:s_axi_control_rdata<=loaded;
     20:s_axi_control_rdata<=cycles;
     24:s_axi_control_rdata<=first_cycles;
     28:s_axi_control_rdata<=captured;
     32:s_axi_control_rdata<=stall_cycles;
     36:s_axi_control_rdata<=accepted_groups;
     40:s_axi_control_rdata<=stall_period;
     44:s_axi_control_rdata<=32'h4b414e31;
     default: begin
      if(ar_address>=17'h10000 && ((ar_address-17'h10000)>>3)<captured && ar_address[1:0]==0 && !busy)
       s_axi_control_rdata<=read_bank[((ar_address-17'h10000)>>3)%LANES] >> (ar_address[2]*32);
      else begin s_axi_control_rdata<=32'hdeadbeef;s_axi_control_rresp<=2;end
     end
    endcase
   end
  end
 end
endmodule

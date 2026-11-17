`timescale 1ns/1ps
// One event resident in flip-flops before release. AXI-Lite traffic is untimed.
// PL counters advance every ap_clk edge, independently of stream backpressure.
module transport_pl (
 input wire ap_clk, input wire ap_rst_n,
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
 output wire [127:0] m_axis_tx_tdata, output wire [15:0] m_axis_tx_tkeep,
 output wire m_axis_tx_tlast, output wire m_axis_tx_tvalid, input wire m_axis_tx_tready,
 input wire [127:0] s_axis_rx_tdata, input wire [15:0] s_axis_rx_tkeep,
 input wire s_axis_rx_tlast, input wire s_axis_rx_tvalid, output wire s_axis_rx_tready
);
 localparam INPUT_WORDS=296, INPUT_BEATS=74, DENSITY_BEATS=8, RX_BEATS=648;
 (* ram_style="registers" *) reg [31:0] resident [0:INPUT_WORDS-1];
 reg [31:0] density_sum [0:127];
 (* ram_style="block" *) reg [127:0] distances [0:639];
 reg [INPUT_WORDS-1:0] loaded;
 reg busy, density_done, readback_done, fault, release_strobe;
 reg [6:0] tx_index;
 reg [9:0] rx_index;
 reg [63:0] elapsed_cycles;
 reg aw_pending, w_pending;
 reg [15:0] aw_address;
 reg [31:0] write_data;
 reg [3:0] write_strobes;
 integer lane, byte_index, index;
 wire write_commit=aw_pending && w_pending && !s_axi_control_bvalid;
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!s_axi_control_rvalid;
 assign m_axis_tx_tvalid=busy && tx_index<INPUT_BEATS;
 assign m_axis_tx_tdata=m_axis_tx_tvalid ? {
   resident[tx_index*4+3],resident[tx_index*4+2],resident[tx_index*4+1],resident[tx_index*4]} : 128'b0;
 assign m_axis_tx_tkeep=16'hffff;
 assign m_axis_tx_tlast=(tx_index==INPUT_BEATS-1);
 assign s_axis_rx_tready=busy && rx_index<RX_BEATS;

 function automatic [31:0] read_register(input [15:0] address);
 begin
   case(address)
    16'h0000: read_register=0;
    16'h0004: read_register={28'b0,fault,readback_done,density_done,busy};
    16'h0010: read_register=elapsed_cycles[31:0];
    16'h0014: read_register=elapsed_cycles[63:32];
    16'h0020: read_register={22'b0,rx_index};
    16'h0024: read_register={25'b0,tx_index};
    16'h0034: read_register=32'h44454e31;
    16'h0038: read_register=645;
    default: begin
     if(address>=16'h1000 && address<16'h14a0)
       read_register=resident[(address-16'h1000)>>2];
     else if(address>=16'h2000 && address<16'h4800)
       read_register=distances[(address-16'h2000)>>4][address[3:2]*32+:32];
     else if(address>=16'h5000 && address<16'h5200)
       read_register=density_sum[(address-16'h5000)>>2];
     else read_register=32'hdeadbeef;
    end
   endcase
 end
 endfunction

 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   busy<=0; density_done<=0; readback_done<=0; fault<=0; loaded<=0;
   tx_index<=0; rx_index<=0; elapsed_cycles<=0; release_strobe<=0;
   aw_pending<=0; w_pending<=0;
   s_axi_control_bvalid<=0; s_axi_control_bresp<=0;
   s_axi_control_rvalid<=0; s_axi_control_rresp<=0; s_axi_control_rdata<=0;
   for(index=0;index<128;index=index+1) density_sum[index]<=0;
  end else begin
   release_strobe<=0;
   if(busy && !density_done) elapsed_cycles<=elapsed_cycles+1;
   if(s_axi_control_awvalid && s_axi_control_awready) begin
    aw_address<=s_axi_control_awaddr; aw_pending<=1;
   end
   if(s_axi_control_wvalid && s_axi_control_wready) begin
    write_data<=s_axi_control_wdata; write_strobes<=s_axi_control_wstrb; w_pending<=1;
   end
   if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
   if(write_commit) begin
    aw_pending<=0; w_pending<=0; s_axi_control_bvalid<=1; s_axi_control_bresp<=0;
    if(aw_address==0 && write_strobes[0] && write_data==1) begin
     if(!busy && (&loaded)) begin
      busy<=1; density_done<=0; readback_done<=0; fault<=0; loaded<=0;
      tx_index<=0; rx_index<=0; elapsed_cycles<=0; release_strobe<=1;
     end else begin fault<=1; s_axi_control_bresp<=2'b10; end
    end else if(aw_address==0 && write_strobes[0] && write_data==2 && !busy) begin
     // Reset once per event, outside timing. Subsequent releases can accumulate
     // further contributions without resetting these sums.
     for(index=0;index<128;index=index+1) density_sum[index]<=0;
    end else if(aw_address>=16'h1000 && aw_address<16'h14a0 && aw_address[1:0]==0 && !busy) begin
     for(byte_index=0;byte_index<4;byte_index=byte_index+1)
      if(write_strobes[byte_index])
       resident[(aw_address-16'h1000)>>2][byte_index*8+:8]<=write_data[byte_index*8+:8];
     loaded[(aw_address-16'h1000)>>2]<=(&write_strobes);
    end else begin fault<=1; s_axi_control_bresp<=2'b10; end
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   if(s_axi_control_arvalid && s_axi_control_arready) begin
    s_axi_control_rdata<=read_register(s_axi_control_araddr);
    s_axi_control_rvalid<=1; s_axi_control_rresp<=0;
   end
   if(m_axis_tx_tvalid && m_axis_tx_tready) tx_index<=tx_index+1;
   if(s_axis_rx_tvalid && s_axis_rx_tready) begin
    rx_index<=rx_index+1;
    if(rx_index<DENSITY_BEATS) begin
     for(lane=0;lane<16;lane=lane+1)
      density_sum[rx_index*16+lane]<=density_sum[rx_index*16+lane]+{24'b0,s_axis_rx_tdata[lane*8+:8]};
     // Final additions and timer stop occur on this same PL edge.
     if(rx_index==DENSITY_BEATS-1) density_done<=1;
    end else begin
     distances[rx_index-DENSITY_BEATS]<=s_axis_rx_tdata;
     if(rx_index==RX_BEATS-1) begin busy<=0; readback_done<=1; end
    end
   end
  end
 end
endmodule

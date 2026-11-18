`timescale 1ns/1ps
module column_pl (
 input wire ap_clk, input wire ap_rst_n,
 input wire [17:0] s_axi_control_awaddr, input wire s_axi_control_awvalid,
 output wire s_axi_control_awready,
 input wire [31:0] s_axi_control_wdata, input wire [3:0] s_axi_control_wstrb,
 input wire s_axi_control_wvalid, output wire s_axi_control_wready,
 output reg [1:0] s_axi_control_bresp, output reg s_axi_control_bvalid,
 input wire s_axi_control_bready,
 input wire [17:0] s_axi_control_araddr, input wire s_axi_control_arvalid,
 output wire s_axi_control_arready, output reg [31:0] s_axi_control_rdata,
 output reg [1:0] s_axi_control_rresp, output reg s_axi_control_rvalid,
 input wire s_axi_control_rready,
 output reg [127:0] m_axis_tx_tdata, output reg [15:0] m_axis_tx_tkeep,
 output wire m_axis_tx_tlast, output wire m_axis_tx_tvalid, input wire m_axis_tx_tready,
 input wire [127:0] s_axis_rx_tdata, input wire [15:0] s_axis_rx_tkeep,
 input wire s_axis_rx_tlast, input wire s_axis_rx_tvalid, output wire s_axis_rx_tready
);
 localparam INPUT_WORDS=576;
 localparam IDLE=0, LANDMARKS=1, HITS=2, WAIT_DENSITY=3, READBACK=4, SENT=5;
 (* ram_style="registers" *) reg [31:0] resident [0:INPUT_WORDS-1];
 reg [31:0] density_sum [0:127];
 reg [31:0] route_header [0:19];
 reg [4:0] output_id [0:7];
 reg [INPUT_WORDS-1:0] loaded;
 reg [3:0] active_count;
 wire [7:0] active_mask = (9'b1 << active_count)-1;
 reg busy, density_done, readback_done, fault, release_strobe;
 reg [63:0] elapsed_cycles;
 reg [31:0] tx_beats, rx_beats;
 reg [7:0] density_mask, readback_mask;
 reg [2:0] tx_state, tx_tile;
 reg [8:0] tx_word;
 reg [11:0] rx_words;
 reg [2:0] rx_tile, rx_type;
 reg aw_pending, w_pending;
 reg [17:0] aw_address;
 reg [31:0] write_data;
 reg [3:0] write_strobes;
 wire write_commit=aw_pending && w_pending && !s_axi_control_bvalid;
 assign s_axi_control_awready=!aw_pending && !s_axi_control_bvalid;
 assign s_axi_control_wready=!w_pending && !s_axi_control_bvalid;
 assign s_axi_control_arready=!s_axi_control_rvalid;

 reg [1:0] group_index;
 reg [8:0] tx_length;
 integer tw, source_word;
 always @* begin
  case(active_count)
   1: group_index=0; 2: group_index=1; 4: group_index=2; default: group_index=3;
  endcase
  case(tx_state)
   LANDMARKS: tx_length=257;
   HITS: tx_length=41;
   READBACK: tx_length=1;
   default: tx_length=0;
  endcase
  m_axis_tx_tdata=0; m_axis_tx_tkeep=0;
  source_word=0;
  for(tw=0;tw<4;tw=tw+1) begin
   if(tx_word+tw<tx_length) begin
    m_axis_tx_tkeep[tw*4+:4]=4'hf;
    if(tx_word+tw==0) begin
     case(tx_state)
      LANDMARKS: m_axis_tx_tdata[tw*32+:32]=route_header[8+group_index];
      HITS: m_axis_tx_tdata[tw*32+:32]=route_header[tx_tile];
      READBACK: m_axis_tx_tdata[tw*32+:32]=route_header[12+tx_tile];
      default: m_axis_tx_tdata[tw*32+:32]=0;
     endcase
    end else begin
     source_word=(tx_state==LANDMARKS ? 320 : tx_tile*40)+tx_word+tw-1;
     m_axis_tx_tdata[tw*32+:32]=resident[source_word];
    end
   end
  end
 end
 assign m_axis_tx_tvalid=busy && (tx_state==LANDMARKS || tx_state==HITS || tx_state==READBACK);
 assign m_axis_tx_tlast=tx_word+4>=tx_length;
 assign s_axis_rx_tready=busy;

 // Packet IDs come from the compiled graph and are loaded before timing.
 reg [2:0] beat_tile, beat_type;
 reg beat_id_valid;
 reg [2:0] valid_words;
 integer r;
 always @* begin
  beat_tile=rx_tile; beat_type=rx_type; beat_id_valid=1;
  if(rx_words==0) begin
   beat_type=s_axis_rx_tdata[14:12]; beat_id_valid=0; beat_tile=0;
   for(r=0;r<8;r=r+1) begin
    if(r<active_count && output_id[r]==s_axis_rx_tdata[4:0]) begin
     beat_tile=r; beat_id_valid=1;
    end
   end
  end
  case(s_axis_rx_tkeep)
   16'h000f: valid_words=1;
   16'h00ff: valid_words=2;
   16'h0fff: valid_words=3;
   16'hffff: valid_words=4;
   default: valid_words=0;
  endcase
 end

 // Four independent banks sustain the four diagnostic words in each RX beat.
 // Writes happen only after the density timer has stopped.
 reg [3:0] matrix_we;
 reg [12:0] matrix_wa [0:3];
 reg [31:0] matrix_wd [0:3];
 wire [31:0] matrix_rd [0:3];
 wire [12:0] matrix_ra=(s_axi_control_araddr-18'h10000)>>4;
 integer b, rw, payload_word, bank;
 always @* begin
  matrix_we=0; payload_word=0; bank=0;
  for(b=0;b<4;b=b+1) begin matrix_wa[b]=0; matrix_wd[b]=0; end
  if(s_axis_rx_tvalid && s_axis_rx_tready && beat_id_valid && beat_type==1 && density_done) begin
   for(rw=0;rw<4;rw=rw+1) begin
    if(rw<valid_words && rx_words+rw>0 && rx_words+rw<=2560) begin
     payload_word=rx_words+rw-1; bank=payload_word%4;
     matrix_we[bank]=1;
     matrix_wa[bank]=beat_tile*640+(payload_word/4);
     matrix_wd[bank]=s_axis_rx_tdata[rw*32+:32];
    end
   end
  end
 end
 generate for(genvar mb=0;mb<4;mb=mb+1) begin: matrix_bank
  (* ram_style="block" *) reg [31:0] data [0:5119];
  always @(posedge ap_clk) if(matrix_we[mb]) data[matrix_wa[mb]]<=matrix_wd[mb];
  assign matrix_rd[mb]=data[matrix_ra];
 end endgenerate

 function automatic [31:0] read_register(input [17:0] address);
 begin
  case(address)
   18'h00000: read_register=0;
   18'h00004: read_register={28'b0,fault,readback_done,density_done,busy};
   18'h00008: read_register={28'b0,active_count};
   18'h00010: read_register=elapsed_cycles[31:0];
   18'h00014: read_register=elapsed_cycles[63:32];
   18'h00020: read_register=tx_beats;
   18'h00024: read_register=rx_beats;
   18'h00028: read_register={24'b0,density_mask};
   18'h0002c: read_register={24'b0,readback_mask};
   18'h00034: read_register=32'h434f4c31;
   18'h00038: read_register=645;
   default: begin
    if(address>=18'h01000 && address<18'h01900) read_register=resident[(address-18'h01000)>>2];
    else if(address>=18'h02000 && address<18'h02200) read_register=density_sum[(address-18'h02000)>>2];
    else if(address>=18'h10000 && address<18'h24000) read_register=matrix_rd[address[3:2]];
    else read_register=32'hdeadbeef;
   end
  endcase
 end
 endfunction

 integer i, w, byte_lane, density_index;
 always @(posedge ap_clk) begin
  if(!ap_rst_n) begin
   busy<=0; density_done<=0; readback_done<=0; fault<=0; release_strobe<=0;
   elapsed_cycles<=0; active_count<=1; loaded<=0;
   tx_state<=IDLE; tx_tile<=0; tx_word<=0; tx_beats<=0; rx_beats<=0;
   rx_words<=0; rx_tile<=0; rx_type<=0; density_mask<=0; readback_mask<=0;
   aw_pending<=0; w_pending<=0;
   s_axi_control_bvalid<=0; s_axi_control_bresp<=0;
   s_axi_control_rvalid<=0; s_axi_control_rresp<=0; s_axi_control_rdata<=0;
   for(i=0;i<128;i=i+1) density_sum[i]<=0;
   for(i=0;i<20;i=i+1) route_header[i]<=0;
   for(i=0;i<8;i=i+1) output_id[i]<=0;
  end else begin
   release_strobe<=0;
   if(busy && !density_done) elapsed_cycles<=elapsed_cycles+1;
   if(s_axi_control_awvalid && s_axi_control_awready) begin aw_pending<=1; aw_address<=s_axi_control_awaddr; end
   if(s_axi_control_wvalid && s_axi_control_wready) begin
    w_pending<=1; write_data<=s_axi_control_wdata; write_strobes<=s_axi_control_wstrb;
   end
   if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
   if(write_commit) begin
    aw_pending<=0; w_pending<=0; s_axi_control_bvalid<=1; s_axi_control_bresp<=0;
    if(aw_address==0 && write_strobes==4'hf && write_data==1 && !busy && (&loaded)) begin
     busy<=1; density_done<=0; readback_done<=0; fault<=0; release_strobe<=1; loaded<=0;
     elapsed_cycles<=0; density_mask<=0; readback_mask<=0;
     tx_state<=LANDMARKS; tx_tile<=0; tx_word<=0; tx_beats<=0; rx_beats<=0; rx_words<=0;
    end else if(aw_address==0 && write_strobes==4'hf && write_data==2 && !busy) begin
     for(i=0;i<128;i=i+1) density_sum[i]<=0;
    end else if(aw_address==8 && write_strobes==4'hf && !busy &&
                (write_data==1 || write_data==2 || write_data==4 || write_data==8)) begin
     active_count<=write_data[3:0];
    end else if(aw_address>=18'h00040 && aw_address<18'h00090 && aw_address[1:0]==0 && write_strobes==4'hf && !busy) begin
     route_header[(aw_address-18'h00040)>>2]<=write_data;
    end else if(aw_address>=18'h000a0 && aw_address<18'h000c0 && aw_address[1:0]==0 && write_strobes==4'hf && !busy) begin
     output_id[(aw_address-18'h000a0)>>2]<=write_data[4:0];
    end else if(aw_address>=18'h01000 && aw_address<18'h01900 && aw_address[1:0]==0 && !busy) begin
     for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
      if(write_strobes[byte_lane]) resident[(aw_address-18'h01000)>>2][byte_lane*8+:8]<=write_data[byte_lane*8+:8];
     loaded[(aw_address-18'h01000)>>2]<=(&write_strobes);
    end else begin fault<=1; s_axi_control_bresp<=2'b10; end
   end
   if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
   if(s_axi_control_arvalid && s_axi_control_arready) begin
    s_axi_control_rvalid<=1; s_axi_control_rresp<=0;
    s_axi_control_rdata<=read_register(s_axi_control_araddr);
   end
   if(m_axis_tx_tvalid && m_axis_tx_tready) begin
    tx_beats<=tx_beats+1;
    if(m_axis_tx_tlast) begin
     tx_word<=0;
     case(tx_state)
      LANDMARKS: begin tx_state<=HITS; tx_tile<=0; end
      HITS: if(tx_tile==active_count-1) tx_state<=WAIT_DENSITY; else tx_tile<=tx_tile+1;
      READBACK: if(tx_tile==active_count-1) tx_state<=SENT; else tx_tile<=tx_tile+1;
      default: tx_state<=SENT;
     endcase
    end else tx_word<=tx_word+4;
   end
   if(tx_state==WAIT_DENSITY && density_done) begin tx_state<=READBACK; tx_tile<=0; tx_word<=0; end
   if(s_axis_rx_tvalid && s_axis_rx_tready) begin
    rx_beats<=rx_beats+1;
    if(!beat_id_valid || valid_words==0 || (beat_type!=0 && beat_type!=1)) fault<=1;
    if(rx_words==0) begin
     rx_tile<=beat_tile; rx_type<=beat_type;
     if(beat_type==0 && density_mask[beat_tile]) fault<=1;
     if(beat_type==1 && (!density_done || readback_mask[beat_tile])) fault<=1;
    end
    if(beat_id_valid && beat_type==0) begin
     for(w=0;w<4;w=w+1) begin
      if(w<valid_words && rx_words+w>0 && rx_words+w<=32) begin
       for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1) begin
        density_index=(rx_words+w-1)*4+byte_lane;
        density_sum[density_index]<=density_sum[density_index]+{24'b0,s_axis_rx_tdata[w*32+byte_lane*8+:8]};
       end
      end
     end
    end
    if(s_axis_rx_tlast) begin
     rx_words<=0;
     if(beat_type==0 && rx_words+valid_words==33 && beat_id_valid) begin
      density_mask<=density_mask | (8'b1<<beat_tile);
      if((density_mask | (8'b1<<beat_tile))==active_mask) density_done<=1;
     end else if(beat_type==1 && rx_words+valid_words==2561 && beat_id_valid && density_done) begin
      readback_mask<=readback_mask | (8'b1<<beat_tile);
      if((readback_mask | (8'b1<<beat_tile))==active_mask) begin readback_done<=1; busy<=0; end
     end else fault<=1;
    end else rx_words<=rx_words+valid_words;
   end
  end
 end
endmodule

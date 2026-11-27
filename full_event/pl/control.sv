module event_control (
 input wire ap_clk,ap_rst_n,
 input wire [15:0] s_axi_control_awaddr,input wire s_axi_control_awvalid,output wire s_axi_control_awready,
 input wire [31:0] s_axi_control_wdata,input wire [3:0] s_axi_control_wstrb,input wire s_axi_control_wvalid,output wire s_axi_control_wready,
 output reg [1:0] s_axi_control_bresp,output reg s_axi_control_bvalid,input wire s_axi_control_bready,
 input wire [15:0] s_axi_control_araddr,input wire s_axi_control_arvalid,output wire s_axi_control_arready,
 output reg [31:0] s_axi_control_rdata,output reg [1:0] s_axi_control_rresp,output reg s_axi_control_rvalid,input wire s_axi_control_rready,
 output wire [48*128-1:0] tx_data,input wire [47:0] tx_ready,output wire [47:0] tx_valid,tx_last,
 output wire [48*16-1:0] tx_keep,input wire [48*128-1:0] rx_data,input wire [47:0] rx_last,rx_valid,
 input wire [48*16-1:0] rx_keep,output wire [47:0] rx_ready
);
 reg have_aw,have_w; reg [15:0] addr; reg [31:0] data; reg [3:0] strb;
 assign s_axi_control_awready=!have_aw && !s_axi_control_bvalid;
 assign s_axi_control_wready=!have_w && !s_axi_control_bvalid;
 wire write=have_aw && have_w;
 reg busy,done,host_fault,start;
 reg [13:0] loaded;
 reg [5:0] load_col;
 reg [7:0] load_slot;
 wire raw_write=write && !busy && strb==15 && loaded<8000 && addr==(16'h8000+loaded*4);
 wire route_write=write && !busy && strb==15 && addr>=16'h1000 && addr<16'h2800 && addr[1:0]==0 && addr[6:2]<18;
 wire release_event=write && !busy && strb==15 && addr==0 && data==1 && loaded==8000;
 wire clear=write && !busy && strb==15 && addr==0 && data==2;
 wire [47:0] density_done,label_done,fault;
 wire [47:0] ev;
 wire [63:0] enc[0:47]; wire [7:0] index_out[0:47];
 wire lm_we=ev[0] && index_out[0]<128;
 reg [63:0] landmarks[0:127];
 always @(posedge ap_clk) if(lm_we) landmarks[index_out[0][6:0]]<=enc[0];
 wire [6:0] seed_count; wire [511:0] seed_slots;
 wire select_done; reg send_seeds;
 reg [5:0] scan;
 reg [2:0] reduction_state;
 wire [39:0] partial[0:47]; wire [31:0] label_word[0:47];
 reg [15:0] read_addr;
 for(genvar c=0;c<48;c=c+1) begin: columns
   event_column #(.COL(c),.HITS(c<40?21:20)) worker(
    .clk(ap_clk),.resetn(ap_rst_n),.start(start),.send_seeds(send_seeds),
    .raw_we(raw_write && load_col==c),.raw_waddr(load_slot),.raw_word(data),
    .route_we(route_write && ((addr-16'h1000)>>7)==c),.route_addr(addr[6:2]),.route_word(data),
    .landmark_we(lm_we),.landmark_addr(index_out[0][6:0]),.landmark_word(enc[0]),
    .encoded_valid(ev[c]),.encoded_addr(index_out[c]),.encoded(enc[c]),
    .seed_count(seed_count),.seed_slots(seed_slots),
    .tx_data(tx_data[c*128+:128]),.tx_keep(tx_keep[c*16+:16]),.tx_ready(tx_ready[c]),.tx_valid(tx_valid[c]),.tx_last(tx_last[c]),
    .rx_data(rx_data[c*128+:128]),.rx_keep(rx_keep[c*16+:16]),.rx_ready(rx_ready[c]),.rx_valid(rx_valid[c]),.rx_last(rx_last[c]),
    .densities_done(density_done[c]),.labels_done(label_done[c]),.fault(fault[c]),
    .density_address(scan[4:0]),.density_out(partial[c]),.label_address(read_addr[7:2]),.label_out(label_word[c]));
 end
 reg [12:0] global_density[0:127];
 for(genvar byte_index=0;byte_index<4;byte_index=byte_index+1) begin: reduce_byte
   wire [12:0] sums[0:127];
   for(genvar c=0;c<48;c=c+1) assign sums[64+c]={3'b0,partial[c][byte_index*10+:10]};
   for(genvar pad=112;pad<128;pad=pad+1) assign sums[pad]=0;
   for(genvar n=1;n<64;n=n+1) begin
     reg [12:0] value;
     always @(posedge ap_clk) value<=sums[n*2]+sums[n*2+1];
     assign sums[n]=value;
   end
   always @(posedge ap_clk)
     if(reduction_state==2 && scan>=6 && scan<38)
       global_density[(scan-6)*4+byte_index]<=sums[1];
 end
 wire [4095:0] density_bus;
 wire [8191:0] lm_bus;
 for(genvar i=0;i<128;i=i+1) begin
   assign density_bus[i*32+:32]={19'b0,global_density[i]};
   assign lm_bus[i*64+:64]=landmarks[i];
 end
 wire prepare_geometry=ev[0] && index_out[0]==128;
 wire begin_selection=reduction_state==2 && scan==38;
 seed_select selector(.clk(ap_clk),.rst_n(ap_rst_n),.prepare(prepare_geometry),.start(begin_selection),.force_64(1'b0),
  .densities(density_bus),.landmarks(lm_bus),.landmark_hit_ids(4096'b0),.done(select_done),.overflow(),
  .seed_count(seed_count),.seed_slots(seed_slots),.seed_hit_ids());
 reg [31:0] cycles;
 always @(posedge ap_clk) begin
   if(!ap_rst_n) begin
     have_aw<=0; have_w<=0; s_axi_control_bvalid<=0; s_axi_control_bresp<=0; busy<=0; done<=0;
     loaded<=0; load_col<=0; load_slot<=0; host_fault<=0; start<=0; cycles<=0; scan<=0; reduction_state<=0; send_seeds<=0;
   end else begin
     start<=release_event;
     if(s_axi_control_awvalid && s_axi_control_awready) begin have_aw<=1; addr<=s_axi_control_awaddr; end
     if(s_axi_control_wvalid && s_axi_control_wready) begin have_w<=1; data<=s_axi_control_wdata; strb<=s_axi_control_wstrb; end
     if(s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid<=0;
     if(write) begin
       have_aw<=0; have_w<=0; s_axi_control_bvalid<=1; s_axi_control_bresp<=0;
       if(!(clear || release_event || route_write || raw_write)) begin host_fault<=1; s_axi_control_bresp<=2; end
     end
     if(clear) begin loaded<=0; load_slot<=0; load_col<=0; done<=0; host_fault<=0; end
     if(raw_write) begin
       loaded<=loaded+1'b1;
       if(load_slot==(load_col<40 ? 167 : 159)) begin load_slot<=0; load_col<=load_col+1'b1; end
       else load_slot<=load_slot+1'b1;
     end
     if(release_event) begin busy<=1; done<=0; cycles<=0; reduction_state<=0; send_seeds<=0;scan<=0;end
     else if(busy) begin
       cycles<=cycles+1'b1;
       case(reduction_state)
         0: if(!start) reduction_state<=1;
         1: if(&density_done) begin reduction_state<=2;scan<=0;end
         2: begin scan<=scan+1'b1; if(begin_selection) reduction_state<=3; end
         3: reduction_state<=4;
         4: if(select_done) begin send_seeds<=1; reduction_state<=5; end
         5: if(&label_done) begin busy<=0;done<=1;end
         default:;
       endcase
     end
   end
 end
 reg read_pending;
 assign s_axi_control_arready=!read_pending && !s_axi_control_rvalid;
 always @(posedge ap_clk) begin
   if(!ap_rst_n) begin read_pending<=0;s_axi_control_rvalid<=0;s_axi_control_rresp<=0;end
   else begin
     if(s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid<=0;
     if(s_axi_control_arvalid && s_axi_control_arready) begin read_pending<=1;read_addr<=s_axi_control_araddr;end
     if(read_pending) begin
       read_pending<=0;s_axi_control_rvalid<=1;s_axi_control_rresp<=0;
       case(read_addr)
         4:s_axi_control_rdata<={29'b0,host_fault || (|fault),done,busy};
         8:s_axi_control_rdata<=32'h38408000;
         12:s_axi_control_rdata<=loaded;
         16:s_axi_control_rdata<=cycles;
         20:s_axi_control_rdata<=seed_count;
         24:s_axi_control_rdata<=reduction_state;
         default: if(read_addr>=16'h4000 && read_addr<16'h7000) s_axi_control_rdata<=label_word[read_addr[13:8]];
           else if(read_addr>=16'h800 && read_addr<16'ha00) s_axi_control_rdata<=global_density[read_addr[8:2]];
           else s_axi_control_rdata<=0;
       endcase
     end
   end
 end
endmodule

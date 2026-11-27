module tb;
reg ap_clk=0,ap_rst_n=0;
always #2 ap_clk=~ap_clk;
reg [15:0] s_axi_control_awaddr,s_axi_control_araddr;
reg s_axi_control_awvalid=0,s_axi_control_wvalid=0,s_axi_control_arvalid=0;
reg [31:0] s_axi_control_wdata;
wire s_axi_control_awready,s_axi_control_wready,s_axi_control_arready,s_axi_control_bvalid,s_axi_control_rvalid;
wire [31:0] s_axi_control_rdata;
wire [1:0] s_axi_control_rresp,s_axi_control_bresp;
wire [3:0] s_axi_control_wstrb=15;
wire s_axi_control_bready=1,s_axi_control_rready=1;
wire [48*128-1:0] tx_data,rx_data;
wire [48*16-1:0] tx_keep,rx_keep;
wire [47:0] tx_valid,tx_ready,tx_last,rx_valid,rx_ready,rx_last;
event_control dut(.*);
task write(input [15:0] addr,input [31:0] data);
  @(negedge ap_clk); s_axi_control_awaddr=addr;s_axi_control_wdata=data;s_axi_control_awvalid=1;s_axi_control_wvalid=1;
  @(posedge ap_clk);if(!s_axi_control_awready || !s_axi_control_wready) $fatal;
  @(negedge ap_clk);s_axi_control_awvalid=0;s_axi_control_wvalid=0;
  wait(s_axi_control_bvalid);if(s_axi_control_bresp!=0) $fatal;
  @(posedge ap_clk);
endtask
task read(input [15:0] addr,output [31:0] data);
  @(negedge ap_clk);s_axi_control_araddr=addr;s_axi_control_arvalid=1;
  @(posedge ap_clk);if(!s_axi_control_arready) $fatal;
  @(negedge ap_clk);s_axi_control_arvalid=0;
  wait(s_axi_control_rvalid);data=s_axi_control_rdata;@(posedge ap_clk);
endtask
reg [31:0] raw[0:7999],routes[0:863],dens[0:127];
reg [7:0] labels[0:7999];
integer tick=0;
always @(posedge ap_clk) tick<=tick+1;
for(genvar c=0;c<48;c=c+1) begin: test_col
  localparam N=c<40?21:20;
  localparam DENS_TX=65+8*(c<40?12:11);
  localparam TXN=DENS_TX+1; // event 187 selects four seeds, one control beat
  localparam RXN=8*9+8*2;
  reg [144:0] tx[0:TXN-1],rx[0:RXN-1];
  initial begin
    $readmemh($sformatf("tx%0d.mem",c),tx);
    $readmemh($sformatf("rx%0d.mem",c),rx);
  end
  integer sent=0,received=0;
  assign tx_ready[c]=(tick+c)%7!=0;
  assign rx_valid[c]=received<RXN && (received<72 ? sent>=DENS_TX : sent==TXN);
  assign {rx_last[c],rx_keep[c*16+:16],rx_data[c*128+:128]}=rx[received%RXN];
  always @(posedge ap_clk) begin
    if(tx_valid[c] && tx_ready[c]) begin
      if(sent>=TXN || {tx_last[c],tx_keep[c*16+:16]}!==tx[sent][144:128]) $fatal(1,"TX framing col=%d beat=%d",c,sent);
      for(integer j=0;j<4;j=j+1)
        if(tx_keep[c*16+j*4] && tx_data[c*128+j*32+:32]!==tx[sent][32*j+:32]) $fatal(1,"TX data col=%d beat=%d word=%d got %h expected %h",c,sent,j,tx_data[c*128+j*32+:32],tx[sent][32*j+:32]);
      sent<=sent+1;
    end
    if(rx_ready[c] && rx_valid[c]) received<=received+1;
  end
end
integer offset=0,n;
reg [31:0] value;
initial begin
  $readmemh("wire.mem",raw);$readmemh("routes.mem",routes);$readmemh("densities.mem",dens);$readmemh("labels.mem",labels);
  repeat(4) @(negedge ap_clk);ap_rst_n=1;
  write(0,2);
  for(integer c=0;c<48;c=c+1) for(integer j=0;j<18;j=j+1) write('h1000+c*128+j*4,routes[18*c+j]);
  for(integer i=0;i<8000;i=i+1) write('h8000+4*i,raw[i]);
  write(0,1);wait(dut.done || (|dut.fault));if(|dut.fault) $fatal(1,"Column fault %h",dut.fault);
  for(integer i=0;i<128;i=i+1) begin read('h800+i*4,value);if(value!==dens[i]) $fatal(1,"density %d",i);end
  for(integer c=0;c<48;c=c+1) begin
    n=c<40?21:20;
    for(integer row=0;row<8;row=row+1) for(integer j=0;j<n;j=j+1) begin
      if(j%4==0) read('h4000+c*256+row*24+(j/4)*4,value);
      if(value[(j%4)*8+:8]!==labels[offset]) $fatal(1,"Wrong label %d",offset);
      offset=offset+1;
    end
  end
  $display("PASS PL event 187, all 8000 labels and 128 global densities, cycles=%d",dut.cycles);$finish;
end
initial begin repeat(100000) @(posedge ap_clk);$fatal(1,"timeout phase=%d",dut.reduction_state);end
endmodule

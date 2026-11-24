`timescale 1ns/1ps
module kan_cluster_tb #(parameter integer CAPTURE_EMBEDDINGS=1);
 localparam C=4;
 reg clk=0,resetn=0;always #5 clk=~clk;
 reg [17:0] awaddr=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg [31:0] wdata=0;reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;
 wire [1:0] bresp,rresp;wire [31:0] rdata;
 wire [511:0] txdata;wire [63:0] txkeep;wire [3:0] txvalid,txlast;
 reg [3:0] txready=0,rxvalid=0,rxlast=0;reg [511:0] rxdata=0;reg [63:0] rxkeep=0;wire [3:0] rxready;
 kan_cluster_control #(.CAPTURE_EMBEDDINGS(CAPTURE_EMBEDDINGS)) dut(.ap_clk(clk),.ap_rst_n(resetn),
 .s_axi_control_awaddr(awaddr),.s_axi_control_awvalid(awvalid),.s_axi_control_awready(awready),
 .s_axi_control_wdata(wdata),.s_axi_control_wstrb(wstrb),.s_axi_control_wvalid(wvalid),.s_axi_control_wready(wready),
 .s_axi_control_bresp(bresp),.s_axi_control_bvalid(bvalid),.s_axi_control_bready(bready),
 .s_axi_control_araddr(araddr),.s_axi_control_arvalid(arvalid),.s_axi_control_arready(arready),
 .s_axi_control_rdata(rdata),.s_axi_control_rresp(rresp),.s_axi_control_rvalid(rvalid),.s_axi_control_rready(rready),
 .tx_data(txdata),.tx_keep(txkeep),.tx_last(txlast),.tx_valid(txvalid),.tx_ready(txready),
 .rx_data(rxdata),.rx_keep(rxkeep),.rx_last(rxlast),.rx_valid(rxvalid),.rx_ready(rxready));
 reg [31:0] frames[0:1535],golden[0:1023],headers[0:39];
 reg [31:0] expected_cluster[0:369],expected_normal[0:369],expected_forced[0:369],landmark_ids[0:127];
 reg [31:0] raw[0:7999],roles[0:767];reg [63:0] expected_encoder[0:7999];
 integer current_frame=0,tick=0,release_tick=0;
 integer phase[0:3],tx_row[0:3],packet_word[0:3],controls[0:3];
 reg [3:0] inputs_done=0,held=0;reg [144:0] held_beat[0:3];
 time release_time,finish_time,last_column_time,first_payload_time[0:3];
 time last_role_commit,start_attempt;
 always @(posedge clk) if(resetn) begin
  if(dut.role_write && dut.roles_loaded==767) last_role_commit=$time;
  if(dut.start_request) start_attempt=$time;
 end
 reg [8191:0] path,input_path,expected_path;
 function automatic [31:0] header(input integer id,input integer kind);
 reg [31:0] v;
 begin v=(id&31)|(kind<<12)|(31<<16)|(127<<21);v[31]=~^v[30:0];header=v;end
 endfunction
 function automatic integer output_id(input integer col,input integer row);
 begin output_id=(row*3+1+col*5)%32;end
 endfunction
 task automatic write_reg(input [17:0] address,input [31:0] value,input bit bad=0);
 begin
  @(negedge clk);awaddr=address;awvalid=1;
  do @(posedge clk);while(!awready);
  @(negedge clk);awvalid=0;repeat(2) @(negedge clk);
  wdata=value;wvalid=1;do @(posedge clk);while(!wready);
  @(negedge clk);wvalid=0;wait(bvalid);repeat(2) @(negedge clk);
  if(bresp!==(bad?2'b10:2'b00)) $fatal(1,"Unexpected AXI write response at %h",address);
  bready=1;@(negedge clk);bready=0;
 end
 endtask
 // Keep BREADY asserted and offer both write channels together. Two calls
 // back-to-back put START at the earliest legal edge after the final hit.
 task automatic write_fast(input [17:0] address,input [31:0] value,input bit bad=0);
 begin
  @(negedge clk);awaddr=address;wdata=value;awvalid=1;wvalid=1;bready=1;
  @(posedge clk);if(!awready || !wready) $fatal(1,"Expected idle AXI write channels");
  @(negedge clk);awvalid=0;wvalid=0;
  do @(posedge clk);while(!bvalid);
  if(bresp!==(bad?2'b10:2'b00)) $fatal(1,"Unexpected back-to-back AXI write response at %h",address);
 end
 endtask
 task automatic read_reg(input [17:0] address,output [31:0] value);
 reg [31:0] stable;
 begin
  @(negedge clk);araddr=address;arvalid=1;do @(posedge clk);while(!arready);
  @(negedge clk);arvalid=0;araddr=~address;wait(rvalid);stable=rdata;repeat(2) @(negedge clk);
  if(rdata!==stable || !rvalid || arready) $fatal(1,"AXI read response changed under backpressure");
  value=rdata;rready=1;@(negedge clk);rready=0;
 end
 endtask
 always @(posedge dut.busy) begin
  release_time=$time;release_tick=tick;inputs_done=0;
  for(integer col=0;col<C;col=col+1) first_payload_time[col]=0;
  for(integer col=0;col<C;col=col+1) begin phase[col]=0;tx_row[col]=0;packet_word[col]=0;controls[col]=0;end
 end
 // A new event must not expose the previous event's completed columns while
 // the start pulse is in flight, or kick off the density reduction early.
 reg previous_start=0,previous_column_start=0;
 always @(posedge clk) begin
  if(resetn) begin
   if(dut.column_start_pending!=={4{previous_start}}) $fatal(1,"Column start must follow accepted START by one clock");
   if(previous_start && (!dut.busy || dut.elapsed_cycles!=0 || rxready!=0 || txvalid!=0 ||
      (|dut.column_density_done) || (|dut.column_labels_done) || (|dut.column_labels_finishing) ||
      (|dut.column_fault) || dut.reduce_valid)) $fatal(1,"Stale column state during event release");
   if(previous_column_start && (rxready!=4'hf || dut.elapsed_cycles!=1 || dut.reduce_valid))
    $fatal(1,"Column launch or density reduction at the wrong edge");
  end
  previous_column_start<=resetn && previous_start;
  previous_start<=resetn && dut.start;
 end
 always @(posedge (&dut.column_density_done)) last_column_time=$time;
 always @(posedge dut.cluster_done) finish_time=$time;
 always @(posedge dut.density_done) begin
  if(($time-last_column_time)!==(C==4?20:10)) $fatal(1,"Wrong reduction pipeline depth");
 end
 always @(negedge clk) for(integer col=0;col<C;col=col+1)
  txready[col]=((tick-release_tick+col*2)%7!=1 && (tick-release_tick+col*2)%7!=2);
 always @(posedge clk) if(resetn) begin: monitor
  integer count,offset,length,route;
  tick=tick+1;
  if(dut.cluster_done && !(&dut.column_labels_done)) $fatal(1,"Global timer ended before all columns");
  for(integer col=0;col<C;col=col+1) begin
   if(held[col] && (!txvalid[col] || {txlast[col],txkeep[col*16+:16],txdata[col*128+:128]}!==held_beat[col]))
    $fatal(1,"Column %0d TX changed under backpressure",col);
   held[col]=txvalid[col]&&!txready[col];held_beat[col]={txlast[col],txkeep[col*16+:16],txdata[col*128+:128]};
   if(txvalid[col]&&txready[col]) begin
    if(phase[col]==0 && (packet_word[col]>0 || txkeep[col*16+:16]!=16'h000f) && first_payload_time[col]==0) begin
     first_payload_time[col]=$time;
     if(dut.encoded_count>=8000) $fatal(1,"AIE payload did not overlap encoding");
    end
    count=0;
    case(phase[col])
     0:begin length=257;route=8;end
     1:begin length=41;route=tx_row[col];end
     2:begin length=2+((expected_cluster[current_frame*370+128]+3)/4);route=9;end
     default:$fatal(1,"Unexpected extra packet");
    endcase
    if(phase[col]==2 && !dut.seeds_done) $fatal(1,"Seed packet before selection");
    for(integer k=0;k<4;k=k+1) begin
     if(txkeep[col*16+k*4+:4]==15) begin
      if(packet_word[col]+count==0) begin
       if(txdata[col*128+k*32+:32]!==headers[col*10+route]) $fatal(1,"Wrong column packet header");
      end else if(phase[col]==2) begin
       if(packet_word[col]+count==1) begin
        if(txdata[col*128+k*32+:32]!==expected_cluster[current_frame*370+128]) $fatal(1,"Wrong seed count broadcast");
       end else if(txdata[col*128+k*32+:32]!==expected_cluster[current_frame*370+130+packet_word[col]+count-2]) $fatal(1,"Wrong seed ID broadcast");
      end else begin
       offset=(phase[col]==0?1280:col*320+tx_row[col]*40)+packet_word[col]+count-1;
       if(txdata[col*128+k*32+:32]!==frames[current_frame*1536+offset]) $fatal(1,"Wrong distinct hit/common landmark payload");
      end
      count=count+1;
     end else if(txkeep[col*16+k*4+:4]!=0) $fatal(1,"Partial word TKEEP");
    end
    if(count==0 || txkeep[col*16+:16]!==((17'b1<<(count*4))-1)) $fatal(1,"Noncontiguous TKEEP");
    if(txlast[col]!==(packet_word[col]+count==length)) $fatal(1,"Packet length mismatch");
    if(!txlast[col] && txkeep[col*16+:16]!=16'hffff) $fatal(1,"PLIO interior beats must be full width");
    packet_word[col]=packet_word[col]+count;
    if(txlast[col]) begin
     packet_word[col]=0;
     if(phase[col]==0) begin phase[col]=1;tx_row[col]=0;end
     else if(phase[col]==1) begin
      if(tx_row[col]==7) begin phase[col]=2;tx_row[col]=0;inputs_done[col]=1;end
      else tx_row[col]=tx_row[col]+1;
     end else begin
      controls[col]=controls[col]+1;
      phase[col]=3;
     end
    end
   end
  end
 end
 task automatic send_packet(input integer col,input integer row,input integer kind);
 integer length,count,offset,base;
 reg [127:0] beat;reg [15:0] keep;
 begin
  length=(kind==0?33:6);base=(kind==0?(col*8+row)*32:current_frame*370+210+(col*8+row)*5);
  for(offset=0;offset<length;offset=offset+4) begin
   beat=0;keep=0;count=0;
   for(integer k=0;k<4;k=k+1) if(offset+k<length) begin
    keep[k*4+:4]=15;count=count+1;
    beat[k*32+:32]=(offset+k==0?header(output_id(col,row),kind):(kind==0?golden[base+offset+k-1]:expected_cluster[base+offset+k-1]));
   end
   if(offset%28==0) repeat(3+col) @(negedge clk);
   // Forced-seed cases drive adjacent beats on consecutive clocks.
   if(offset==0 || offset%28==0 || !dut.force_64) @(negedge clk);
   rxdata[col*128+:128]=beat;rxkeep[col*16+:16]=keep;
   rxlast[col]=(offset+count==length);rxvalid[col]=1;
   do @(posedge clk);while(!rxready[col]);
   @(negedge clk);rxvalid[col]=0;
  end
 end
 endtask
 generate for(genvar col=0;col<C;col=col+1) begin: responders
  always @(posedge dut.busy) begin
   @(negedge clk);wait(inputs_done[col]);
   repeat(17+col*43) @(negedge clk);
   for(integer row=7;row>=0;row=row-1) send_packet(col,row,0);
   wait(controls[col]==1);
   repeat(37+col*11) @(negedge clk);
   for(integer row=0;row<8;row=row+1) send_packet(col,row,2);
  end
 end endgenerate
 reg [31:0] value,timed_cycles,lo,hi;
 integer event_id;reg forced;
 initial begin
  if(!$value$plusargs("DATA=%s",path)) $fatal(1,"DATA required");
  repeat(5) @(negedge clk);resetn=1;
  write_reg(0,1,1);if(dut.busy) $fatal(1,"Empty release");
  // Reset between validation and commit must discard the entire transaction.
  @(negedge clk);awaddr=18'h20000;wdata=(1<<18)|(1<<17)|159;awvalid=1;wvalid=1;
  @(negedge clk);awvalid=0;wvalid=0;
  @(negedge clk);if(!dut.role_checking || bvalid) $fatal(1,"Role lookup handshake");
  @(negedge clk);if(!dut.role_pending || bvalid) $fatal(1,"Role validation handshake");
  resetn=0;@(negedge clk);resetn=1;
  if(dut.roles_loaded!==0 || dut.role_hits_seen!==0 || dut.role_landmarks_seen!==0 ||
     dut.columns[0].lane.map_loaded!==0 || bvalid || dut.role_pending)
   $fatal(1,"Reset failed to cancel pending role");
  // Duplicate hit on the very next role write must leave both maps at slot 0.
  write_fast(18'h20000,(1<<18)|(1<<17)|159);
  write_fast(18'h20004,(1<<18)|(1<<10)|(1<<17)|159,1);
  if(dut.roles_loaded!=1 || dut.role_landmarks_seen!=1 ||
     dut.columns[0].lane.odd_source[79]!=0) $fatal(1,"Duplicate role modified the maps");
  write_fast(18'h20004,(1<<18)|(1<<10)|(1<<17)|640,1);
  write_fast(18'h20008,(1<<18)|(1<<10)|(1<<17)|160,1);
  write_fast(18'h20004,(1<<18)|(1<<17)|160,1);
  if(dut.roles_loaded!=1 || dut.role_hits_seen[160] || dut.columns[1].lane.map_loaded[0])
    $fatal(1,"Invalid role changed configuration");
  // W may arrive before AW. Change the bus after its handshake.
  @(negedge clk);wvalid=1;wdata=(1<<18)|(1<<10)|(1<<17)|160;
  @(posedge clk);if(!wready) $fatal(1,"Role data acceptance");
  @(negedge clk);wvalid=0;wdata=0;repeat(2) @(negedge clk);
  awvalid=1;awaddr=18'h20004;@(posedge clk);if(!awready) $fatal(1,"Role address acceptance");
  @(negedge clk);awvalid=0;bready=0;wait(bvalid);repeat(3) @(negedge clk);
  if(bresp!=0 || awready || wready || dut.roles_loaded!=2 || dut.role_hits_seen[160]!==1 ||
     dut.columns[1].lane.even_source[0]!=1) $fatal(1,"Role retry or stalled response");
  bready=1;@(negedge clk);bready=0;
  write_reg(0,2);
  // Reset between accepting an ID write and its local write strobe.
  @(negedge clk);awaddr=18'h3000;wdata=32'hbad0bad0;awvalid=1;wvalid=1;
  @(posedge clk);if(!awready || !wready) $fatal(1,"ID write acceptance");
  @(negedge clk);awvalid=0;wvalid=0;
  wait(bvalid);@(negedge clk);resetn=0;
  @(negedge clk);resetn=1;
  if(dut.ids_loaded!==0 || dut.landmark_hit_ids!==0) $fatal(1,"Reset failed to cancel pending ID");
  write_reg(18'h3001,32'hdeadbeef,1);
  write_reg(18'h3200,32'hdeadbeef,1);
  wstrb=7;write_reg(18'h3000,32'hdeadbeef,1);wstrb=15;
  if(dut.ids_loaded!==0 || dut.landmark_hit_ids!==0) $fatal(1,"Rejected ID modified table");
  write_fast(18'h31fc,32'h01234567);
  write_fast(18'h3000,32'h89abcdef);
  write_fast(18'h31fc,32'hfedcba98);
  @(negedge clk);bready=0;
  if(dut.ids_loaded!==((128'b1<<127)|1) || dut.landmark_hit_ids!=={32'hfedcba98,4032'b0,32'h89abcdef})
   $fatal(1,"ID data and word enable are misaligned");
  write_reg(0,2);
  if(dut.ids_loaded!==0 || dut.landmark_hit_ids[127*32+:32]!==32'hfedcba98) $fatal(1,"ID validity after clear");
  for(integer col=0;col<4;col=col+1) begin
   for(integer j=0;j<10;j=j+1) begin
    headers[col*10+j]=header((j*7+3+col)%32,j>=9?2:0);
    write_reg(18'h440+col*256+j*4,headers[col*10+j]);
   end
   for(integer j=0;j<8;j=j+1) write_reg(18'h4a0+col*256+j*4,output_id(col,j));
  end
  for(integer trial=0;trial<4;trial=trial+1) begin
   event_id=trial%2==0?187:393;forced=trial==1 || trial==2;
   $sformat(input_path,"%0s/event-%05d/wire.mem",path,event_id);$readmemh(input_path,raw);
   $sformat(input_path,"%0s/event-%05d/roles.mem",path,event_id);$readmemh(input_path,roles);
   $sformat(input_path,"%0s/event-%05d/landmark_ids.mem",path,event_id);$readmemh(input_path,landmark_ids);
   $sformat(input_path,"%0s/event-%05d/payload.mem",path,event_id);$readmemh(input_path,frames);
   $sformat(input_path,"%0s/event-%05d/tile_counts.mem",path,event_id);$readmemh(input_path,golden);
   $sformat(input_path,"%0s/event-%05d/expected.mem",path,event_id);$readmemh(input_path,expected_encoder);
   $sformat(input_path,"%0s/event-%05d/cluster_normal.mem",path,event_id);$readmemh(input_path,expected_normal);
   $sformat(input_path,"%0s/event-%05d/cluster_forced.mem",path,event_id);$readmemh(input_path,expected_forced);
   for(integer j=0;j<370;j=j+1) expected_cluster[j]=forced?expected_forced[j]:expected_normal[j];
   write_reg(0,2);write_reg(18'h40,forced);
   for(integer j=0;j<7999;j=j+1) write_reg(18'h8000+j*4,raw[j]);
   for(integer j=0;j<767;j=j+1) write_reg(18'h20000+j*4,roles[j]);
   for(integer j=0;j<(trial==3?127:128);j=j+1) write_reg(18'h3000+j*4,landmark_ids[j]);
   if(trial%2==0) begin
    write_reg(18'h20000+767*4,roles[767]);
    write_reg(0,1,1);if(dut.busy) $fatal(1,"Partial raw release");
    write_fast(18'h8000+7999*4,raw[7999]);
    write_fast(0,1);
    @(negedge clk);bready=0;
   end else begin
    write_reg(18'h8000+7999*4,raw[7999]);
    if(trial==1) begin
     write_reg(0,1,1);if(dut.busy) $fatal(1,"Partial role release");
    end
    write_reg(18'h20000+767*4,roles[767]);
    if(trial==3) begin
     write_reg(0,1,1);if(dut.busy) $fatal(1,"Missing last landmark ID");
     write_fast(18'h31fc,landmark_ids[127]);
    end
    write_fast(0,1);
    @(negedge clk);bready=0;
   end
   for(integer j=0;j<128;j=j+1)
    if(dut.landmark_hit_ids[j*32+:32]!==landmark_ids[j]) $fatal(1,"Wrong event ID in slot %0d",j);
   wait(dut.cluster_done);
   read_reg(18'h10,timed_cycles);
   if(timed_cycles!==(finish_time-release_time)/10) $fatal(1,"Timer final-write endpoint");
   read_reg(18'h18,value);if(value!=137) $fatal(1,"AIE backpressure stalled encoder");
   read_reg(18'h24,value);if(value!=8000) $fatal(1,"Not all8000 encoded");
   read_reg(18'h4,value);if(value[3] || value[0] || !value[2]) $fatal(1,"Final status fault");
   for(integer j=0;j<128;j=j+1) begin
    read_reg(18'h2000+j*4,value);if(value!==expected_cluster[j]) $fatal(1,"Density %0d",j);
   end
   read_reg(18'h3c,value);if(value[7:0]!=={expected_cluster[129][0],expected_cluster[128][6:0]}) $fatal(1,"Seed count/overflow");
   for(integer j=0;j<16;j=j+1) begin
    read_reg(18'h2400+j*4,value);if(value!==expected_cluster[130+j]) $fatal(1,"Seed slot");
   end
   for(integer j=0;j<64;j=j+1) begin
    read_reg(18'h2500+j*4,value);if(value!==expected_cluster[146+j]) $fatal(1,"Original seed identity");
   end
   for(integer j=0;j<160;j=j+1) begin
    read_reg(18'h1000+j*4,value);if(value!==expected_cluster[210+j]) $fatal(1,"Label %0d",j);
   end
   // Exercise cross-word and cross-column byte reads, plus the partial-count windows.
   for(integer col=0;col<3;col=col+1) begin
    for(integer byte_shift=1;byte_shift<4;byte_shift=byte_shift+1) begin
     read_reg(18'h1000+col*160+156+byte_shift,value);
     if(value!==32'({expected_cluster[210+(col+1)*40],expected_cluster[209+(col+1)*40]}>>(8*byte_shift)))
      $fatal(1,"Unaligned label read at column %0d",col);
    end
   end
   for(integer col=0;col<4;col=col+1) begin
    for(integer j=0;j<128;j=j+1) begin
     lo=0;
     for(integer row=0;row<8;row=row+1)
      lo=lo+((golden[(col*8+row)*32+j/4]>>(8*(j%4)))&255);
     read_reg(18'h4000+col*1024+j*4,value);
     if(value!==lo) $fatal(1,"Partial density column %0d counter %0d",col,j);
    end
    read_reg(18'h4200+col*1024,value);
    if(value!==32'hdeadbeef) $fatal(1,"Unexpected partial density in unmapped gap");
   end
   for(integer j=0;j<8000;j=j+1) begin
    read_reg(18'h10000+j*8,lo);read_reg(18'h10004+j*8,hi);
    if(CAPTURE_EMBEDDINGS) begin
     if({hi,lo}!==expected_encoder[j]) $fatal(1,"Encoder capture hit %0d",j);
    end else if({hi,lo}!==64'hdeadbeef_deadbeef) $fatal(1,"Unexpected hardware capture at %0d",j);
   end
   $display("INTEGRATION event=%0d forced=%0d encoder_hits=8000 aie_hits=640 total_cycles=%0d first_payload_cycles=%0d",event_id,forced,timed_cycles,(first_payload_time[0]-release_time)/10);
  end
  // Resident data can be replayed. Reject an ID overwrite after release.
  write_fast(0,1);@(negedge clk);bready=0;
  write_reg(18'h31fc,~landmark_ids[127],1);
  if(!dut.busy || dut.landmark_hit_ids[127*32+:32]!==landmark_ids[127]) $fatal(1,"Busy ID write changed the event");
  wait(dut.cluster_done);

  // The fixtures have padding in role slot 767. Use a map whose very
  // last AXI word supplies hit bit 639 to exercise both reduction stages.
  for(integer complete=0;complete<2;complete=complete+1) begin
   write_fast(0,2);
   if(dut.roles_complete!==0) $fatal(1,"CLEAR retained role completeness");
   for(integer j=0;j<8000;j=j+1) write_fast(18'h8000+j*4,raw[j]);
   for(integer j=0;j<128;j=j+1) write_fast(18'h3000+j*4,landmark_ids[j]);
   for(integer j=0;j<128;j=j+1) write_fast(18'h20000+j*4,(1<<18)|(j<<10));
   for(integer j=0;j<639;j=j+1) write_fast(18'h20000+(128+j)*4,(1<<17)|j);
   if(dut.roles_complete!==0 || dut.role_hits_seen[639]!==0) $fatal(1,"Incomplete map reported ready");
   write_fast(18'h20000+767*4,complete ? ((1<<17)|639) : 0);
   write_fast(0,1,!complete);
   if(start_attempt!=last_role_commit+30 || $time!=start_attempt+10 ||
      dut.roles_loaded!=768 || $countones(dut.role_hits_seen)!=639+complete ||
      !(&dut.role_landmarks_seen) || dut.roles_complete!==complete[0] ||
      dut.busy!==complete[0] || dut.encoder_busy!==complete[0])
    $fatal(1,"START response or encoder launch after final role (complete=%0d)",complete);
   if(complete && release_time+10!=$time) $fatal(1,"Timer started on wrong edge");
   @(negedge clk);bready=0;
   if(complete && (dut.encoder.issued!=64 || dut.elapsed_cycles!=1))
    $fatal(1,"Encoder did not issue the first 64 hits on time");
   $display("FINAL_ROLE words=%0d hits=%0d start_commit_gap_cycles=%0d encoder_busy=%0d",
    dut.roles_loaded,$countones(dut.role_hits_seen),(start_attempt-last_role_commit)/10,dut.encoder_busy);
  end
  $display("PASS: 64-lane KAN to four-column streaming RTL");$finish;
 end
 initial begin #100000000;$fatal(1,"Watchdog");end
endmodule

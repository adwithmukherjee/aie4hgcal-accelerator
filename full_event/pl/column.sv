// One independent PL endpoint per physical compute column.
module event_column #(parameter integer HITS=21, parameter integer COL=0)(
 input wire clk, resetn, start, send_seeds,
 input wire raw_we, input wire [7:0] raw_waddr, input wire [31:0] raw_word,
 input wire route_we, input wire [4:0] route_addr, input wire [31:0] route_word,
 input wire landmark_we, input wire [6:0] landmark_addr, input wire [63:0] landmark_word,
 output wire encoded_valid, output wire [7:0] encoded_addr, output wire [63:0] encoded,
 input wire [6:0] seed_count, input wire [511:0] seed_slots,
 output reg [127:0] tx_data, output reg [15:0] tx_keep, output reg tx_valid, tx_last,
 input wire tx_ready, input wire [127:0] rx_data, input wire [15:0] rx_keep,
 input wire rx_valid,rx_last, output wire rx_ready,
 output wire densities_done, labels_done, output reg fault,
 input wire [4:0] density_address, output wire [39:0] density_out,
 input wire [5:0] label_address, output wire [31:0] label_out
);
 localparam COUNT=8*HITS;
 localparam HIT_WORDS=(HITS==21 ? 44 : 40);
 localparam LABEL_WORDS=(HITS+3)/4;
 reg [31:0] raw[0:COUNT-1];
 reg [63:0] embeddings[0:COUNT-1], landmarks[0:127];
 reg [31:0] headers[0:9];
 reg [4:0] worker_ids[0:7];
 always @(posedge clk) begin
   if(raw_we) raw[raw_waddr]<=raw_word;
   if(landmark_we) landmarks[landmark_addr]<=landmark_word;
   if(route_we && route_addr<10) headers[route_addr]<=route_word;
   if(route_we && route_addr>=10 && route_addr<18) worker_ids[route_addr-10]<=route_word[4:0];
 end

 reg [7:0] issued;
 reg encoding;
 // kan_lane has ten registered stages (two table reads, six adder stages, two quantizers).
 reg [9:0] valid_pipe;
 reg [7:0] index_pipe[0:9];
 kan_lane encoder(.clk(clk),.ce(1'b1),.din(raw[issued]),.dout(encoded));
 assign encoded_valid=valid_pipe[9];
 assign encoded_addr=index_pipe[9];
 always @(posedge clk) begin
   if(!resetn || start) begin issued<=0; encoding<=start; valid_pipe<=0; end
   else begin
     valid_pipe<={valid_pipe[8:0],encoding};
     if(encoding) begin
       if(issued==COUNT-1) encoding<=0;
       else issued<=issued+1'b1;
     end
   end
   index_pipe[0]<=issued;
   for(integer i=1;i<10;i=i+1) index_pipe[i]<=index_pipe[i-1];
   if(encoded_valid) embeddings[encoded_addr]<=encoded;
 end

 localparam WAIT_ENCODE=0,LANDMARKS=1,HIT=2,WAIT_SEED=3,SEEDS=4,FINISHED=5;
 reg [2:0] phase,row;
 reg [8:0] word_pos;
 reg [1:0] lane;
 wire [8:0] payload_index=word_pos-1'b1;
 wire [7:0] local_hit=row*HITS+payload_index[8:1];
 wire [63:0] embedding=phase==LANDMARKS ? landmarks[payload_index[7:1]] : embeddings[local_hit];
 reg [31:0] next_word;
 always @* begin
   if(word_pos==0) next_word=headers[phase==LANDMARKS ? 8 : phase==SEEDS ? 9 : {1'b0,row}];
   else if(phase==SEEDS) next_word=(word_pos==1) ? {25'b0,seed_count} : seed_slots[(word_pos-2)*32+:32];
   else if(phase==HIT && payload_index>=HITS*2) next_word=0;
   else next_word=payload_index[0] ? embedding[63:32] : embedding[31:0];
 end
 wire end_word=word_pos==(phase==LANDMARKS ? 256 : phase==HIT ? HIT_WORDS : 1+((seed_count+3)>>2));
 always @(posedge clk) begin
   if(!resetn || start) begin phase<=WAIT_ENCODE; tx_valid<=0; tx_keep<=0; tx_last<=0; lane<=0; word_pos<=0; row<=0; end
   else if(tx_valid) begin
     if(tx_ready) begin tx_valid<=0; tx_keep<=0; tx_last<=0; end
   end else case(phase)
     WAIT_ENCODE: if(encoded_valid && encoded_addr==COUNT-1) phase<=LANDMARKS;
     WAIT_SEED: if(send_seeds) phase<=SEEDS;
     LANDMARKS,HIT,SEEDS: begin
       tx_data[lane*32+:32]<=next_word;
       tx_keep[lane*4+:4]<=4'hf;
       word_pos<=word_pos+1'b1;
       lane<=lane+1'b1;
       if(lane==3 || end_word) begin tx_valid<=1; tx_last<=end_word; lane<=0; end
       if(end_word) begin
         word_pos<=0;
         if(phase==LANDMARKS) phase<=HIT;
         else if(phase==HIT && row!=7) row<=row+1'b1;
         else phase<=phase==HIT ? WAIT_SEED : FINISHED;
       end
     end
     default:;
   endcase
 end

 reg [39:0] sums[0:31]; // Four ten-bit counts per word, at most 168 per count.
 reg [31:0] labels[0:47]; // Six-word stride per worker, including the 20-hit columns.
 assign density_out=sums[density_address];
 assign label_out=labels[label_address];
 reg [7:0] density_mask,label_mask;
 assign densities_done=&density_mask;
 assign labels_done=&label_mask;
 reg holding, last_beat, is_label;
 reg [127:0] beat;
 reg [15:0] keep;
 reg [5:0] position;
 reg [2:0] source_row;
 assign rx_ready=!holding && resetn && !start;
 wire [31:0] value=beat[31:0];
 wire final_word=last_beat && keep==16'h000f;
 reg [7:0] match_id;
 always @* for(integer i=0;i<8;i=i+1) match_id[i]=(value[4:0]==worker_ids[i]);
 always @(posedge clk) begin
   if(!resetn || start) begin
     holding<=0; position<=0; density_mask<=0; label_mask<=0; fault<=0; is_label<=0; source_row<=0;
   end else if(rx_ready && rx_valid) begin
     beat<=rx_data; keep<=rx_keep; last_beat<=rx_last; holding<=1;
     if(!(rx_keep==16'hffff || (rx_last && (rx_keep==16'h000f || rx_keep==16'h00ff || rx_keep==16'h0fff)))) fault<=1;
   end else if(holding) begin
     if(position==0) begin
       if(match_id==0 || !(value[14:12]==0 || value[14:12]==2)) fault<=1;
       for(integer i=0;i<8;i=i+1) if(match_id[i]) begin
         source_row<=i;
         if(value[14:12]==2 ? label_mask[i] : density_mask[i]) fault<=1;
       end
       is_label<=value[14:12]==2;
     end else if(is_label) begin
       if(position<=LABEL_WORDS) labels[source_row*6+position-1]<=value;
     end else begin
       for(integer i=0;i<4;i=i+1)
         sums[(position-1)&31][10*i+:10]<=value[8*i+:8]+(density_mask==0 ? 10'd0 : sums[(position-1)&31][10*i+:10]);
     end
     if(position!=0 && (position==(is_label ? LABEL_WORDS : 32))!=final_word) fault<=1;
     if(final_word) begin
       if(position==0) fault<=1;
       if(is_label) label_mask[source_row]<=1; else density_mask[source_row]<=1;
       position<=0;
     end else position<=position+1'b1;
     beat<=beat>>32; keep<=keep>>4;
     if(keep==16'h000f) holding<=0;
   end
 end
endmodule

// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Tag-sticky two-lane reservation and full-payload ACE FIFO. Capacity is
// charged at grant, before fire, and fire converts that same reservation into
// a queued entry without charging twice.

module vet_m4_cva6_precommit_bridge #(
    parameter int unsigned FIFO_DEPTH = 32,
    parameter int unsigned TAG_WIDTH = 3
) (
    input logic clk_i,input logic rst_ni,
    input logic [1:0] req_i,input logic [1:0][TAG_WIDTH-1:0] tag_i,
    input logic [1:0] fire_i,output logic [1:0] grant_o,
    input logic [1:0][31:0] ctx_i,input logic [1:0][63:0] pc_i,
    input logic [1:0][31:0] raw_i,input logic [1:0][63:0] rs1_i,input logic [1:0][63:0] rs2_i,
    input logic [1:0][1:0] privilege_i,input logic [1:0] trap_i,input logic [1:0] interrupt_i,
    input logic [1:0][63:0] cause_i,
    output logic ace_valid_o,input logic ace_ready_i,output logic [31:0] retire_seq_o,
    output logic [31:0] ctx_o,output logic [63:0] pc_o,output logic [31:0] raw_o,
    output logic [2:0] len_o,output logic [1:0] privilege_o,output logic [2:0] cf_class_o,
    output logic branch_taken_valid_o,output logic branch_taken_o,output logic target_valid_o,
    output logic [63:0] resolved_target_o,output logic trap_o,output logic interrupt_o,
    output logic [63:0] cause_o,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] occupancy_o,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] used_credits_o
);
  import vet_m4_pkg::*;
  localparam int unsigned PTR_W=(FIFO_DEPTH<=2)?1:$clog2(FIFO_DEPTH);
  localparam int unsigned COUNT_W=$clog2(FIFO_DEPTH+1);
  typedef struct packed {logic[31:0]seq,ctx;logic[63:0]pc;logic[31:0]raw;
    logic[63:0]rs1,rs2;logic[1:0]privilege;logic trap,intr;logic[63:0]cause;} payload_t;
  payload_t mem_q[FIFO_DEPTH],lane_payload[2],reserved_payload_q[2];
  logic[PTR_W-1:0]rd_q,wr_q;logic[COUNT_W-1:0]queued_q,used_q;
  logic[1:0]reserved_q,reservation_match,reservation_cancel,new_reservation;
  logic[1:0][TAG_WIDTH-1:0]reserved_tag_q;
  logic[31:0]next_seq_q;logic pop;logic[1:0]fire_count,cancel_count;
  logic[COUNT_W:0]used_cursor;logic[COUNT_W-1:0]queued_next;

  function automatic logic[PTR_W-1:0] add_ptr(input logic[PTR_W-1:0]p,input int unsigned n);
    int unsigned x;begin x=int'(p)+n;if(x>=FIFO_DEPTH)x-=FIFO_DEPTH;if(x>=FIFO_DEPTH)x-=FIFO_DEPTH;return PTR_W'(x);end
  endfunction
  function automatic logic[2:0] classify(input logic[31:0]i);
    if(i[1:0]!=2'b11)begin
      if(i[1:0]==2'b01&&i[15:13] inside {3'b110,3'b111})return CF_CONDITIONAL;
      if(i[1:0]==2'b01&&i[15:13]==3'b101)return CF_DIRECT;
      if(i[1:0]==2'b10&&i[15:13]==3'b100&&i[6:2]==0&&i[11:7]!=0)
        return (i[11:7] inside {5'd1,5'd5})?CF_RETURN:CF_INDIRECT;
      return CF_SEQUENTIAL;
    end
    if(i[6:0]==7'b1100011)return CF_CONDITIONAL;if(i[6:0]==7'b1101111)return CF_DIRECT;
    if(i[6:0]==7'b1100111)return(i[11:7]==0&&i[19:15] inside {5'd1,5'd5}&&i[31:20]==0)?CF_RETURN:CF_INDIRECT;
    return CF_SEQUENTIAL;
  endfunction
  function automatic logic taken(input logic[31:0]i,input logic[63:0]a,b);
    if(i[1:0]!=2'b11)return i[15:13]==3'b110 ? a==0 : i[15:13]==3'b111 ? a!=0 : 0;
    case(i[14:12])3'b000:return a==b;3'b001:return a!=b;3'b100:return $signed(a)<$signed(b);
      3'b101:return $signed(a)>=$signed(b);3'b110:return a<b;3'b111:return a>=b;default:return 0;endcase
  endfunction
  function automatic logic[63:0] target(input logic[31:0]i,input logic[63:0]pc,a,input logic[2:0]cf);
    logic signed[63:0]imm;imm='0;
    if(i[1:0]!=2'b11)begin
      if(cf==CF_CONDITIONAL)imm={{55{i[12]}},i[12],i[6:5],i[2],i[11:10],i[4:3],1'b0};
      else if(cf==CF_DIRECT)imm={{52{i[12]}},i[12],i[8],i[10:9],i[6],i[7],i[2],i[11],i[5:3],1'b0};
      else return a&~64'd1;return pc+imm;
    end
    if(cf==CF_CONDITIONAL)begin imm={{51{i[31]}},i[31],i[7],i[30:25],i[11:8],1'b0};return pc+imm;end
    if(cf==CF_DIRECT)begin imm={{43{i[31]}},i[31],i[19:12],i[20],i[30:21],1'b0};return pc+imm;end
    imm={{52{i[31]}},i[31:20]};return(a+imm)&~64'd1;
  endfunction

  always_comb begin
    for(int lane=0;lane<2;lane++)begin lane_payload[lane]='0;lane_payload[lane].seq=next_seq_q+((lane==1)?32'(fire_i[0]):32'd0);
      lane_payload[lane].ctx=ctx_i[lane];lane_payload[lane].pc=pc_i[lane];lane_payload[lane].raw=raw_i[lane];
      lane_payload[lane].rs1=rs1_i[lane];lane_payload[lane].rs2=rs2_i[lane];lane_payload[lane].privilege=privilege_i[lane];
      lane_payload[lane].trap=trap_i[lane];lane_payload[lane].intr=interrupt_i[lane];lane_payload[lane].cause=cause_i[lane];end
    pop=ace_valid_o&&ace_ready_i;fire_count=2'(fire_i[0])+2'(fire_i[1]);
    for(int lane=0;lane<2;lane++)begin reservation_match[lane]=reserved_q[lane]&&req_i[lane]&&reserved_tag_q[lane]==tag_i[lane];
      reservation_cancel[lane]=reserved_q[lane]&&!reservation_match[lane];end
    cancel_count=2'(reservation_cancel[0])+2'(reservation_cancel[1]);
    grant_o='0;new_reservation='0;used_cursor={1'b0,used_q}-(COUNT_W+1)'(cancel_count)-(pop?(COUNT_W+1)'(1):'0);
    if(req_i[0])begin if(reservation_match[0])grant_o[0]=1;else if(used_cursor<(COUNT_W+1)'(FIFO_DEPTH))begin grant_o[0]=1;new_reservation[0]=1;used_cursor++;end end
    if(req_i[1]&&req_i[0]&&grant_o[0])begin if(reservation_match[1])grant_o[1]=1;else if(used_cursor<(COUNT_W+1)'(FIFO_DEPTH))begin grant_o[1]=1;new_reservation[1]=1;used_cursor++;end end
    queued_next=COUNT_W'(int'(queued_q)-int'(pop)+int'(fire_count));
  end

  assign ace_valid_o=queued_q!=0;assign retire_seq_o=mem_q[rd_q].seq;assign ctx_o=mem_q[rd_q].ctx;
  assign pc_o=mem_q[rd_q].pc;assign raw_o=mem_q[rd_q].raw;assign len_o=raw_o[1:0]==2'b11 ? 3'd4 : 3'd2;
  assign privilege_o=mem_q[rd_q].privilege;assign cf_class_o=classify(raw_o);
  assign branch_taken_valid_o=cf_class_o==CF_CONDITIONAL;assign branch_taken_o=taken(raw_o,mem_q[rd_q].rs1,mem_q[rd_q].rs2);
  assign target_valid_o=cf_class_o inside {CF_DIRECT,CF_INDIRECT,CF_RETURN};
  assign resolved_target_o=target(raw_o,pc_o,mem_q[rd_q].rs1,cf_class_o);
  assign trap_o=mem_q[rd_q].trap;assign interrupt_o=mem_q[rd_q].intr;assign cause_o=mem_q[rd_q].cause;
  assign occupancy_o=queued_q;assign used_credits_o=used_q;

  always_ff@(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin rd_q<='0;wr_q<='0;queued_q<='0;used_q<='0;reserved_q<='0;reserved_tag_q<='0;
      reserved_payload_q<='{default:'0};next_seq_q<='0;end else begin
      if(pop)rd_q<=add_ptr(rd_q,1);if(fire_count!=0)wr_q<=add_ptr(wr_q,int'(fire_count));
      queued_q<=queued_next;used_q<=COUNT_W'(used_cursor);next_seq_q<=next_seq_q+32'(fire_count);
      for(int lane=0;lane<2;lane++)begin
        if(reservation_cancel[lane])reserved_q[lane]<=0;
        if(new_reservation[lane])begin reserved_q[lane]<=1;reserved_tag_q[lane]<=tag_i[lane];reserved_payload_q[lane]<=lane_payload[lane];end
        if(fire_i[lane])reserved_q[lane]<=0;
      end
      if(fire_i[0])mem_q[wr_q]<=lane_payload[0];if(fire_i[1])mem_q[add_ptr(wr_q,1)]<=lane_payload[1];
    end
  end
`ifndef SYNTHESIS
  initial assert(FIFO_DEPTH>=2);
  always_ff@(posedge clk_i)if(rst_ni)begin
    assert(!(req_i[1]&&!req_i[0]));assert(!(fire_i[1]&&!fire_i[0]));assert((fire_i&~grant_o)==0);
    assert(queued_q<=used_q&&used_q<=COUNT_W'(FIFO_DEPTH));
    assert(queued_q+COUNT_W'(reserved_q[0])+COUNT_W'(reserved_q[1])==used_q);
    for(int lane=0;lane<2;lane++)if(reservation_match[lane])
      assert(lane_payload[lane].ctx==reserved_payload_q[lane].ctx&&lane_payload[lane].pc==reserved_payload_q[lane].pc
        &&lane_payload[lane].raw==reserved_payload_q[lane].raw&&lane_payload[lane].trap==reserved_payload_q[lane].trap
        &&lane_payload[lane].intr==reserved_payload_q[lane].intr
        &&lane_payload[lane].rs1==reserved_payload_q[lane].rs1&&lane_payload[lane].rs2==reserved_payload_q[lane].rs2
        &&lane_payload[lane].privilege==reserved_payload_q[lane].privilege
        &&lane_payload[lane].cause==reserved_payload_q[lane].cause);
  end
`endif
endmodule

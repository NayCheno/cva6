// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module vet_m4_cva6_precommit_chain #(
  parameter int unsigned FIFO_DEPTH=32, TAG_WIDTH=3, NR_SB_ENTRIES=8,
  parameter int unsigned NR_ISSUE_PORTS=1, NR_COMMIT_PORTS=2,
  parameter int unsigned RVT_ENTRIES=8,VHC_ENTRIES=16,RECORD_FIFO_DEPTH=8,SINK_WORDS=4096,
  parameter type rvfi_probes_instr_t=logic
)(input logic clk_i,rst_ni,input rvfi_probes_instr_t rvfi_probes_instr_i,
  input logic[1:0]commit_req_i,input logic[1:0][TAG_WIDTH-1:0]commit_tag_i,input logic[1:0]commit_fire_i,
  output logic[1:0]commit_grant_o,input logic[1:0][31:0]trusted_ctx_id_i,
  output logic[$clog2(SINK_WORDS+1)-1:0]sink_words_used_o,output logic debug_frame_word_valid_o,
  output logic sink_full_o,output logic[63:0]stall_cycles_o,output logic loss_sticky_o,
  output logic[31:0]debug_frame_word_o,debug_epoch_o,output logic[1:0]debug_commit_grant_o,
  output logic debug_sink_read_valid_o,
  output logic[$clog2(SINK_WORDS)-1:0]debug_sink_read_addr_o,
  output logic[31:0]debug_sink_read_data_o);
  logic[1:0][31:0]raw,ctx;logic[1:0][63:0]pc,rs1,rs2,cause;logic[1:0][1:0]priv;logic[1:0]trap,intr;
  logic av,ar,bv,bt,tv,at,ai;logic[31:0]seq,ac,araw;logic[63:0]apc,target,acause;logic[2:0]len,cf;logic[1:0]apriv;
  logic start_q,configured_q;
  logic[$clog2(SINK_WORDS)-1:0]sink_scan_addr_q,sink_scan_addr_pipe_q;
  always_ff@(posedge clk_i or negedge rst_ni)if(!rst_ni)begin configured_q<=0;start_q<=0;end else begin start_q<=!configured_q;configured_q<=1;end
  vet_m4_cva6_precommit_payload #(.rvfi_probes_instr_t(rvfi_probes_instr_t),.NR_SB_ENTRIES(NR_SB_ENTRIES),
    .TAG_WIDTH(TAG_WIDTH),.NR_ISSUE_PORTS(NR_ISSUE_PORTS),.NR_COMMIT_PORTS(NR_COMMIT_PORTS))map(
    .clk_i,.rst_ni,.probes_i(rvfi_probes_instr_i),.raw_o(raw),.pc_o(pc),.rs1_o(rs1),.rs2_o(rs2),
    .privilege_o(priv),.trap_o(trap),.interrupt_o(intr),.cause_o(cause));
  assign ctx=trusted_ctx_id_i;assign debug_commit_grant_o=commit_grant_o;
  assign debug_sink_read_addr_o=sink_scan_addr_pipe_q;
  always_ff@(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin sink_scan_addr_q<='0;sink_scan_addr_pipe_q<='0;end
    else if(sink_full_o)begin
      sink_scan_addr_pipe_q<=sink_scan_addr_q;
      if(sink_scan_addr_q==$clog2(SINK_WORDS)'(SINK_WORDS-1))sink_scan_addr_q<='0;
      else sink_scan_addr_q<=sink_scan_addr_q+1'b1;
    end
  end
  vet_m4_cva6_precommit_bridge #(.FIFO_DEPTH(FIFO_DEPTH),.TAG_WIDTH(TAG_WIDTH))bridge(
    .clk_i,.rst_ni,.req_i(commit_req_i),.tag_i(commit_tag_i),.fire_i(commit_fire_i),.grant_o(commit_grant_o),
    .ctx_i(ctx),.pc_i(pc),.raw_i(raw),.rs1_i(rs1),.rs2_i(rs2),.privilege_i(priv),.trap_i(trap),.interrupt_i(intr),.cause_i(cause),
    .ace_valid_o(av),.ace_ready_i(ar),.retire_seq_o(seq),.ctx_o(ac),.pc_o(apc),.raw_o(araw),.len_o(len),.privilege_o(apriv),
    .cf_class_o(cf),.branch_taken_valid_o(bv),.branch_taken_o(bt),.target_valid_o(tv),.resolved_target_o(target),
    .trap_o(at),.interrupt_o(ai),.cause_o(acause),.occupancy_o(),.used_credits_o());
  vet_m4_integration_top #(.RVT_ENTRIES(RVT_ENTRIES),.VHC_ENTRIES(VHC_ENTRIES),.RECORD_FIFO_DEPTH(RECORD_FIFO_DEPTH),.SINK_WORDS(SINK_WORDS))m4(
    .clk_i,.rst_ni,.ctrl_we_i(start_q),.ctrl_trusted_i(1'b1),.ctrl_enable_i(1'b1),.ctrl_loss_aware_i(1'b0),
    .ctrl_session_i(32'h5052_4543),.ctrl_hart_i(0),.ctrl_epoch_i(1),.ctrl_sink_clear_i(0),
    .ace_valid_i(av),.ace_ready_o(ar),.retire_seq_i(seq),.ctx_id_i(ac),.pc_i(apc),.raw_i(araw),.len_i(len),.privilege_i(apriv),
    .cf_class_i(cf),.branch_taken_valid_i(bv),.branch_taken_i(bt),.target_valid_i(tv),.resolved_target_i(target),.trap_i(at),.interrupt_i(ai),
    .stop_valid_i(0),.stop_ready_o(),.external_loss_valid_i(0),.external_first_lost_seq_i(0),.external_next_seq_i(0),.external_loss_ack_o(),
    .export_trusted_i(1'b1),.export_valid_i(sink_full_o),.export_addr_i(sink_scan_addr_q),
    .export_valid_o(debug_sink_read_valid_o),.export_data_o(debug_sink_read_data_o),.sink_words_used_o,
    .sink_full_o,.protection_violation_o(),.loss_sticky_o,.first_lost_seq_o(),.epoch_o(debug_epoch_o),.stall_cycles_o,
    .debug_frame_word_valid_o,.debug_frame_word_o);
endmodule

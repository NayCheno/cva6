// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Standalone integration boundary. Trusted control is intentionally small:
// untrusted writes cannot start/reset tracing or clear/read the protected sink.

module vet_m4_integration_top #(
    parameter int unsigned RVT_ENTRIES = 8,
    parameter int unsigned VHC_ENTRIES = 16,
    parameter int unsigned PATH_MAX = 16,
    parameter int unsigned RECORD_FIFO_DEPTH = 8,
    parameter int unsigned SINK_WORDS = 1024,
    parameter bit ENABLE_CODE_RUN = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic ctrl_we_i,
    input  logic ctrl_trusted_i,
    input  logic ctrl_enable_i,
    input  logic ctrl_loss_aware_i,
    input  logic [31:0] ctrl_session_i,
    input  logic [15:0] ctrl_hart_i,
    input  logic [31:0] ctrl_epoch_i,
    input  logic ctrl_sink_clear_i,

    input  logic ace_valid_i,
    output logic ace_ready_o,
    input  logic [31:0] retire_seq_i,
    input  logic [31:0] ctx_id_i,
    input  logic [63:0] pc_i,
    input  logic [31:0] raw_i,
    input  logic [2:0] len_i,
    input  logic [1:0] privilege_i,
    input  logic [2:0] cf_class_i,
    input  logic branch_taken_valid_i,
    input  logic branch_taken_i,
    input  logic target_valid_i,
    input  logic [63:0] resolved_target_i,
    input  logic trap_i,
    input  logic interrupt_i,
    input  logic stop_valid_i,
    output logic stop_ready_o,
    input  logic external_loss_valid_i,
    input  logic [31:0] external_first_lost_seq_i,
    input  logic [31:0] external_next_seq_i,
    output logic external_loss_ack_o,

    input  logic export_trusted_i,
    input  logic export_valid_i,
    input  logic [$clog2(SINK_WORDS)-1:0] export_addr_i,
    output logic export_valid_o,
    output logic [31:0] export_data_o,
    output logic [$clog2(SINK_WORDS+1)-1:0] sink_words_used_o,
    output logic sink_full_o,
    output logic protection_violation_o,
    output logic loss_sticky_o,
    output logic [31:0] first_lost_seq_o,
    output logic [31:0] epoch_o,
    output logic [63:0] stall_cycles_o,
    output logic debug_frame_word_valid_o,
    output logic [31:0] debug_frame_word_o
);
  logic cfg_enable_q, cfg_loss_aware_q, start_q, ctrl_violation_q;
  logic [31:0] cfg_session_q, cfg_epoch_q;
  logic [15:0] cfg_hart_q;
  logic record_valid, record_ready;
  logic [vet_m4_pkg::VET_RECORD_WIDTH-1:0] record;
  logic word_valid, word_ready;
  logic [31:0] word;
  logic sink_protection_violation;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cfg_enable_q <= 1'b0; cfg_loss_aware_q <= 1'b0;
      cfg_session_q <= '0; cfg_hart_q <= '0; cfg_epoch_q <= '0;
      start_q <= 1'b0; ctrl_violation_q <= 1'b0;
    end else begin
      start_q <= 1'b0;
      if (ctrl_we_i) begin
        if (ctrl_trusted_i) begin
          cfg_enable_q <= ctrl_enable_i; cfg_loss_aware_q <= ctrl_loss_aware_i;
          cfg_session_q <= ctrl_session_i; cfg_hart_q <= ctrl_hart_i;
          cfg_epoch_q <= ctrl_epoch_i; start_q <= 1'b1;
        end else ctrl_violation_q <= 1'b1;
      end
    end
  end

  vet_m4_pipeline #(
      .RVT_ENTRIES(RVT_ENTRIES), .VHC_ENTRIES(VHC_ENTRIES),
      .PATH_MAX(PATH_MAX), .RECORD_FIFO_DEPTH(RECORD_FIFO_DEPTH),
      .ENABLE_CODE_RUN(ENABLE_CODE_RUN)
  ) i_pipeline (
      .clk_i(clk_i), .rst_ni(rst_ni), .start_i(start_q),
      .enable_i(cfg_enable_q), .loss_aware_i(cfg_loss_aware_q),
      .session_i(cfg_session_q), .hart_i(cfg_hart_q), .initial_epoch_i(cfg_epoch_q),
      .ace_valid_i(ace_valid_i), .ace_ready_o(ace_ready_o),
      .retire_seq_i(retire_seq_i), .ctx_id_i(ctx_id_i), .pc_i(pc_i),
      .raw_i(raw_i), .len_i(len_i), .privilege_i(privilege_i),
      .cf_class_i(cf_class_i), .branch_taken_valid_i(branch_taken_valid_i),
      .branch_taken_i(branch_taken_i), .target_valid_i(target_valid_i),
      .resolved_target_i(resolved_target_i), .trap_i(trap_i),
      .interrupt_i(interrupt_i), .stop_valid_i(stop_valid_i),
      .stop_ready_o(stop_ready_o), .external_loss_valid_i(external_loss_valid_i),
      .external_first_lost_seq_i(external_first_lost_seq_i),
      .external_next_seq_i(external_next_seq_i), .external_loss_ack_o(external_loss_ack_o),
      .record_valid_o(record_valid),
      .record_ready_i(record_ready), .record_o(record), .fifo_occupancy_o(),
      .loss_sticky_o(loss_sticky_o), .first_lost_seq_o(first_lost_seq_o),
      .lost_count_o(), .epoch_o(epoch_o), .stall_cycles_o(stall_cycles_o),
      .contract_error_o()
  );

  vet_m4_framer i_framer (
      .clk_i(clk_i), .rst_ni(rst_ni), .record_valid_i(record_valid),
      .record_ready_o(record_ready), .record_i(record), .word_valid_o(word_valid),
      .word_ready_i(word_ready), .word_o(word), .frame_seq_o()
  );

  vet_m4_protected_sink #(.WORDS(SINK_WORDS)) i_sink (
      .clk_i(clk_i), .rst_ni(rst_ni), .word_valid_i(word_valid),
      .word_ready_o(word_ready), .word_i(word),
      .trusted_clear_i(ctrl_trusted_i),
      .clear_i(ctrl_we_i && ctrl_sink_clear_i),
      .trusted_read_i(export_trusted_i), .read_valid_i(export_valid_i),
      .read_addr_i(export_addr_i), .read_valid_o(export_valid_o),
      .read_data_o(export_data_o), .words_used_o(sink_words_used_o),
      .full_o(sink_full_o), .protection_violation_o(sink_protection_violation)
  );

  always_comb protection_violation_o = sink_protection_violation | ctrl_violation_q;
  always_comb begin
    debug_frame_word_valid_o = word_valid && word_ready;
    debug_frame_word_o = word;
  end
endmodule

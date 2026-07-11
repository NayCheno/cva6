// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Standalone, synthesizable single-hart VET backend.  It implements exact
// full-tag RVT/VHC lookup, monotonic epoch-local IDs, accumulated PATH records,
// and a four-element sequential cold CODE_RUN.

module vet_m4_backend #(
    parameter int unsigned RVT_ENTRIES = 8,
    parameter int unsigned VHC_ENTRIES = 16,
    parameter int unsigned PATH_MAX = 16,
    parameter bit ENABLE_CODE_RUN = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic abort_i,
    input  logic [31:0] session_i,
    input  logic [15:0] hart_i,
    input  logic [31:0] epoch_i,

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
    output logic record_valid_o,
    input  logic record_ready_i,
    output logic [vet_m4_pkg::VET_RECORD_WIDTH-1:0] record_o,
    output logic oldest_valid_o,
    output logic [31:0] oldest_unrecorded_seq_o,
    output logic contract_error_o,
    output logic id_exhausted_o,
    output logic [15:0] next_version_id_o
);
  import vet_m4_pkg::*;

  localparam int unsigned RVT_PTR_W = (RVT_ENTRIES <= 2) ? 1 : $clog2(RVT_ENTRIES);
  localparam int unsigned VHC_PTR_W = (VHC_ENTRIES <= 2) ? 1 : $clog2(VHC_ENTRIES);
  // The counter stores values through PATH_MAX inclusive.  In particular,
  // PATH_MAX=2 needs two bits; using pointer-width logic here silently reduced
  // that legal parameter point to one retirement per PATH.
  localparam int unsigned PATH_COUNT_W = $clog2(PATH_MAX + 1);

  typedef enum logic [2:0] {
    ST_WAIT,
    ST_PROCESS,
    ST_AFTER_VERSION,
    ST_FLUSH_BOUNDARY,
    ST_STOP_RUN,
    ST_STOP_PATH,
    ST_STOP_END
  } state_t;
  typedef enum logic [3:0] {
    ACT_NONE,
    ACT_RUN_RETRY,
    ACT_PATH_RETRY,
    ACT_VERSION,
    ACT_BOUNDARY,
    ACT_RUN_STOP,
    ACT_PATH_STOP,
    ACT_END_STOP
  } action_t;

  state_t state_q;
  action_t action_q;
  logic emit_valid_q;
  logic [VET_RECORD_WIDTH-1:0] emit_record_q;

  logic pending_valid_q;
  logic [31:0] p_seq_q, p_ctx_q, p_raw_q;
  logic [63:0] p_pc_q, p_target_q;
  logic [2:0] p_len_q, p_cf_q;
  logic [1:0] p_priv_q;
  logic p_branch_valid_q, p_branch_q, p_target_valid_q, p_trap_q, p_interrupt_q;

  logic rvt_valid_q [RVT_ENTRIES];
  logic [31:0] rvt_ctx_q [RVT_ENTRIES];
  logic [63:0] rvt_pc_q [RVT_ENTRIES];
  logic [31:0] rvt_raw_q [RVT_ENTRIES];
  logic [2:0] rvt_len_q [RVT_ENTRIES];
  logic [15:0] rvt_version_q [RVT_ENTRIES];
  logic [RVT_PTR_W-1:0] rvt_insert_q;

  logic vhc_valid_q [VHC_ENTRIES];
  logic [31:0] vhc_ctx_q [VHC_ENTRIES];
  logic [63:0] vhc_pc_q [VHC_ENTRIES];
  logic [31:0] vhc_raw_q [VHC_ENTRIES];
  logic [2:0] vhc_len_q [VHC_ENTRIES];
  logic [15:0] vhc_version_q [VHC_ENTRIES];
  logic [VHC_PTR_W-1:0] vhc_insert_q;
  logic [15:0] next_version_q;

  logic path_valid_q;
  logic [31:0] path_start_seq_q, path_ctx_q;
  logic [63:0] path_start_pc_q, path_expected_pc_q;
  logic [1:0] path_priv_q;
  logic [PATH_COUNT_W-1:0] path_count_q;
  logic [15:0] path_branch_map_q;
  logic [4:0] path_branch_count_q;
  logic [1:0] path_indirect_count_q;
  logic [63:0] path_target0_q, path_target1_q;
  logic path_boundary_q;
  logic [3:0] path_termination_q; // 0 version,1 full,2 indirect,3 trap,4 interrupt,5 discontinuity,6 stop,7 ctx,8 priv

  logic run_valid_q;
  logic [31:0] run_start_seq_q, run_ctx_q;
  logic [63:0] run_base_pc_q, run_next_pc_q;
  logic [1:0] run_priv_q;
  logic [2:0] run_count_q;
  logic [3:0][15:0] run_version_q;
  logic [3:0][31:0] run_raw_q;
  logic [3:0][2:0] run_len_q;
  logic [3:0][2:0] run_cf_q;

  logic expected_seq_valid_q;
  logic [31:0] expected_seq_q;
  logic contract_error_q;

  logic active_version_match, active_slot_found;
  logic [RVT_PTR_W-1:0] active_slot;
  logic history_hit;
  logic [15:0] history_version;
  logic history_slot_found;
  logic event_is_cold, run_can_append, path_can_append, event_boundary;
  logic [63:0] event_next_pc;

  function automatic logic [VET_RECORD_WIDTH-1:0] make_version_record(
      input logic is_bind,
      input logic [15:0] version
  );
    logic [VET_RECORD_WIDTH-1:0] value;
    value = common_record(is_bind ? REC_CODE_BIND : REC_CODE_DEF,
                          epoch_i, session_i, hart_i);
    value[383:352] = p_seq_q;
    value[351:320] = p_ctx_q;
    value[319:256] = p_pc_q;
    value[255:224] = p_raw_q;
    value[223:221] = p_len_q;
    value[220:205] = version;
    value[204:203] = p_priv_q;
    return value;
  endfunction

  function automatic logic [VET_RECORD_WIDTH-1:0] make_path_record(input logic [3:0] termination);
    logic [VET_RECORD_WIDTH-1:0] value;
    value = common_record(REC_PATH, epoch_i, session_i, hart_i);
    value[383:352] = path_start_seq_q;
    value[351:320] = path_ctx_q;
    value[319:256] = path_start_pc_q;
    value[255:240] = 16'(path_count_q);
    value[239:224] = path_branch_map_q;
    value[223:216] = 8'(path_branch_count_q);
    value[215:208] = 8'(path_indirect_count_q);
    value[207:144] = path_target0_q;
    value[143:80] = path_target1_q;
    value[79:78] = path_priv_q;
    value[77] = path_boundary_q;
    value[76:73] = termination;
    return value;
  endfunction

  function automatic logic [VET_RECORD_WIDTH-1:0] make_run_record(input logic [3:0] termination);
    logic [VET_RECORD_WIDTH-1:0] value;
    int unsigned base;
    value = common_record(REC_CODE_RUN, epoch_i, session_i, hart_i);
    value[383:352] = run_start_seq_q;
    value[351:320] = run_ctx_q;
    value[319:256] = run_base_pc_q;
    value[255:248] = 8'(run_count_q);
    for (int unsigned idx = 0; idx < 4; idx++) begin
      base = 247 - idx * 55;
      value[base -: 16] = run_version_q[idx];
      value[base-16 -: 32] = run_raw_q[idx];
      value[base-48 -: 3] = run_len_q[idx];
      value[base-51 -: 3] = run_cf_q[idx];
      value[base-54] = 1'b0;
    end
    value[27:26] = run_priv_q;
    value[25:22] = termination;
    return value;
  endfunction

  function automatic logic [VET_RECORD_WIDTH-1:0] make_end_record();
    logic [VET_RECORD_WIDTH-1:0] value;
    value = common_record(REC_END, epoch_i, session_i, hart_i);
    value[383:352] = expected_seq_q;
    value[351] = expected_seq_valid_q;
    return value;
  endfunction

  always_comb begin
    active_version_match = 1'b0;
    active_slot_found = 1'b0;
    active_slot = '0;
    for (int unsigned entry = 0; entry < RVT_ENTRIES; entry++) begin
      if (!active_slot_found && rvt_valid_q[entry]
          && rvt_ctx_q[entry] == p_ctx_q && rvt_pc_q[entry] == p_pc_q) begin
        active_slot_found = 1'b1;
        active_slot = RVT_PTR_W'(entry);
        active_version_match = rvt_raw_q[entry] == p_raw_q
            && rvt_len_q[entry] == p_len_q && rvt_version_q[entry] != 0;
      end
    end

    history_hit = 1'b0;
    history_slot_found = 1'b0;
    history_version = '0;
    for (int unsigned entry = 0; entry < VHC_ENTRIES; entry++) begin
      if (!history_slot_found && vhc_valid_q[entry]
          && vhc_ctx_q[entry] == p_ctx_q && vhc_pc_q[entry] == p_pc_q
          && vhc_raw_q[entry] == p_raw_q && vhc_len_q[entry] == p_len_q) begin
        history_hit = 1'b1;
        history_slot_found = 1'b1;
        history_version = vhc_version_q[entry];
      end
    end

    event_boundary = p_trap_q || p_interrupt_q
        || p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN;
    event_next_pc = p_pc_q + 64'(p_len_q);
    if (p_cf_q == CF_CONDITIONAL && p_branch_valid_q && p_branch_q)
      event_next_pc = p_target_q;
    else if (p_cf_q == CF_DIRECT || p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN)
      event_next_pc = p_target_q;

    event_is_cold = ENABLE_CODE_RUN && !history_hit && !active_version_match
        && p_cf_q == CF_SEQUENTIAL && !p_trap_q && !p_interrupt_q
        && (p_len_q == 3'd2 || p_len_q == 3'd4);
    run_can_append = event_is_cold && run_valid_q && run_count_q < 3'd4
        && run_ctx_q == p_ctx_q && run_priv_q == p_priv_q
        && run_next_pc_q == p_pc_q;
    path_can_append = path_valid_q && path_count_q < PATH_COUNT_W'(PATH_MAX)
        && path_ctx_q == p_ctx_q && path_priv_q == p_priv_q
        && path_expected_pc_q == p_pc_q
        && (!(p_cf_q == CF_CONDITIONAL) || path_branch_count_q < 16)
        && (!(p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN)
            || path_indirect_count_q < 2);

    ace_ready_o = state_q == ST_WAIT && !emit_valid_q;
    stop_ready_o = state_q == ST_WAIT && !emit_valid_q && !ace_valid_i;
    record_valid_o = emit_valid_q;
    record_o = emit_record_q;
    contract_error_o = contract_error_q;
    id_exhausted_o = next_version_q == 16'hffff;
    next_version_id_o = next_version_q;

    oldest_valid_o = run_valid_q || path_valid_q || pending_valid_q || emit_valid_q;
    if (run_valid_q) oldest_unrecorded_seq_o = run_start_seq_q;
    else if (path_valid_q) oldest_unrecorded_seq_o = path_start_seq_q;
    else if (pending_valid_q) oldest_unrecorded_seq_o = p_seq_q;
    else if (emit_valid_q) oldest_unrecorded_seq_o = emit_record_q[383:352];
    else oldest_unrecorded_seq_o = expected_seq_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_backend
    if (!rst_ni || abort_i) begin
      state_q <= ST_WAIT;
      action_q <= ACT_NONE;
      emit_valid_q <= 1'b0;
      emit_record_q <= '0;
      pending_valid_q <= 1'b0;
      p_seq_q <= '0; p_ctx_q <= '0; p_pc_q <= '0; p_raw_q <= '0;
      p_len_q <= '0; p_priv_q <= '0; p_cf_q <= '0;
      p_branch_valid_q <= 1'b0; p_branch_q <= 1'b0;
      p_target_valid_q <= 1'b0; p_target_q <= '0;
      p_trap_q <= 1'b0; p_interrupt_q <= 1'b0;
      rvt_insert_q <= '0; vhc_insert_q <= '0; next_version_q <= 16'd1;
      path_valid_q <= 1'b0; path_start_seq_q <= '0; path_ctx_q <= '0;
      path_start_pc_q <= '0; path_expected_pc_q <= '0; path_priv_q <= '0;
      path_count_q <= '0; path_branch_map_q <= '0; path_branch_count_q <= '0;
      path_indirect_count_q <= '0; path_target0_q <= '0; path_target1_q <= '0;
      path_boundary_q <= 1'b0;
      path_termination_q <= '0;
      run_valid_q <= 1'b0; run_start_seq_q <= '0; run_ctx_q <= '0;
      run_base_pc_q <= '0; run_next_pc_q <= '0; run_priv_q <= '0;
      run_count_q <= '0; run_version_q <= '0; run_raw_q <= '0;
      run_len_q <= '0; run_cf_q <= '0;
      expected_seq_valid_q <= 1'b0; expected_seq_q <= '0;
      contract_error_q <= 1'b0;
      for (int unsigned entry = 0; entry < RVT_ENTRIES; entry++) begin
        rvt_valid_q[entry] <= 1'b0; rvt_ctx_q[entry] <= '0; rvt_pc_q[entry] <= '0;
        rvt_raw_q[entry] <= '0; rvt_len_q[entry] <= '0; rvt_version_q[entry] <= '0;
      end
      for (int unsigned entry = 0; entry < VHC_ENTRIES; entry++) begin
        vhc_valid_q[entry] <= 1'b0; vhc_ctx_q[entry] <= '0; vhc_pc_q[entry] <= '0;
        vhc_raw_q[entry] <= '0; vhc_len_q[entry] <= '0; vhc_version_q[entry] <= '0;
      end
    end else begin
      if (emit_valid_q && record_ready_i) begin
        emit_valid_q <= 1'b0;
        case (action_q)
          ACT_RUN_RETRY: begin run_valid_q <= 1'b0; run_count_q <= '0; state_q <= ST_PROCESS; end
          ACT_PATH_RETRY: begin path_valid_q <= 1'b0; path_count_q <= '0; state_q <= ST_PROCESS; end
          ACT_VERSION: state_q <= ST_AFTER_VERSION;
          ACT_BOUNDARY: begin path_valid_q <= 1'b0; path_count_q <= '0; state_q <= ST_WAIT; end
          ACT_RUN_STOP: begin run_valid_q <= 1'b0; run_count_q <= '0; state_q <= ST_STOP_PATH; end
          ACT_PATH_STOP: begin path_valid_q <= 1'b0; path_count_q <= '0; state_q <= ST_STOP_END; end
          ACT_END_STOP: state_q <= ST_WAIT;
          default: state_q <= ST_WAIT;
        endcase
        action_q <= ACT_NONE;
      end else if (!emit_valid_q) begin
        case (state_q)
          ST_WAIT: begin
            if (ace_valid_i) begin
              pending_valid_q <= 1'b1;
              p_seq_q <= retire_seq_i; p_ctx_q <= ctx_id_i; p_pc_q <= pc_i;
              p_raw_q <= raw_i; p_len_q <= len_i; p_priv_q <= privilege_i;
              p_cf_q <= cf_class_i; p_branch_valid_q <= branch_taken_valid_i;
              p_branch_q <= branch_taken_i; p_target_valid_q <= target_valid_i;
              p_target_q <= resolved_target_i; p_trap_q <= trap_i;
              p_interrupt_q <= interrupt_i;
              if (expected_seq_valid_q && retire_seq_i != expected_seq_q)
                contract_error_q <= 1'b1;
              state_q <= ST_PROCESS;
            end else if (stop_valid_i) begin
              state_q <= ST_STOP_RUN;
            end
          end

          ST_PROCESS: begin
            if (run_valid_q && !run_can_append) begin
              emit_record_q <= make_run_record(
                  run_ctx_q != p_ctx_q ? 4'd7 :
                  (run_priv_q != p_priv_q ? 4'd8 :
                  (run_next_pc_q != p_pc_q ? 4'd5 : 4'd0)));
              emit_valid_q <= 1'b1; action_q <= ACT_RUN_RETRY;
            end else if (run_can_append) begin
              run_version_q[run_count_q] <= next_version_q;
              run_raw_q[run_count_q] <= p_raw_q; run_len_q[run_count_q] <= p_len_q;
              run_cf_q[run_count_q] <= p_cf_q; run_count_q <= run_count_q + 3'd1;
              run_next_pc_q <= event_next_pc;
              if (active_slot_found) begin
                rvt_raw_q[active_slot] <= p_raw_q; rvt_len_q[active_slot] <= p_len_q;
                rvt_version_q[active_slot] <= next_version_q;
              end else begin
                rvt_valid_q[rvt_insert_q] <= 1'b1; rvt_ctx_q[rvt_insert_q] <= p_ctx_q;
                rvt_pc_q[rvt_insert_q] <= p_pc_q; rvt_raw_q[rvt_insert_q] <= p_raw_q;
                rvt_len_q[rvt_insert_q] <= p_len_q; rvt_version_q[rvt_insert_q] <= next_version_q;
                rvt_insert_q <= rvt_insert_q == RVT_PTR_W'(RVT_ENTRIES-1) ? '0 : rvt_insert_q + 1'b1;
              end
              vhc_valid_q[vhc_insert_q] <= 1'b1; vhc_ctx_q[vhc_insert_q] <= p_ctx_q;
              vhc_pc_q[vhc_insert_q] <= p_pc_q; vhc_raw_q[vhc_insert_q] <= p_raw_q;
              vhc_len_q[vhc_insert_q] <= p_len_q; vhc_version_q[vhc_insert_q] <= next_version_q;
              vhc_insert_q <= vhc_insert_q == VHC_PTR_W'(VHC_ENTRIES-1) ? '0 : vhc_insert_q + 1'b1;
              next_version_q <= next_version_q + 16'd1;
              expected_seq_valid_q <= 1'b1; expected_seq_q <= p_seq_q + 32'd1;
              pending_valid_q <= 1'b0; state_q <= ST_WAIT;
            end else if (path_valid_q && (!active_version_match || !path_can_append)) begin
              emit_record_q <= make_path_record(!active_version_match ? 4'd0
                  : (path_ctx_q != p_ctx_q ? 4'd7
                  : (path_priv_q != p_priv_q ? 4'd8
                  : ((path_count_q >= PATH_COUNT_W'(PATH_MAX) || path_branch_count_q >= 5'd16) ? 4'd1 : 4'd5))));
              emit_valid_q <= 1'b1; action_q <= ACT_PATH_RETRY;
            end else if (active_version_match) begin
              if (!path_valid_q) begin
                path_valid_q <= 1'b1; path_start_seq_q <= p_seq_q;
                path_ctx_q <= p_ctx_q; path_start_pc_q <= p_pc_q;
                path_priv_q <= p_priv_q; path_count_q <= PATH_COUNT_W'(1);
                path_branch_map_q <= '0; path_branch_count_q <= '0;
                path_indirect_count_q <= '0; path_target0_q <= '0; path_target1_q <= '0;
                path_boundary_q <= event_boundary;
                path_termination_q <= p_trap_q ? 4'd3 : (p_interrupt_q ? 4'd4 : 4'd2);
                if (p_cf_q == CF_CONDITIONAL) begin
                  path_branch_map_q[0] <= p_branch_q; path_branch_count_q <= 5'd1;
                end
                if (p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN) begin
                  path_target0_q <= p_target_q; path_indirect_count_q <= 2'd1;
                end
              end else begin
                path_count_q <= path_count_q + PATH_COUNT_W'(1);
                if (p_cf_q == CF_CONDITIONAL) begin
                  path_branch_map_q[path_branch_count_q[3:0]] <= p_branch_q;
                  path_branch_count_q <= path_branch_count_q + 5'd1;
                end
                if (p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN) begin
                  if (path_indirect_count_q == 0) path_target0_q <= p_target_q;
                  else path_target1_q <= p_target_q;
                  path_indirect_count_q <= path_indirect_count_q + 2'd1;
                end
                path_boundary_q <= path_boundary_q || event_boundary;
                if (event_boundary)
                  path_termination_q <= p_trap_q ? 4'd3 : (p_interrupt_q ? 4'd4 : 4'd2);
              end
              if ((p_cf_q == CF_CONDITIONAL && !p_branch_valid_q)
                  || ((p_cf_q == CF_DIRECT || p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN)
                      && !p_target_valid_q)) contract_error_q <= 1'b1;
              path_expected_pc_q <= event_next_pc;
              expected_seq_valid_q <= 1'b1; expected_seq_q <= p_seq_q + 32'd1;
              pending_valid_q <= 1'b0;
              state_q <= event_boundary ? ST_FLUSH_BOUNDARY : ST_WAIT;
            end else if (event_is_cold && !run_valid_q) begin
              run_valid_q <= 1'b1; run_start_seq_q <= p_seq_q; run_ctx_q <= p_ctx_q;
              run_base_pc_q <= p_pc_q; run_next_pc_q <= event_next_pc;
              run_priv_q <= p_priv_q; run_count_q <= 3'd1;
              run_version_q[0] <= next_version_q; run_raw_q[0] <= p_raw_q;
              run_len_q[0] <= p_len_q; run_cf_q[0] <= p_cf_q;
              if (active_slot_found) begin
                rvt_raw_q[active_slot] <= p_raw_q; rvt_len_q[active_slot] <= p_len_q;
                rvt_version_q[active_slot] <= next_version_q;
              end else begin
                rvt_valid_q[rvt_insert_q] <= 1'b1; rvt_ctx_q[rvt_insert_q] <= p_ctx_q;
                rvt_pc_q[rvt_insert_q] <= p_pc_q; rvt_raw_q[rvt_insert_q] <= p_raw_q;
                rvt_len_q[rvt_insert_q] <= p_len_q; rvt_version_q[rvt_insert_q] <= next_version_q;
                rvt_insert_q <= rvt_insert_q == RVT_PTR_W'(RVT_ENTRIES-1) ? '0 : rvt_insert_q + 1'b1;
              end
              vhc_valid_q[vhc_insert_q] <= 1'b1; vhc_ctx_q[vhc_insert_q] <= p_ctx_q;
              vhc_pc_q[vhc_insert_q] <= p_pc_q; vhc_raw_q[vhc_insert_q] <= p_raw_q;
              vhc_len_q[vhc_insert_q] <= p_len_q; vhc_version_q[vhc_insert_q] <= next_version_q;
              vhc_insert_q <= vhc_insert_q == VHC_PTR_W'(VHC_ENTRIES-1) ? '0 : vhc_insert_q + 1'b1;
              next_version_q <= next_version_q + 16'd1;
              expected_seq_valid_q <= 1'b1; expected_seq_q <= p_seq_q + 32'd1;
              pending_valid_q <= 1'b0; state_q <= ST_WAIT;
            end else if (next_version_q == 16'hffff && !history_hit) begin
              contract_error_q <= 1'b1;
            end else begin
              emit_record_q <= make_version_record(history_hit, history_hit ? history_version : next_version_q);
              emit_valid_q <= 1'b1; action_q <= ACT_VERSION;
            end
          end

          ST_AFTER_VERSION: begin
            // The version record has been accepted, so activate it before PATH use.
            if (active_slot_found) begin
              rvt_raw_q[active_slot] <= p_raw_q; rvt_len_q[active_slot] <= p_len_q;
              rvt_version_q[active_slot] <= history_hit ? history_version : next_version_q;
            end else begin
              rvt_valid_q[rvt_insert_q] <= 1'b1; rvt_ctx_q[rvt_insert_q] <= p_ctx_q;
              rvt_pc_q[rvt_insert_q] <= p_pc_q; rvt_raw_q[rvt_insert_q] <= p_raw_q;
              rvt_len_q[rvt_insert_q] <= p_len_q;
              rvt_version_q[rvt_insert_q] <= history_hit ? history_version : next_version_q;
              rvt_insert_q <= rvt_insert_q == RVT_PTR_W'(RVT_ENTRIES-1) ? '0 : rvt_insert_q + 1'b1;
            end
            if (!history_hit) begin
              vhc_valid_q[vhc_insert_q] <= 1'b1; vhc_ctx_q[vhc_insert_q] <= p_ctx_q;
              vhc_pc_q[vhc_insert_q] <= p_pc_q; vhc_raw_q[vhc_insert_q] <= p_raw_q;
              vhc_len_q[vhc_insert_q] <= p_len_q; vhc_version_q[vhc_insert_q] <= next_version_q;
              vhc_insert_q <= vhc_insert_q == VHC_PTR_W'(VHC_ENTRIES-1) ? '0 : vhc_insert_q + 1'b1;
              next_version_q <= next_version_q + 16'd1;
            end
            // Start a one-event PATH. Boundary records flush immediately.
            path_valid_q <= 1'b1; path_start_seq_q <= p_seq_q; path_ctx_q <= p_ctx_q;
            path_start_pc_q <= p_pc_q; path_expected_pc_q <= event_next_pc;
            path_priv_q <= p_priv_q; path_count_q <= PATH_COUNT_W'(1);
            path_branch_map_q <= '0; path_branch_count_q <= '0;
            path_indirect_count_q <= '0; path_target0_q <= '0; path_target1_q <= '0;
            path_boundary_q <= event_boundary;
            path_termination_q <= p_trap_q ? 4'd3 : (p_interrupt_q ? 4'd4 : 4'd2);
            if (p_cf_q == CF_CONDITIONAL) begin
              path_branch_map_q[0] <= p_branch_q; path_branch_count_q <= 5'd1;
            end
            if (p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN) begin
              path_target0_q <= p_target_q; path_indirect_count_q <= 2'd1;
            end
            if ((p_cf_q == CF_CONDITIONAL && !p_branch_valid_q)
                || ((p_cf_q == CF_DIRECT || p_cf_q == CF_INDIRECT || p_cf_q == CF_RETURN)
                    && !p_target_valid_q)) contract_error_q <= 1'b1;
            expected_seq_valid_q <= 1'b1; expected_seq_q <= p_seq_q + 32'd1;
            pending_valid_q <= 1'b0;
            state_q <= event_boundary ? ST_FLUSH_BOUNDARY : ST_WAIT;
          end

          ST_FLUSH_BOUNDARY: begin
            emit_record_q <= make_path_record(path_termination_q);
            emit_valid_q <= 1'b1; action_q <= ACT_BOUNDARY;
          end
          ST_STOP_RUN: begin
            if (run_valid_q) begin
              emit_record_q <= make_run_record(4'd6); emit_valid_q <= 1'b1; action_q <= ACT_RUN_STOP;
            end else state_q <= ST_STOP_PATH;
          end
          ST_STOP_PATH: begin
            if (path_valid_q) begin
              emit_record_q <= make_path_record(4'd6); emit_valid_q <= 1'b1; action_q <= ACT_PATH_STOP;
            end else state_q <= ST_STOP_END;
          end
          ST_STOP_END: begin
            emit_record_q <= make_end_record(); emit_valid_q <= 1'b1; action_q <= ACT_END_STOP;
          end
          default: state_q <= ST_WAIT;
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (RVT_ENTRIES >= 2);
    assert (VHC_ENTRIES >= 2);
    assert (PATH_MAX >= 2 && PATH_MAX <= 16);
  end
`endif
endmodule

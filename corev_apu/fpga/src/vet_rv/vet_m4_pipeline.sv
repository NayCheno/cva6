// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Backend + central record sequencing + explicit loss state machine + FIFO.

module vet_m4_pipeline #(
    parameter int unsigned RVT_ENTRIES = 8,
    parameter int unsigned VHC_ENTRIES = 16,
    parameter int unsigned PATH_MAX = 16,
    parameter int unsigned RECORD_FIFO_DEPTH = 8,
    parameter bit ENABLE_CODE_RUN = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic start_i,
    input  logic enable_i,
    input  logic loss_aware_i,
    input  logic [31:0] session_i,
    input  logic [15:0] hart_i,
    input  logic [31:0] initial_epoch_i,

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

    output logic record_valid_o,
    input  logic record_ready_i,
    output logic [vet_m4_pkg::VET_RECORD_WIDTH-1:0] record_o,
    output logic [$clog2(RECORD_FIFO_DEPTH+1)-1:0] fifo_occupancy_o,
    output logic loss_sticky_o,
    output logic [31:0] first_lost_seq_o,
    output logic [31:0] lost_count_o,
    output logic [31:0] epoch_o,
    output logic [63:0] stall_cycles_o,
    output logic contract_error_o
);
  import vet_m4_pkg::*;
  typedef enum logic [1:0] {CTL_NORMAL, CTL_LOSS, CTL_SYNC} ctl_state_t;
  ctl_state_t ctl_state_q;

  logic active_q, loss_mode_q;
  logic [31:0] session_q, epoch_q;
  logic [15:0] hart_q;
  logic [31:0] record_seq_q;
  logic [31:0] first_lost_q, loss_next_seq_q, sync_next_seq_q;
  logic [31:0] lost_count_q, loss_old_epoch_q;
  logic pending_loss_valid_q;
  logic [31:0] pending_first_lost_q, pending_next_seq_q;
  logic loss_sticky_q;
  logic [63:0] stall_cycles_q;

  logic backend_ready, backend_record_valid, backend_record_ready;
  logic stop_ready_backend;
  logic [VET_RECORD_WIDTH-1:0] backend_record;
  logic backend_oldest_valid;
  logic [31:0] backend_oldest;
  logic backend_contract_error, backend_id_exhausted;
  logic backend_abort, backend_in_valid;
  logic loss_trigger;
  logic internal_loss_trigger;
  logic id_loss_trigger;
  logic [31:0] selected_first_lost, selected_loss_next;
  logic [31:0] loss_effective_first, loss_effective_next;
  logic pending_effective_valid;
  logic [31:0] pending_effective_first, pending_effective_next;
  logic ace_handshake;

  logic fifo_in_valid, fifo_in_ready, fifo_clear;
  logic [VET_RECORD_WIDTH-1:0] fifo_in_record, unstamped_record;

  function automatic logic [VET_RECORD_WIDTH-1:0] make_sync_record(
      input logic [31:0] next_seq
  );
    logic [VET_RECORD_WIDTH-1:0] value;
    value = common_record(REC_SYNC, epoch_q, session_q, hart_q);
    value[383:352] = next_seq;
    value[351:320] = 32'b0;
    value[319:256] = 64'b0;
    value[255] = 1'b1;
    return value;
  endfunction

  function automatic logic [VET_RECORD_WIDTH-1:0] make_loss_record(
      input logic [31:0] first_seq,
      input logic [31:0] next_seq
  );
    logic [VET_RECORD_WIDTH-1:0] value;
    value = common_record(REC_LOSS, loss_old_epoch_q, session_q, hart_q);
    value[383:352] = first_seq - 32'd1;
    value[351:320] = first_seq;
    value[319:288] = next_seq - first_seq;
    value[287:280] = LOSS_INTERNAL_BACKPRESSURE;
    value[279:248] = loss_old_epoch_q;
    value[247:216] = epoch_q;
    return value;
  endfunction

  always_comb begin
    ace_handshake = ace_valid_i && active_q
        && (loss_mode_q || (ctl_state_q == CTL_NORMAL && backend_ready));
    internal_loss_trigger = active_q && loss_mode_q && ctl_state_q == CTL_NORMAL
        && ace_valid_i && !backend_ready;
    id_loss_trigger = active_q && loss_mode_q && ctl_state_q == CTL_NORMAL
        && ace_valid_i && backend_id_exhausted;
    loss_trigger = internal_loss_trigger || (active_q && loss_mode_q
        && ctl_state_q == CTL_NORMAL && external_loss_valid_i) || id_loss_trigger;
    if (backend_oldest_valid) selected_first_lost = backend_oldest;
    else if (external_loss_valid_i) selected_first_lost = external_first_lost_seq_i;
    else selected_first_lost = retire_seq_i;
    selected_loss_next = selected_first_lost;
    if (ace_valid_i) begin
      if (retire_seq_i < selected_first_lost) selected_first_lost = retire_seq_i;
      if (retire_seq_i + 32'd1 > selected_loss_next)
        selected_loss_next = retire_seq_i + 32'd1;
    end
    if (external_loss_valid_i) begin
      if (external_first_lost_seq_i < selected_first_lost)
        selected_first_lost = external_first_lost_seq_i;
      if (external_next_seq_i > selected_loss_next)
        selected_loss_next = external_next_seq_i;
    end

    // The LOSS payload snapshots the inclusive cursor on its FIFO-accept
    // edge.  This closes the race in which a simultaneous transparent ACE
    // handshake was previously applied to the mutable counter only after the
    // already-emitted record had captured the old value.
    loss_effective_first = first_lost_q;
    loss_effective_next = loss_next_seq_q;
    if (ace_handshake) begin
      if (retire_seq_i < loss_effective_first)
        loss_effective_first = retire_seq_i;
      if (retire_seq_i + 32'd1 > loss_effective_next)
        loss_effective_next = retire_seq_i + 32'd1;
    end
    if (external_loss_valid_i) begin
      if (external_first_lost_seq_i < loss_effective_first)
        loss_effective_first = external_first_lost_seq_i;
      if (external_next_seq_i > loss_effective_next)
        loss_effective_next = external_next_seq_i;
    end

    // Once LOSS has been accepted, sync_next_seq_q is immutable until its
    // matching SYNC is accepted.  Transparent handshakes during CTL_SYNC are
    // accumulated into a disjoint next-epoch LOSS interval instead of
    // silently moving the reset cursor past the wire-visible LOSS end.
    pending_effective_valid = pending_loss_valid_q;
    pending_effective_first = pending_first_lost_q;
    pending_effective_next = pending_next_seq_q;
    if (ctl_state_q == CTL_SYNC && ace_handshake) begin
      if (!pending_effective_valid) begin
        pending_effective_valid = 1'b1;
        pending_effective_first = retire_seq_i;
        pending_effective_next = retire_seq_i + 32'd1;
      end else begin
        if (retire_seq_i < pending_effective_first)
          pending_effective_first = retire_seq_i;
        if (retire_seq_i + 32'd1 > pending_effective_next)
          pending_effective_next = retire_seq_i + 32'd1;
      end
    end
    if (ctl_state_q == CTL_SYNC && external_loss_valid_i) begin
      if (!pending_effective_valid) begin
        pending_effective_valid = 1'b1;
        pending_effective_first = external_first_lost_seq_i;
        pending_effective_next = external_next_seq_i;
      end else begin
        if (external_first_lost_seq_i < pending_effective_first)
          pending_effective_first = external_first_lost_seq_i;
        if (external_next_seq_i > pending_effective_next)
          pending_effective_next = external_next_seq_i;
      end
    end
    backend_abort = start_i || loss_trigger;
    backend_in_valid = active_q && ctl_state_q == CTL_NORMAL
        && ace_valid_i && (!loss_mode_q || backend_ready);

    if (!active_q) ace_ready_o = 1'b0;
    else if (loss_mode_q) ace_ready_o = 1'b1;
    else ace_ready_o = ctl_state_q == CTL_NORMAL && backend_ready;

    // A record still resident in the backend at the loss edge is part of the
    // loss interval. Do not let it race into the FIFO while aborting it.
    backend_record_ready = ctl_state_q == CTL_NORMAL && fifo_in_ready && !loss_trigger;
    fifo_in_valid = 1'b0;
    unstamped_record = '0;
    if (ctl_state_q == CTL_LOSS) begin
      fifo_in_valid = 1'b1;
      unstamped_record = make_loss_record(loss_effective_first, loss_effective_next);
    end else if (ctl_state_q == CTL_SYNC) begin
      fifo_in_valid = 1'b1;
      unstamped_record = make_sync_record(sync_next_seq_q);
    end else begin
      fifo_in_valid = backend_record_valid && !loss_trigger;
      unstamped_record = backend_record;
    end
    fifo_in_record = stamp_record_seq(unstamped_record, record_seq_q);
    fifo_clear = start_i;

    stop_ready_o = active_q && ctl_state_q == CTL_NORMAL && !loss_mode_q
        ? stop_ready_backend : (active_q && ctl_state_q == CTL_NORMAL && stop_ready_backend);
    loss_sticky_o = loss_sticky_q;
    first_lost_seq_o = first_lost_q;
    lost_count_o = lost_count_q;
    epoch_o = epoch_q;
    stall_cycles_o = stall_cycles_q;
    contract_error_o = backend_contract_error;
    // Atomically snapshot the external cursor with the LOSS record.  The
    // adapter can then buffer post-snapshot retirements while reset SYNC is
    // emitted, instead of extending an already-emitted LOSS descriptor.
    external_loss_ack_o = ctl_state_q == CTL_LOSS && external_loss_valid_i
        && fifo_in_valid && fifo_in_ready;
  end

  vet_m4_backend #(
      .RVT_ENTRIES(RVT_ENTRIES), .VHC_ENTRIES(VHC_ENTRIES),
      .PATH_MAX(PATH_MAX), .ENABLE_CODE_RUN(ENABLE_CODE_RUN)
  ) i_backend (
      .clk_i(clk_i), .rst_ni(rst_ni), .abort_i(backend_abort),
      .session_i(session_q), .hart_i(hart_q), .epoch_i(epoch_q),
      .ace_valid_i(backend_in_valid), .ace_ready_o(backend_ready),
      .retire_seq_i(retire_seq_i), .ctx_id_i(ctx_id_i), .pc_i(pc_i),
      .raw_i(raw_i), .len_i(len_i), .privilege_i(privilege_i),
      .cf_class_i(cf_class_i), .branch_taken_valid_i(branch_taken_valid_i),
      .branch_taken_i(branch_taken_i), .target_valid_i(target_valid_i),
      .resolved_target_i(resolved_target_i), .trap_i(trap_i),
      .interrupt_i(interrupt_i),
      .stop_valid_i(stop_valid_i && ctl_state_q == CTL_NORMAL),
      .stop_ready_o(stop_ready_backend),
      .record_valid_o(backend_record_valid), .record_ready_i(backend_record_ready),
      .record_o(backend_record), .oldest_valid_o(backend_oldest_valid),
      .oldest_unrecorded_seq_o(backend_oldest),
      .contract_error_o(backend_contract_error),
      .id_exhausted_o(backend_id_exhausted), .next_version_id_o()
  );

  vet_m4_record_fifo #(.DEPTH(RECORD_FIFO_DEPTH)) i_fifo (
      .clk_i(clk_i), .rst_ni(rst_ni), .clear_i(fifo_clear),
      .in_valid_i(fifo_in_valid), .in_ready_o(fifo_in_ready),
      .in_data_i(fifo_in_record), .out_valid_o(record_valid_o),
      .out_ready_i(record_ready_i), .out_data_o(record_o),
      .occupancy_o(fifo_occupancy_o)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0;
      loss_mode_q <= 1'b0;
      session_q <= '0; hart_q <= '0; epoch_q <= '0;
      record_seq_q <= '0;
      ctl_state_q <= CTL_NORMAL;
      first_lost_q <= '0; loss_next_seq_q <= '0; sync_next_seq_q <= '0;
      pending_loss_valid_q <= 1'b0;
      pending_first_lost_q <= '0; pending_next_seq_q <= '0;
      lost_count_q <= '0;
      loss_old_epoch_q <= '0; loss_sticky_q <= 1'b0;
      stall_cycles_q <= '0;
    end else begin
      if (start_i) begin
        active_q <= enable_i;
        loss_mode_q <= loss_aware_i;
        session_q <= session_i; hart_q <= hart_i; epoch_q <= initial_epoch_i;
        record_seq_q <= '0;
        ctl_state_q <= enable_i ? CTL_SYNC : CTL_NORMAL;
        first_lost_q <= '0; loss_next_seq_q <= '0; sync_next_seq_q <= '0;
        pending_loss_valid_q <= 1'b0;
        pending_first_lost_q <= '0; pending_next_seq_q <= '0;
        lost_count_q <= '0;
        loss_old_epoch_q <= '0; loss_sticky_q <= 1'b0;
        stall_cycles_q <= '0;
      end else begin
        if (active_q && !loss_mode_q && ace_valid_i && !ace_ready_o)
          stall_cycles_q <= stall_cycles_q + 64'd1;

        if (loss_trigger) begin
          first_lost_q <= selected_first_lost;
          loss_next_seq_q <= selected_loss_next;
          lost_count_q <= selected_loss_next - selected_first_lost;
          loss_old_epoch_q <= epoch_q;
          epoch_q <= epoch_q + 32'd1;
          loss_sticky_q <= 1'b1;
          ctl_state_q <= CTL_LOSS;
          pending_loss_valid_q <= 1'b0;
          pending_first_lost_q <= '0;
          pending_next_seq_q <= '0;
        end else if (ctl_state_q == CTL_LOSS) begin
          first_lost_q <= loss_effective_first;
          loss_next_seq_q <= loss_effective_next;
          lost_count_q <= loss_effective_next - loss_effective_first;
          if (fifo_in_valid && fifo_in_ready) begin
            sync_next_seq_q <= loss_effective_next;
            ctl_state_q <= CTL_SYNC;
          end
        end else if (ctl_state_q == CTL_SYNC) begin
          pending_loss_valid_q <= pending_effective_valid;
          pending_first_lost_q <= pending_effective_first;
          pending_next_seq_q <= pending_effective_next;
          if (fifo_in_valid && fifo_in_ready) begin
            if (pending_effective_valid) begin
              first_lost_q <= pending_effective_first;
              loss_next_seq_q <= pending_effective_next;
              lost_count_q <= pending_effective_next - pending_effective_first;
              loss_old_epoch_q <= epoch_q;
              epoch_q <= epoch_q + 32'd1;
              loss_sticky_q <= 1'b1;
              ctl_state_q <= CTL_LOSS;
              pending_loss_valid_q <= 1'b0;
              pending_first_lost_q <= '0;
              pending_next_seq_q <= '0;
            end else begin
              ctl_state_q <= CTL_NORMAL;
            end
          end
        end

        if (fifo_in_valid && fifo_in_ready) begin
          record_seq_q <= record_seq_q + 32'd1;
        end
      end
    end
  end
endmodule

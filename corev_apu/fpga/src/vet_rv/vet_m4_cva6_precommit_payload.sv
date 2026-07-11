// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Pre-commit copy of the pinned official RVFI issue-pointer -> scoreboard-tag
// mapping.  Unlike cva6_rvfi, this exposes payload while commit is still only
// a request, so a reserved FIFO slot can gate architectural side effects.

module vet_m4_cva6_precommit_payload #(
    parameter int unsigned NR_ISSUE_PORTS = 2,
    parameter int unsigned NR_COMMIT_PORTS = 2,
    parameter int unsigned NR_SB_ENTRIES = 8,
    parameter int unsigned TAG_WIDTH = 3,
    parameter int unsigned XLEN = 64,
    parameter int unsigned VLEN = 64,
    parameter type rvfi_probes_instr_t = logic
) (
    input logic clk_i,
    input logic rst_ni,
    input rvfi_probes_instr_t probes_i,
    output logic [NR_COMMIT_PORTS-1:0][31:0] raw_o,
    output logic [NR_COMMIT_PORTS-1:0][63:0] pc_o,
    output logic [NR_COMMIT_PORTS-1:0][63:0] rs1_o,
    output logic [NR_COMMIT_PORTS-1:0][63:0] rs2_o,
    output logic [NR_COMMIT_PORTS-1:0][1:0] privilege_o,
    output logic [NR_COMMIT_PORTS-1:0] trap_o,
    output logic [NR_COMMIT_PORTS-1:0] interrupt_o,
    output logic [NR_COMMIT_PORTS-1:0][63:0] cause_o
);
  typedef struct packed { logic valid; logic [31:0] instr; } issue_entry_t;
  typedef struct packed {
    logic [XLEN-1:0] rs1;
    logic [XLEN-1:0] rs2;
    logic [31:0] raw;
  } tag_payload_t;
  issue_entry_t [NR_ISSUE_PORTS-1:0] issue_q, issue_d;
  tag_payload_t [NR_SB_ENTRIES-1:0] tag_mem_q, tag_mem_d;
  logic took0;

  // This is kept structurally aligned with pinned core/cva6_rvfi.sv:164-220.
  always_comb begin
    issue_d = issue_q;
    took0 = 1'b0;
    for (int unsigned lane=0; lane<NR_ISSUE_PORTS; lane++) begin
      if (probes_i.issue_instr_ack[lane]) issue_d[lane].valid = 1'b0;
    end
    if (!issue_d[NR_ISSUE_PORTS-1].valid) begin
      issue_d[NR_ISSUE_PORTS-1].valid = probes_i.fetch_entry_valid[0];
      issue_d[NR_ISSUE_PORTS-1].instr = probes_i.is_compressed[0]
          ? {16'b0,probes_i.instruction[0][15:0]} : probes_i.instruction[0];
      took0 = 1'b1;
    end
    if (!issue_d[0].valid) begin
      issue_d[0] = issue_d[NR_ISSUE_PORTS-1];
      issue_d[NR_ISSUE_PORTS-1].valid = 1'b0;
    end
    if (!issue_d[NR_ISSUE_PORTS-1].valid) begin
      if (took0) begin
        issue_d[NR_ISSUE_PORTS-1].valid = probes_i.fetch_entry_valid[NR_ISSUE_PORTS-1];
        issue_d[NR_ISSUE_PORTS-1].instr = probes_i.is_compressed[NR_ISSUE_PORTS-1]
            ? {16'b0,probes_i.instruction[NR_ISSUE_PORTS-1][15:0]}
            : probes_i.instruction[NR_ISSUE_PORTS-1];
      end else begin
        issue_d[NR_ISSUE_PORTS-1].valid = probes_i.fetch_entry_valid[0];
        issue_d[NR_ISSUE_PORTS-1].instr = probes_i.is_compressed[0]
            ? {16'b0,probes_i.instruction[0][15:0]} : probes_i.instruction[0];
      end
    end
    if (probes_i.flush) issue_d = '0;
  end

  // This is the payload subset of pinned core/cva6_rvfi.sv:225-269.
  always_comb begin
    tag_mem_d = tag_mem_q;
    for (int unsigned lane=0; lane<NR_ISSUE_PORTS; lane++) begin
      if (probes_i.decoded_instr_valid[lane] && probes_i.decoded_instr_ack[lane]
          && !probes_i.flush_unissued_instr) begin
        tag_mem_d[probes_i.issue_pointer[lane]].raw = issue_q[lane].instr;
        tag_mem_d[probes_i.issue_pointer[lane]].rs1 = probes_i.rs1[lane];
        tag_mem_d[probes_i.issue_pointer[lane]].rs2 = probes_i.rs2[lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin issue_q <= '0; tag_mem_q <= '0; end
    else begin issue_q <= issue_d; tag_mem_q <= tag_mem_d; end
  end

  always_comb begin
    raw_o='0;pc_o='0;rs1_o='0;rs2_o='0;privilege_o='0;
    trap_o='0;interrupt_o='0;cause_o='0;
    for (int unsigned lane=0; lane<NR_COMMIT_PORTS; lane++) begin
      raw_o[lane] = tag_mem_q[probes_i.commit_pointer[lane]].raw;
      pc_o[lane] = 64'(probes_i.commit_instr_pc[lane]);
      rs1_o[lane] = 64'(tag_mem_q[probes_i.commit_pointer[lane]].rs1);
      rs2_o[lane] = 64'(tag_mem_q[probes_i.commit_pointer[lane]].rs2);
      privilege_o[lane] = probes_i.priv_lvl;
      cause_o[lane] = 64'(probes_i.ex_commit_cause);
    end
    trap_o[0] = probes_i.ex_commit_valid && !probes_i.ex_commit_cause[31];
    interrupt_o[0] = probes_i.ex_commit_valid && probes_i.ex_commit_cause[31];
  end

`ifndef SYNTHESIS
  initial begin
    assert (NR_ISSUE_PORTS==2 && NR_COMMIT_PORTS==2);
    assert (XLEN<=64 && VLEN<=64 && (1<<TAG_WIDTH)>=NR_SB_ENTRIES);
  end
`endif
endmodule


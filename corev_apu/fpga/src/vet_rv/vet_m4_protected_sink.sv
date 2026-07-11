// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Non-overwriting protected trace sink. Once full, writes are backpressured;
// only a trusted clear can release storage. Untrusted reads return zero.

module vet_m4_protected_sink #(
    parameter int unsigned WORDS = 1024
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic word_valid_i,
    output logic word_ready_o,
    input  logic [31:0] word_i,
    input  logic trusted_clear_i,
    input  logic clear_i,
    input  logic trusted_read_i,
    input  logic read_valid_i,
    input  logic [$clog2(WORDS)-1:0] read_addr_i,
    output logic read_valid_o,
    output logic [31:0] read_data_o,
    output logic [$clog2(WORDS+1)-1:0] words_used_o,
    output logic full_o,
    output logic protection_violation_o
);
  import vet_m4_pkg::*;
  (* ram_style = "block" *) logic [31:0] mem_q [WORDS];
  logic [$clog2(WORDS+1)-1:0] used_q;
  logic protection_violation_q;
  logic [31:0] read_data_q;

  always_comb begin
    full_o = used_q == $clog2(WORDS+1)'(WORDS);
    word_ready_o = !full_o;
    words_used_o = used_q;
    read_data_o = rst_ni ? read_data_q : '0;
    protection_violation_o = protection_violation_q;
  end

  // Keep both memory ports free of asynchronous-reset semantics so Vivado can
  // infer a simple dual-port block RAM at board-scale depths.  Reset/clear
  // invalidate contents through used_q; the protected bytes are never exposed
  // unless their address is below the current trusted extent.
  always_ff @(posedge clk_i) begin
    if (rst_ni && !clear_i && word_valid_i && word_ready_o)
      mem_q[used_q[$clog2(WORDS)-1:0]] <= word_i;
    if (read_valid_i && trusted_read_i
        && $clog2(WORDS+1)'(read_addr_i) < used_q)
      read_data_q <= mem_q[read_addr_i];
    else read_data_q <= '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      used_q <= '0;
      protection_violation_q <= 1'b0;
      read_valid_o <= 1'b0;
    end else begin
      read_valid_o <= read_valid_i;
      if (clear_i) begin
        if (trusted_clear_i) begin
          used_q <= '0;
          protection_violation_q <= 1'b0;
        end else protection_violation_q <= 1'b1;
      end else if (word_valid_i && word_ready_o) begin
        used_q <= used_q + 1'b1;
      end
      if (read_valid_i && !trusted_read_i) protection_violation_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial assert (WORDS >= VET_FRAME_WORDS);
`endif
endmodule

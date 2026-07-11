// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module vet_m4_record_fifo #(
    parameter int unsigned DEPTH = 8,
    parameter int unsigned WIDTH = vet_m4_pkg::VET_RECORD_WIDTH
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic in_valid_i,
    output logic in_ready_o,
    input  logic [WIDTH-1:0] in_data_i,
    output logic out_valid_o,
    input  logic out_ready_i,
    output logic [WIDTH-1:0] out_data_o,
    output logic [$clog2(DEPTH+1)-1:0] occupancy_o
);
  localparam int unsigned PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [PTR_W-1:0] rd_ptr_q, wr_ptr_q;
  logic [$clog2(DEPTH+1)-1:0] count_q;
  wire push = in_valid_i && in_ready_o;
  wire pop = out_valid_o && out_ready_i;

  // Keep the readiness path independent of in_valid_i.  Besides matching the
  // standard FIFO contract, separate continuous assignments prevent tools
  // from inferring a false combinational loop through an upstream producer.
  assign in_ready_o = count_q != $clog2(DEPTH+1)'(DEPTH);
  assign out_valid_o = count_q != 0;
  assign out_data_o = mem_q[rd_ptr_q];
  assign occupancy_o = count_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || clear_i) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q <= '0;
    end else begin
      if (push) begin
        mem_q[wr_ptr_q] <= in_data_i;
        wr_ptr_q <= wr_ptr_q == PTR_W'(DEPTH-1) ? '0 : wr_ptr_q + 1'b1;
      end
      if (pop) rd_ptr_q <= rd_ptr_q == PTR_W'(DEPTH-1) ? '0 : rd_ptr_q + 1'b1;
      case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial assert (DEPTH >= 2);
`endif
endmodule

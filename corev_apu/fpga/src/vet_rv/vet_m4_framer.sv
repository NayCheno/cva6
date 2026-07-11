// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Fixed hardware frame: magic, {version,kind,flags,reserved}, uint32 frame_seq,
// uint32 payload_words=16, 16 little-endian payload words, final CRC32.

module vet_m4_framer (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic record_valid_i,
    output logic record_ready_o,
    input  logic [vet_m4_pkg::VET_RECORD_WIDTH-1:0] record_i,
    output logic word_valid_o,
    input  logic word_ready_i,
    output logic [31:0] word_o,
    output logic [31:0] frame_seq_o
);
  import vet_m4_pkg::*;
  logic active_q;
  logic [4:0] word_index_q;
  logic [VET_RECORD_WIDTH-1:0] record_q;
  logic [31:0] frame_seq_q, crc_q;
  logic [31:0] current_word;

  always_comb begin
    record_ready_o = !active_q;
    word_valid_o = active_q;
    current_word = '0;
    case (word_index_q)
      5'd0: current_word = VET_FRAME_MAGIC;
      5'd1: current_word = {VET_FRAME_VERSION, record_q[KIND_MSB:KIND_LSB],
                            record_q[FLAGS_MSB:FLAGS_LSB], 8'b0};
      5'd2: current_word = frame_seq_q;
      5'd3: current_word = 32'd16;
      5'd20: current_word = crc_q ^ 32'hffff_ffff;
      default: current_word = record_q[(word_index_q-5'd4)*32 +: 32];
    endcase
    word_o = current_word;
    frame_seq_o = frame_seq_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0;
      word_index_q <= '0;
      record_q <= '0;
      frame_seq_q <= '0;
      crc_q <= 32'hffff_ffff;
    end else begin
      if (!active_q && record_valid_i) begin
        active_q <= 1'b1;
        record_q <= record_i;
        word_index_q <= '0;
        crc_q <= 32'hffff_ffff;
      end else if (active_q && word_ready_i) begin
        if (word_index_q < 5'd20) crc_q <= crc32_word(crc_q, current_word);
        if (word_index_q == 5'd20) begin
          active_q <= 1'b0;
          frame_seq_q <= frame_seq_q + 32'd1;
          word_index_q <= '0;
        end else word_index_q <= word_index_q + 5'd1;
      end
    end
  end
endmodule

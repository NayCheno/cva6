// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Standalone M4 backend record contract.  This is a fixed-width hardware
// transport contract, not the M3 canonical-JSON wire format.

package vet_m4_pkg;
  localparam int unsigned VET_RECORD_WIDTH = 512;
  localparam int unsigned VET_FRAME_WORDS = 21;
  localparam logic [31:0] VET_FRAME_MAGIC = 32'h5634_5446; // "V4TF"
  localparam logic [7:0] VET_FRAME_VERSION = 8'd1;

  typedef enum logic [7:0] {
    REC_SYNC     = 8'h01,
    REC_CODE_DEF = 8'h02,
    REC_CODE_BIND= 8'h03,
    REC_PATH     = 8'h04,
    REC_CODE_RUN = 8'h05,
    REC_LOSS     = 8'h06,
    REC_END      = 8'h07
  } vet_record_kind_t;

  typedef enum logic [2:0] {
    CF_SEQUENTIAL = 3'd0,
    CF_CONDITIONAL= 3'd1,
    CF_DIRECT     = 3'd2,
    CF_INDIRECT   = 3'd3,
    CF_RETURN     = 3'd4
  } vet_cf_class_t;

  typedef enum logic [7:0] {
    LOSS_INTERNAL_BACKPRESSURE = 8'd1,
    LOSS_ID_EXHAUSTION         = 8'd2,
    LOSS_TRUSTED_RESET         = 8'd3
  } vet_loss_reason_t;

  // Common bit positions in every 512-bit record.
  localparam int unsigned KIND_MSB = 511;
  localparam int unsigned KIND_LSB = 504;
  localparam int unsigned FLAGS_MSB = 503;
  localparam int unsigned FLAGS_LSB = 496;
  localparam int unsigned RECORD_SEQ_MSB = 495;
  localparam int unsigned RECORD_SEQ_LSB = 464;
  localparam int unsigned EPOCH_MSB = 463;
  localparam int unsigned EPOCH_LSB = 432;
  localparam int unsigned SESSION_MSB = 431;
  localparam int unsigned SESSION_LSB = 400;
  localparam int unsigned HART_MSB = 399;
  localparam int unsigned HART_LSB = 384;

  function automatic logic [VET_RECORD_WIDTH-1:0] common_record(
      input vet_record_kind_t kind,
      input logic [31:0] epoch,
      input logic [31:0] session,
      input logic [15:0] hart
  );
    logic [VET_RECORD_WIDTH-1:0] value;
    value = '0;
    value[KIND_MSB:KIND_LSB] = kind;
    value[EPOCH_MSB:EPOCH_LSB] = epoch;
    value[SESSION_MSB:SESSION_LSB] = session;
    value[HART_MSB:HART_LSB] = hart;
    return value;
  endfunction

  function automatic logic [VET_RECORD_WIDTH-1:0] stamp_record_seq(
      input logic [VET_RECORD_WIDTH-1:0] record,
      input logic [31:0] record_seq
  );
    logic [VET_RECORD_WIDTH-1:0] value;
    value = record;
    value[RECORD_SEQ_MSB:RECORD_SEQ_LSB] = record_seq;
    return value;
  endfunction

  // Reflected Ethernet/ZIP CRC32. Bytes within each 32-bit word are consumed
  // least-significant byte first. Initial state and final XOR are all ones.
  function automatic logic [31:0] crc32_byte(
      input logic [31:0] crc_in,
      input logic [7:0] data
  );
    logic [31:0] crc;
    crc = crc_in ^ {24'b0, data};
    for (int unsigned bit_idx = 0; bit_idx < 8; bit_idx++) begin
      crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
    end
    return crc;
  endfunction

  function automatic logic [31:0] crc32_word(
      input logic [31:0] crc_in,
      input logic [31:0] data
  );
    logic [31:0] crc;
    crc = crc_in;
    for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
      crc = crc32_byte(crc, data[byte_idx*8 +: 8]);
    end
    return crc;
  endfunction
endpackage

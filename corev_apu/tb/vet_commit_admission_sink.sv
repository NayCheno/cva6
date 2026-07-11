// Copyright 2026 VET-RV contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Test-only lossless credit sink for the CVA6 commit-stage integration patch.
// Reservations count against capacity as soon as grant_o rises and remain tied
// to the scoreboard transaction tag until the event fires or the request/tag
// is cancelled. Fired reservations become abstract queued evidence tokens.

module vet_commit_admission_sink #(
    parameter int unsigned NR_LANES = 2,
    parameter int unsigned TAG_WIDTH = 3,
    parameter int unsigned FIFO_DEPTH = 8
) (
    input  logic                                clk_i,
    input  logic                                rst_ni,
    input  logic [NR_LANES-1:0]                 req_i,
    input  logic [NR_LANES-1:0][TAG_WIDTH-1:0]  tag_i,
    input  logic [NR_LANES-1:0]                 fire_i,
    output logic [NR_LANES-1:0]                 grant_o,
    output logic                                consumer_stopped_o
);

  localparam int unsigned COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);
  localparam logic [COUNT_WIDTH-1:0] DEPTH_COUNT = COUNT_WIDTH'(FIFO_DEPTH);
  localparam logic [COUNT_WIDTH:0] DEPTH_EXTENDED = (COUNT_WIDTH + 1)'(FIFO_DEPTH);

  logic [NR_LANES-1:0] reserved_q, reserved_d;
  logic [NR_LANES-1:0][TAG_WIDTH-1:0] reserved_tag_q, reserved_tag_d;
  logic [COUNT_WIDTH-1:0] used_q, used_d;
  logic [COUNT_WIDTH-1:0] queued_q, queued_d;
  logic [NR_LANES-1:0] reservation_match;
  logic [NR_LANES-1:0] reservation_cancel;
  logic [NR_LANES-1:0] new_reservation;
  logic consumer_running;
  logic [COUNT_WIDTH-1:0] pop_count;
  logic [COUNT_WIDTH-1:0] cancel_count;
  logic [COUNT_WIDTH-1:0] fire_count;
  logic [COUNT_WIDTH:0] used_cursor;
  logic [COUNT_WIDTH-1:0] queued_cursor;

  longint unsigned cycle_q;
  longint unsigned stopped_cycles_q;
  longint unsigned stop_cycle;
  longint unsigned resume_cycle;
  logic [COUNT_WIDTH-1:0] max_used_q;

  initial begin
    stop_cycle = 64'hffff_ffff_ffff_ffff;
    resume_cycle = 64'hffff_ffff_ffff_ffff;
    void'($value$plusargs("vet_sink_stop_cycle=%d", stop_cycle));
    void'($value$plusargs("vet_sink_resume_cycle=%d", resume_cycle));
    assert (NR_LANES == 2) else $fatal(1, "D1 integration sink requires exactly two lanes");
    assert (FIFO_DEPTH >= 2) else $fatal(1, "D1 integration sink FIFO_DEPTH must be at least two");
    assert (resume_cycle >= stop_cycle)
      else $fatal(1, "vet_sink_resume_cycle must not precede vet_sink_stop_cycle");
  end

  assign consumer_running = !((cycle_q >= stop_cycle) && (cycle_q < resume_cycle));
  assign consumer_stopped_o = !consumer_running;
  assign cancel_count = COUNT_WIDTH'(reservation_cancel[0])
      + COUNT_WIDTH'(reservation_cancel[1]);
  assign fire_count = COUNT_WIDTH'(fire_i[0]) + COUNT_WIDTH'(fire_i[1]);

  // The normal consumer has the same maximum width as the producer. This
  // prevents an unstopped dual-retire stream from manufacturing backpressure.
  always_comb begin : consumer_pop
    pop_count = '0;
    if (consumer_running) begin
      if (queued_q > COUNT_WIDTH'(NR_LANES)) pop_count = COUNT_WIDTH'(NR_LANES);
      else pop_count = queued_q;
    end
  end

  for (genvar lane = 0; lane < NR_LANES; lane++) begin : gen_reservation_status
    assign reservation_match[lane] = reserved_q[lane] && req_i[lane]
        && (reserved_tag_q[lane] == tag_i[lane]);
    assign reservation_cancel[lane] = reserved_q[lane] && !reservation_match[lane];
  end

  always_comb begin
    grant_o = '0;
    new_reservation = '0;
    used_cursor = {1'b0, used_q}
        - {1'b0, cancel_count}
        - {1'b0, pop_count};

    if (req_i[0]) begin
      if (reservation_match[0]) begin
        grant_o[0] = 1'b1;
      end else if (used_cursor < DEPTH_EXTENDED) begin
        grant_o[0] = 1'b1;
        new_reservation[0] = 1'b1;
        used_cursor = used_cursor + 1'b1;
      end
    end

    if (req_i[1] && req_i[0] && grant_o[0]) begin
      if (reservation_match[1]) begin
        grant_o[1] = 1'b1;
      end else if (used_cursor < DEPTH_EXTENDED) begin
        grant_o[1] = 1'b1;
        new_reservation[1] = 1'b1;
        used_cursor = used_cursor + 1'b1;
      end
    end

    reserved_d = reserved_q;
    reserved_tag_d = reserved_tag_q;
    for (int unsigned lane = 0; lane < NR_LANES; lane++) begin
      if (reservation_cancel[lane]) reserved_d[lane] = 1'b0;
      if (new_reservation[lane]) begin
        reserved_d[lane] = 1'b1;
        reserved_tag_d[lane] = tag_i[lane];
      end
      if (fire_i[lane]) reserved_d[lane] = 1'b0;
    end

    queued_cursor = queued_q - pop_count + fire_count;
    used_d = COUNT_WIDTH'(used_cursor);
    queued_d = COUNT_WIDTH'(queued_cursor);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reserved_q <= '0;
      reserved_tag_q <= '0;
      used_q <= '0;
      queued_q <= '0;
      cycle_q <= '0;
      stopped_cycles_q <= '0;
      max_used_q <= '0;
    end else begin
      reserved_q <= reserved_d;
      reserved_tag_q <= reserved_tag_d;
      used_q <= used_d;
      queued_q <= queued_d;
      cycle_q <= cycle_q + 1'b1;
      if (consumer_stopped_o) stopped_cycles_q <= stopped_cycles_q + 1'b1;
      if (used_d > max_used_q) max_used_q <= used_d;
    end
  end

  final begin
    $display("VET-ADMISSION-SINK cycles=%0d used=%0d queued=%0d reserved=%0b stopped_cycles=%0d max_used=%0d",
             cycle_q, used_q, queued_q, reserved_q, stopped_cycles_q, max_used_q);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Assertions disabled in reset.
    end else begin
      assert (!(req_i[1] && !req_i[0]))
        else $fatal(1, "commit requests are not a program-order prefix");
      assert (!(fire_i[1] && !fire_i[0]))
        else $fatal(1, "commit fires are not a program-order prefix");
      assert ((fire_i & ~grant_o) == 0)
        else $fatal(1, "commit fire occurred without a reservation grant");
      assert (used_q <= DEPTH_COUNT)
        else $fatal(1, "reservation/evidence capacity overflow");
      assert (queued_q <= used_q)
        else $fatal(1, "queued evidence exceeds reserved capacity");
      assert (pop_count <= queued_q && pop_count <= COUNT_WIDTH'(NR_LANES))
        else $fatal(1, "consumer pop exceeded queued tokens or lane width");
      assert ((queued_q
               + {{(COUNT_WIDTH-1){1'b0}}, reserved_q[0]}
               + {{(COUNT_WIDTH-1){1'b0}}, reserved_q[1]}) == used_q)
        else $fatal(1, "used credit is not conserved across queued/reserved tokens");
    end
  end

endmodule

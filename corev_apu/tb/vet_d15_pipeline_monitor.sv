// Testbench-only, observational D1.5 pipeline-event monitor for CVA6 v5.3.0.
//
// This module has no outputs and cannot alter fetch, issue, commit, or memory
// behavior.  It complements architectural RVFI evidence with the pre-commit
// facts needed to prove that a labelled candidate really existed before it
// was flushed.

module vet_d15_pipeline_monitor #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter logic [7:0] HART_ID = '0
) (
  input logic clk_i,
  input logic rst_ni,

  input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_valid_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_ready_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] fetch_pc_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] fetch_insn_i,

  input logic [CVA6Cfg.NrIssuePorts-1:0] decode_valid_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0] decode_ack_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] decode_pc_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] decode_insn_i,
  input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] issue_pointer_i,

  input logic resolved_valid_i,
  input logic resolved_mispredict_i,
  input logic resolved_taken_i,
  input logic [CVA6Cfg.VLEN-1:0] resolved_pc_i,
  input logic [CVA6Cfg.VLEN-1:0] resolved_target_i,

  input logic flush_if_i,
  input logic flush_unissued_i,
  input logic flush_id_i,
  input logic flush_ex_i,

  input logic frontend_replay_i,
  input logic [CVA6Cfg.VLEN-1:0] frontend_replay_addr_i,
  input logic icache_kill_s1_i,

  input logic ex_commit_valid_i,
  input logic [CVA6Cfg.XLEN-1:0] ex_commit_cause_i,
  input logic [CVA6Cfg.VLEN-1:0] commit_pc_i,

  input logic ipi_i,
  input logic timer_irq_i,
  input logic [1:0] irq_i
);

  integer output_fd;
  string output_path;
  bit enabled;
  bit irq_state_initialized;
  logic previous_ipi;
  logic previous_timer_irq;
  logic [1:0] previous_irq;
  longint unsigned cycle_count;
  longint unsigned fetch_count;
  longint unsigned decode_count;
  longint unsigned accepted_count;
  longint unsigned branch_count;
  longint unsigned mispredict_count;
  longint unsigned flush_count;
  longint unsigned replay_count;
  longint unsigned trap_count;
  longint unsigned irq_edge_count;

  initial begin
    enabled = $test$plusargs("vet_d15_events_enable");
    output_fd = 0;
    if (!$value$plusargs("vet_d15_events_file=%s", output_path)) begin
      output_path = "vet_d15_pipeline_events.jsonl";
    end
    if (enabled) begin
      output_fd = $fopen(output_path, "w");
      if (output_fd == 0) begin
        $fatal(1, "VET-RV D1.5: cannot open pipeline event output %s", output_path);
      end
      $display("VET-RV D1.5: pipeline monitor enabled: %s", output_path);
    end
  end

  final begin
    if (output_fd != 0) begin
      $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"SUMMARY\",\"hart\":%0d,\"fetch_count\":%0d,\"decode_count\":%0d,\"accepted_count\":%0d,\"branch_count\":%0d,\"mispredict_count\":%0d,\"flush_count\":%0d,\"replay_count\":%0d,\"trap_count\":%0d,\"irq_edge_count\":%0d}\n",
        cycle_count, HART_ID, fetch_count, decode_count,
        accepted_count, branch_count, mispredict_count, flush_count,
        replay_count, trap_count, irq_edge_count);
      $fclose(output_fd);
    end
  end

  // Blocking assignments intentionally keep the monitor's counters and JSONL
  // records ordered within one sampled cycle.  No monitored signal is driven.
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycle_count = 0;
      fetch_count = 0;
      decode_count = 0;
      accepted_count = 0;
      branch_count = 0;
      mispredict_count = 0;
      flush_count = 0;
      replay_count = 0;
      trap_count = 0;
      irq_edge_count = 0;
      irq_state_initialized = 0;
      previous_ipi = 1'b0;
      previous_timer_irq = 1'b0;
      previous_irq = '0;
    end else begin
      cycle_count = cycle_count + 1;

      if (enabled) begin
        for (int lane = 0; lane < CVA6Cfg.NrIssuePorts; lane++) begin
          if (fetch_valid_i[lane]) begin
            fetch_count = fetch_count + 1;
            $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"FETCH\",\"hart\":%0d,\"lane\":%0d,\"pc\":\"0x%016h\",\"insn\":\"0x%08h\",\"ready\":%0d,\"flush_if\":%0d}\n",
              cycle_count, HART_ID, lane, fetch_pc_i[lane],
              fetch_insn_i[lane], fetch_ready_i[lane], flush_if_i);
          end

          if (decode_valid_i[lane]) begin
            bit accepted;
            accepted = decode_ack_i[lane] && !flush_unissued_i;
            decode_count = decode_count + 1;
            if (accepted) accepted_count = accepted_count + 1;
            $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"DECODE\",\"hart\":%0d,\"lane\":%0d,\"pc\":\"0x%016h\",\"insn\":\"0x%08h\",\"issue_pointer\":%0d,\"ack\":%0d,\"accepted\":%0d,\"flush_unissued\":%0d}\n",
              cycle_count, HART_ID, lane, decode_pc_i[lane],
              decode_insn_i[lane], issue_pointer_i[lane], decode_ack_i[lane],
              accepted, flush_unissued_i);
          end
        end

        if (resolved_valid_i) begin
          branch_count = branch_count + 1;
          if (resolved_mispredict_i) mispredict_count = mispredict_count + 1;
          $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"BRANCH\",\"hart\":%0d,\"pc\":\"0x%016h\",\"target\":\"0x%016h\",\"taken\":%0d,\"mispredict\":%0d,\"flush_if\":%0d,\"flush_unissued\":%0d,\"flush_id\":%0d,\"flush_ex\":%0d}\n",
            cycle_count, HART_ID, resolved_pc_i, resolved_target_i,
            resolved_taken_i, resolved_mispredict_i, flush_if_i,
            flush_unissued_i, flush_id_i, flush_ex_i);
        end

        if (flush_if_i || flush_unissued_i || flush_id_i || flush_ex_i) begin
          flush_count = flush_count + 1;
          $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"FLUSH\",\"hart\":%0d,\"flush_if\":%0d,\"flush_unissued\":%0d,\"flush_id\":%0d,\"flush_ex\":%0d,\"branch_mispredict\":%0d,\"ex_commit_valid\":%0d}\n",
            cycle_count, HART_ID, flush_if_i, flush_unissued_i,
            flush_id_i, flush_ex_i, resolved_valid_i && resolved_mispredict_i,
            ex_commit_valid_i);
        end

        if (frontend_replay_i) begin
          replay_count = replay_count + 1;
          $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"REPLAY\",\"hart\":%0d,\"replay_addr\":\"0x%016h\",\"icache_kill_s1\":%0d}\n",
            cycle_count, HART_ID, frontend_replay_addr_i,
            icache_kill_s1_i);
        end

        if (ex_commit_valid_i) begin
          trap_count = trap_count + 1;
          $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"TRAP\",\"hart\":%0d,\"pc\":\"0x%016h\",\"cause\":\"0x%016h\",\"ipi\":%0d,\"timer_irq\":%0d,\"irq\":%0d,\"flush_if\":%0d,\"flush_unissued\":%0d,\"flush_id\":%0d,\"flush_ex\":%0d}\n",
            cycle_count, HART_ID, commit_pc_i, ex_commit_cause_i,
            ipi_i, timer_irq_i, irq_i, flush_if_i, flush_unissued_i,
            flush_id_i, flush_ex_i);
        end

        if (!irq_state_initialized || ipi_i != previous_ipi ||
            timer_irq_i != previous_timer_irq || irq_i != previous_irq) begin
          irq_edge_count = irq_edge_count + 1;
          $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-pipeline-events-1.0.0\",\"cycle\":%0d,\"kind\":\"IRQ_PIN\",\"hart\":%0d,\"ipi\":%0d,\"timer_irq\":%0d,\"irq\":%0d}\n",
            cycle_count, HART_ID, ipi_i, timer_irq_i, irq_i);
        end
      end

      irq_state_initialized = 1;
      previous_ipi = ipi_i;
      previous_timer_irq = timer_irq_i;
      previous_irq = irq_i;
    end
  end

endmodule

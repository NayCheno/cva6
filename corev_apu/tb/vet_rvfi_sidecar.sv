// Testbench-only RVFI JSONL sidecar for CVA6 v5.3.0.
//
// This module is observational: it does not feed rewrite annotations into the
// core and it cannot provide pre-commit backpressure.  It records the official
// cva6_rvfi output so the host adapter can construct canonical ACE events.

module vet_rvfi_sidecar #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter type rvfi_instr_t = logic,
  parameter logic [7:0] HART_ID = '0
) (
  input logic clk_i,
  input logic rst_ni,
  input rvfi_instr_t [CVA6Cfg.NrCommitPorts-1:0] rvfi_i
);

  integer output_fd;
  string output_path;
  bit enabled;
  longint unsigned cycle_count;
  longint unsigned next_retire_order;
  longint unsigned current_order;
  longint unsigned raw_value;
  int unsigned instruction_length;

  initial begin
    enabled = $test$plusargs("vet_rvfi_enable");
    output_fd = 0;
    if (!$value$plusargs("vet_rvfi_file=%s", output_path)) begin
      output_path = "vet_rvfi_raw.jsonl";
    end
    if (enabled) begin
      output_fd = $fopen(output_path, "w");
      if (output_fd == 0) begin
        $fatal(1, "VET-RV: cannot open RVFI sidecar output %s", output_path);
      end
      $display("VET-RV: RVFI sidecar enabled: %s", output_path);
    end
  end

  final begin
    if (output_fd != 0) begin
      $fclose(output_fd);
    end
  end

  // Blocking assignments are intentional: this is a testbench monitor and a
  // later commit lane must observe the order recorded for an earlier lane in
  // the same cycle.
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycle_count = 0;
      next_retire_order = 0;
    end else begin
      cycle_count = cycle_count + 1;
      if (enabled) begin
        for (int lane = 0; lane < CVA6Cfg.NrCommitPorts; lane++) begin
          if (rvfi_i[lane].valid || rvfi_i[lane].trap ||
              ((lane == 0) && rvfi_i[lane].cause[CVA6Cfg.XLEN-1])) begin
            // CVA6 v5.3.0 declares RVFI order/pc_wdata but does not drive
            // either field. Establish program order from the architecturally
            // ordered commit lanes. A trap-only boundary is located at the
            // next retirement cursor but does not consume a retirement ID.
            current_order = next_retire_order;
            if (rvfi_i[lane].valid) begin
              next_retire_order = next_retire_order + 1;
            end
            if (rvfi_i[lane].insn[1:0] == 2'b11) begin
              instruction_length = 4;
              raw_value = rvfi_i[lane].insn[31:0];
            end else begin
              instruction_length = 2;
              raw_value = rvfi_i[lane].insn[15:0];
            end

            // The pinned 5.008 frontend requires a literal format string;
            // passing an equivalent localparam string prints the percent
            // tokens verbatim and appends the arguments as raw values.
            $fwrite(output_fd, "{\"schema_version\":\"vet-rv-cva6-rvfi-raw-1.1.0\",\"cycle\":%0d,\"lane\":%0d,\"hart\":%0d,\"valid\":%0d,\"order\":%0d,\"reported_order_driven\":false,\"pc\":\"0x%016h\",\"reported_next_pc_driven\":false,\"original_insn\":\"0x%08h\",\"instr_len\":%0d,\"mode\":%0d,\"trap\":%0d,\"intr\":\"0x%016h\",\"cause\":\"0x%016h\",\"mem_addr\":\"0x%016h\",\"mem_wmask\":\"0x%02h\",\"mem_wdata\":\"0x%016h\"}\n",
              cycle_count, lane, HART_ID,
              rvfi_i[lane].valid, current_order,
              rvfi_i[lane].pc_rdata,
              raw_value[31:0], instruction_length,
              rvfi_i[lane].mode, rvfi_i[lane].trap, rvfi_i[lane].intr,
              rvfi_i[lane].cause, rvfi_i[lane].mem_addr,
              rvfi_i[lane].mem_wmask, rvfi_i[lane].mem_wdata);

          end
        end
      end
    end
  end

endmodule

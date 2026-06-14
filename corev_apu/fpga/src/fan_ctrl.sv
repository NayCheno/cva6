// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Description: PWM Fan Control for Genesys II board
// Author: Florian Zaruba, zarubaf@iis.ee.ethz.ch

module fan_ctrl (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic [11:0] device_temp_raw12_i,
    output logic        device_temp_valid_o,
    output logic [9:0]  device_temp_celsius_o,
    output logic [3:0]  pwm_setting_o,
    output logic       fan_pwm_o
);
    localparam logic [11:0] TEMP_VALID_MIN_RAW12 = 12'd2000;
    localparam logic [11:0] TEMP_FAN_OFF_RAW12   = 12'd2691; // 58 C
    localparam logic [11:0] TEMP_FAN_ON_RAW12    = 12'd2708; // 60 C
    localparam logic [11:0] TEMP_FAN_MID_RAW12   = 12'd2789; // 70 C
    localparam logic [11:0] TEMP_FAN_FULL_RAW12  = 12'd2870; // 80 C

    localparam logic [3:0] FAN_DUTY_OFF     = 4'd0;
    localparam logic [3:0] FAN_DUTY_UNKNOWN = 4'd4;
    localparam logic [3:0] FAN_DUTY_LOW     = 4'd4;
    localparam logic [3:0] FAN_DUTY_MID     = 4'd8;
    localparam logic [3:0] FAN_DUTY_FULL    = 4'd15;

    (* ASYNC_REG = "TRUE" *) logic [11:0] device_temp_meta_q;
    (* ASYNC_REG = "TRUE" *) logic [11:0] device_temp_sync_q;

    logic [11:0] device_temp_raw12_q;
    logic        device_temp_valid_d, device_temp_valid_q;
    logic [9:0]  device_temp_celsius_d, device_temp_celsius_q;
    logic [3:0]  ms_clock_d, ms_clock_q;
    logic [19:0] cycle_counter_d, cycle_counter_q;
    logic        fan_enabled_d, fan_enabled_q;
    logic [3:0]  pwm_setting_d, pwm_setting_q;

    function automatic logic [9:0] raw12_to_celsius(input logic [11:0] raw);
        logic [31:0] kelvin_approx;
        logic [31:0] celsius;
        begin
            // UG480 temperature approximation: Temp(C) = raw12 * 503.975 / 4096 - 273.15.
            kelvin_approx = (raw * 32'd504) >> 12;
            if (kelvin_approx > 32'd273) begin
                celsius = kelvin_approx - 32'd273;
                raw12_to_celsius = celsius > 32'd999 ? 10'd999 : celsius[9:0];
            end else begin
                raw12_to_celsius = 10'd0;
            end
        end
    endfunction

    // clock divider
    always_comb begin
        cycle_counter_d = cycle_counter_q;
        ms_clock_d = ms_clock_q;

        // divide clock by 499999
        if (cycle_counter_q == 499_999) begin
            cycle_counter_d = 0;
            ms_clock_d = ms_clock_q + 1;
        end else begin
            cycle_counter_d = cycle_counter_q + 1;
        end

        if (ms_clock_q == 15) begin
            ms_clock_d = 0;
        end
    end

    always_comb begin
        device_temp_valid_d = device_temp_raw12_q >= TEMP_VALID_MIN_RAW12;
        device_temp_celsius_d = device_temp_valid_d ? raw12_to_celsius(device_temp_raw12_q) : 10'd0;

        fan_enabled_d = fan_enabled_q;
        if (!device_temp_valid_d) begin
            fan_enabled_d = 1'b1;
        end else if (device_temp_raw12_q >= TEMP_FAN_ON_RAW12) begin
            fan_enabled_d = 1'b1;
        end else if (device_temp_raw12_q < TEMP_FAN_OFF_RAW12) begin
            fan_enabled_d = 1'b0;
        end

        if (!device_temp_valid_d) begin
            pwm_setting_d = FAN_DUTY_UNKNOWN;
        end else if (!fan_enabled_d) begin
            pwm_setting_d = FAN_DUTY_OFF;
        end else if (device_temp_raw12_q >= TEMP_FAN_FULL_RAW12) begin
            pwm_setting_d = FAN_DUTY_FULL;
        end else if (device_temp_raw12_q >= TEMP_FAN_MID_RAW12) begin
            pwm_setting_d = FAN_DUTY_MID;
        end else begin
            pwm_setting_d = FAN_DUTY_LOW;
        end

        device_temp_valid_o = device_temp_valid_q;
        device_temp_celsius_o = device_temp_celsius_q;
        pwm_setting_o = pwm_setting_q;
    end

    // duty cycle
    always_comb begin
        if (ms_clock_q < pwm_setting_q) begin
            fan_pwm_o = 1'b1;
        end else begin
            fan_pwm_o = 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            device_temp_meta_q <= '0;
            device_temp_sync_q <= '0;
            device_temp_raw12_q <= '0;
            device_temp_valid_q <= 1'b0;
            device_temp_celsius_q <= 10'd0;
            ms_clock_q      <= '0;
            cycle_counter_q <= '0;
            fan_enabled_q   <= 1'b1;
            pwm_setting_q   <= FAN_DUTY_UNKNOWN;
        end else begin
            device_temp_meta_q <= device_temp_raw12_i;
            device_temp_sync_q <= device_temp_meta_q;
            device_temp_raw12_q <= device_temp_sync_q;
            device_temp_valid_q <= device_temp_valid_d;
            device_temp_celsius_q <= device_temp_celsius_d;
            ms_clock_q      <= ms_clock_d;
            cycle_counter_q <= cycle_counter_d;
            fan_enabled_q   <= fan_enabled_d;
            pwm_setting_q   <= pwm_setting_d;
        end
    end
endmodule

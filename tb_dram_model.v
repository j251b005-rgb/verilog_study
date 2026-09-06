// Code your testbench here
// or browse Examples
`timescale 1ns / 1ps

module tb_wff_rff_dram_fixed;

    parameter CLK_PERIOD = 10;
    parameter WL = 4;
    parameter RL = 6;
    parameter BL = 8;
    parameter tRCD = 2;
    parameter tRP  = 2;

    localparam CMD_NOP = 4'b0000;
    localparam CMD_ACT = 4'b0001;
    localparam CMD_PRE = 4'b0010;
    localparam CMD_WR  = 4'b0011;
    localparam CMD_RD  = 4'b0100;

    localparam STATE_ACTIVE = 2'b01;

    reg        clk_tb;
    reg        rst_n_tb;
    reg        cs_n_tb;
    reg [8:0]  ca_tb;
    wire [7:0] dq_tb;
    wire       overflow_tb;

    reg [7:0] dq_drive;
    reg       dq_oe;

    reg [7:0] read_data [0:7];

    integer test_pass;
    integer test_fail;
    integer k;

    wff_rff_dram #(
        .FIFO_DEPTH (32),
        .ADDR_WIDTH (5),
        .DATA_WIDTH (8),
        .WL         (WL),
        .RL         (RL),
        .BL         (BL)
    ) dut (
        .clk      (clk_tb),
        .rst_n    (rst_n_tb),
        .cs_n     (cs_n_tb),
        .ca       (ca_tb),
        .dq       (dq_tb),
        .overflow (overflow_tb)
    );

    // Testbench drives DQ only during WRITE data transfer.
    assign dq_tb = dq_oe ? dq_drive : 8'hzz;

    initial begin
        clk_tb = 1'b0;
        forever #(CLK_PERIOD/2) clk_tb = ~clk_tb;
    end

    task wait_cycles;
        input integer cycles;
        integer n;
        begin
            for (n = 0; n < cycles; n = n + 1) begin
                @(posedge clk_tb);
            end
        end
    endtask

    task wait_for_active;
        begin
            while (dut.state !== STATE_ACTIVE) begin
                @(negedge clk_tb);
            end
        end
    endtask

    task send_act;
        input [4:0] address;
        begin
            $display("[%0t ns] ACT   address=0x%02h", $time, address);
            @(negedge clk_tb);
            cs_n_tb = 1'b0;
            ca_tb   = {address, CMD_ACT};

            @(negedge clk_tb);
            cs_n_tb = 1'b1;
            ca_tb   = {5'b00000, CMD_NOP};
        end
    endtask

    task send_pre;
        begin
            $display("[%0t ns] PRE", $time);
            @(negedge clk_tb);
            cs_n_tb = 1'b0;
            ca_tb   = {5'b00000, CMD_PRE};

            @(negedge clk_tb);
            cs_n_tb = 1'b1;
            ca_tb   = {5'b00000, CMD_NOP};
        end
    endtask

    task send_write;
        input [7:0] data0;
        input [7:0] data1;
        input [7:0] data2;
        input [7:0] data3;
        input [7:0] data4;
        input [7:0] data5;
        input [7:0] data6;
        input [7:0] data7;

        reg [7:0] data_array [0:7];
        integer n;
        begin
            data_array[0] = data0;
            data_array[1] = data1;
            data_array[2] = data2;
            data_array[3] = data3;
            data_array[4] = data4;
            data_array[5] = data5;
            data_array[6] = data6;
            data_array[7] = data7;

            $display("[%0t ns] WRITE command", $time);

            // Command is changed on the falling edge and sampled on the next
            // rising edge. This avoids a race with the DUT.
            @(negedge clk_tb);
            cs_n_tb = 1'b0;
            ca_tb   = {5'b00000, CMD_WR};

            @(negedge clk_tb);
            cs_n_tb = 1'b1;
            ca_tb   = {5'b00000, CMD_NOP};

            // The first data beat is sampled WL cycles after WRITE.
            if (WL > 1) begin
                wait_cycles(WL - 1);
                @(negedge clk_tb);
            end

            dq_oe    = 1'b1;
            dq_drive = data_array[0];

            for (n = 0; n < BL; n = n + 1) begin
                if (n > 0) begin
                    @(negedge clk_tb);
                    dq_drive = data_array[n];
                end

                $display("[%0t ns]   WRITE data[%0d] = 0x%02h",
                         $time, n, data_array[n]);
                @(posedge clk_tb);
            end

            @(negedge clk_tb);
            dq_oe    = 1'b0;
            dq_drive = 8'h00;
        end
    endtask

    task send_read;
        integer n;
        begin
            $display("[%0t ns] READ command", $time);

            @(negedge clk_tb);
            cs_n_tb = 1'b0;
            ca_tb   = {5'b00000, CMD_RD};

            @(negedge clk_tb);
            cs_n_tb = 1'b1;
            ca_tb   = {5'b00000, CMD_NOP};

            // Data becomes valid after RL rising edges. Sample on falling
            // edges so that the DUT has already updated its outputs.
            wait_cycles(RL);

            for (n = 0; n < BL; n = n + 1) begin
                @(negedge clk_tb);
                read_data[n] = dq_tb;
                $display("[%0t ns]   READ  data[%0d] = 0x%02h",
                         $time, n, read_data[n]);
            end
        end
    endtask

    initial begin
        $dumpfile("wff_rff_dram_fixed.vcd");
        $dumpvars(0, tb_wff_rff_dram_fixed);

        rst_n_tb  = 1'b0;
        cs_n_tb   = 1'b1;
        ca_tb     = {5'b00000, CMD_NOP};
        dq_oe     = 1'b0;
        dq_drive  = 8'h00;
        test_pass = 0;
        test_fail = 0;

        // Active-low reset: keep low, then release to high.
        wait_cycles(4);
        @(negedge clk_tb);
        rst_n_tb = 1'b1;
        wait_cycles(2);

        $display("========================================");
        $display("WFF/RFF DRAM test start");
        $display("========================================");

        // ---------------------------------------------------------------------
        // Test 1: normal burst at address 0
        // ---------------------------------------------------------------------
        $display("\nTest 1: normal burst at address 0");
        send_act(5'd0);
        wait_cycles(tRCD);
        send_write(8'hA0, 8'hA1, 8'hA2, 8'hA3,
                   8'hA4, 8'hA5, 8'hA6, 8'hA7);
        wait_for_active();
        send_read();
        wait_for_active();

        if ((read_data[0] === 8'hA0) && (read_data[1] === 8'hA1) &&
            (read_data[2] === 8'hA2) && (read_data[3] === 8'hA3) &&
            (read_data[4] === 8'hA4) && (read_data[5] === 8'hA5) &&
            (read_data[6] === 8'hA6) && (read_data[7] === 8'hA7) &&
            (overflow_tb === 1'b0)) begin
            $display("[PASS] Test 1 data matched");
            test_pass = test_pass + 1;
        end else begin
            $display("[FAIL] Test 1 data mismatch");
            test_fail = test_fail + 1;
        end

        send_pre();
        wait_cycles(tRP);

        // ---------------------------------------------------------------------
        // Test 2: a second independent address
        // ---------------------------------------------------------------------
        $display("\nTest 2: normal burst at address 8");
        send_act(5'd8);
        wait_cycles(tRCD);
        send_write(8'h50, 8'h51, 8'h52, 8'h53,
                   8'h54, 8'h55, 8'h56, 8'h57);
        wait_for_active();
        send_read();
        wait_for_active();

        if ((read_data[0] === 8'h50) && (read_data[1] === 8'h51) &&
            (read_data[2] === 8'h52) && (read_data[3] === 8'h53) &&
            (read_data[4] === 8'h54) && (read_data[5] === 8'h55) &&
            (read_data[6] === 8'h56) && (read_data[7] === 8'h57) &&
            (overflow_tb === 1'b0)) begin
            $display("[PASS] Test 2 data matched");
            test_pass = test_pass + 1;
        end else begin
            $display("[FAIL] Test 2 data mismatch");
            test_fail = test_fail + 1;
        end

        send_pre();
        wait_cycles(tRP);

        // ---------------------------------------------------------------------
        // Test 3: boundary test. Address 28 plus BL=8 crosses address 31.
        // B0-B3 are written to 28-31. B4-B7 are ignored.
        // Out-of-range reads return 00 and overflow must be 1.
        // ---------------------------------------------------------------------
        $display("\nTest 3: boundary overflow at address 28");
        send_act(5'd28);
        wait_cycles(tRCD);
        send_write(8'hB0, 8'hB1, 8'hB2, 8'hB3,
                   8'hB4, 8'hB5, 8'hB6, 8'hB7);
        wait_for_active();
        send_read();
        wait_for_active();

        if ((read_data[0] === 8'hB0) && (read_data[1] === 8'hB1) &&
            (read_data[2] === 8'hB2) && (read_data[3] === 8'hB3) &&
            (read_data[4] === 8'h00) && (read_data[5] === 8'h00) &&
            (read_data[6] === 8'h00) && (read_data[7] === 8'h00) &&
            (overflow_tb === 1'b1)) begin
            $display("[PASS] Test 3 boundary protection worked");
            test_pass = test_pass + 1;
        end else begin
            $display("[FAIL] Test 3 boundary protection failed");
            test_fail = test_fail + 1;
        end

        send_pre();
        wait_cycles(tRP);

        $display("\n========================================");
        $display("Test complete");
        $display("PASS = %0d", test_pass);
        $display("FAIL = %0d", test_fail);
        $display("========================================");

        wait_cycles(5);
        $finish;
    end

    initial begin
        #100000;
        $display("[ERROR] Simulation timeout");
        $finish;
    end

endmodule

// Code your design here
`timescale 1ns / 1ps

// =============================================================================
// Simplified WFF/RFF DRAM model
//
// Main memory : 32 x 8 bit
// WFF / RFF   : 8 entries each (one BL=8 burst)
// CA[8:4]     : 5-bit start address
// CA[3:0]     : command
//
// Out-of-range policy:
//   - Writes whose address is 32 or greater are ignored.
//   - Reads whose address is 32 or greater return 8'h00.
//   - overflow is asserted when a READ/WRITE burst crosses address 31.
// =============================================================================

module wff_rff_dram #(
    parameter FIFO_DEPTH = 32,
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 8,
    parameter WL = 4,
    parameter RL = 6,
    parameter BL = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  cs_n,
    input  wire [ADDR_WIDTH+3:0] ca,
    inout  wire [DATA_WIDTH-1:0] dq,
    output reg                   overflow
);

    localparam CMD_NOP = 4'b0000;
    localparam CMD_ACT = 4'b0001;
    localparam CMD_PRE = 4'b0010;
    localparam CMD_WR  = 4'b0011;
    localparam CMD_RD  = 4'b0100;

    localparam STATE_IDLE   = 2'b00;
    localparam STATE_ACTIVE = 2'b01;
    localparam STATE_READ   = 2'b10;
    localparam STATE_WRITE  = 2'b11;

    reg [1:0] state;
    reg [1:0] state_next;
    reg [ADDR_WIDTH-1:0] active_addr;

    wire       cmd_valid;
    wire [3:0] cmd;

    reg [DATA_WIDTH-1:0] main_mem [0:FIFO_DEPTH-1];
    reg [DATA_WIDTH-1:0] wr_data_buf [0:BL-1];
    reg [DATA_WIDTH-1:0] rd_data_buf [0:BL-1];

    reg [7:0] wl_cnt;
    reg       wl_active;
    reg [3:0] wr_burst_cnt;
    reg       wr_data_capture;

    reg [7:0] rl_cnt;
    reg       rl_active;
    reg [3:0] rd_burst_cnt;
    reg       rd_output_active;

    reg [DATA_WIDTH-1:0] dq_out;
    reg                  dq_oe;

    wire [ADDR_WIDTH:0] wr_linear_addr;

    integer mem_i;
    integer wr_i;
    integer rd_i;

    assign cmd_valid = ~cs_n;
    assign cmd = ca[3:0];

    // One extra address bit is kept so that 31 + 1 becomes 32 instead of 0.
    assign wr_linear_addr = {1'b0, active_addr} + wr_burst_cnt;

    assign dq = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

    initial begin
        for (mem_i = 0; mem_i < FIFO_DEPTH; mem_i = mem_i + 1) begin
            main_mem[mem_i] = {DATA_WIDTH{1'b0}};
        end
    end

    // -------------------------------------------------------------------------
    // State register: rst_n is active low.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // -------------------------------------------------------------------------
    // State transition logic
    // -------------------------------------------------------------------------
    always @(*) begin
        state_next = state;

        case (state)
            STATE_IDLE: begin
                if (cmd_valid && (cmd == CMD_ACT)) begin
                    state_next = STATE_ACTIVE;
                end
            end

            STATE_ACTIVE: begin
                if (cmd_valid) begin
                    case (cmd)
                        CMD_PRE: state_next = STATE_IDLE;
                        CMD_WR : state_next = STATE_WRITE;
                        CMD_RD : state_next = STATE_READ;
                        default: state_next = STATE_ACTIVE;
                    endcase
                end
            end

            STATE_WRITE: begin
                if (!wl_active && !wr_data_capture) begin
                    state_next = STATE_ACTIVE;
                end
            end

            STATE_READ: begin
                if (!rl_active && !rd_output_active) begin
                    state_next = STATE_ACTIVE;
                end
            end

            default: state_next = STATE_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // ACT address latch
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_addr <= {ADDR_WIDTH{1'b0}};
        end else if (cmd_valid && (cmd == CMD_ACT) && (state == STATE_IDLE)) begin
            active_addr <= ca[ADDR_WIDTH+3:4];
        end
    end

    // -------------------------------------------------------------------------
    // Overflow indication. It remains set until the next ACT command or reset.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow <= 1'b0;
        end else if (cmd_valid && (cmd == CMD_ACT) && (state == STATE_IDLE)) begin
            overflow <= 1'b0;
        end else if (cmd_valid && (state == STATE_ACTIVE) &&
                     ((cmd == CMD_WR) || (cmd == CMD_RD))) begin
            overflow <= ((active_addr + BL) > FIFO_DEPTH);
        end
    end

    // -------------------------------------------------------------------------
    // Write path: WRITE -> wait WL -> capture BL beats -> main_mem
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wl_cnt          <= 8'd0;
            wl_active       <= 1'b0;
            wr_burst_cnt    <= 4'd0;
            wr_data_capture <= 1'b0;

            for (wr_i = 0; wr_i < BL; wr_i = wr_i + 1) begin
                wr_data_buf[wr_i] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            if (cmd_valid && (cmd == CMD_WR) && (state == STATE_ACTIVE)) begin
                wr_burst_cnt <= 4'd0;

                if (WL > 1) begin
                    wl_active       <= 1'b1;
                    wl_cnt          <= WL - 1;
                    wr_data_capture <= 1'b0;
                end else begin
                    wl_active       <= 1'b0;
                    wl_cnt          <= 8'd0;
                    wr_data_capture <= 1'b1;
                end
            end else if (wl_active) begin
                if (wl_cnt > 1) begin
                    wl_cnt <= wl_cnt - 1'b1;
                end else begin
                    wl_cnt          <= 8'd0;
                    wl_active       <= 1'b0;
                    wr_data_capture <= 1'b1;
                end
            end else if (wr_data_capture) begin
                wr_data_buf[wr_burst_cnt] <= dq;

                // Only in-range addresses are written.
                if (wr_linear_addr < FIFO_DEPTH) begin
                    main_mem[wr_linear_addr[ADDR_WIDTH-1:0]] <= dq;
                end

                if (wr_burst_cnt == (BL - 1)) begin
                    wr_burst_cnt    <= 4'd0;
                    wr_data_capture <= 1'b0;
                end else begin
                    wr_burst_cnt <= wr_burst_cnt + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read path: main_mem -> RFF -> wait RL -> output BL beats
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rl_cnt           <= 8'd0;
            rl_active        <= 1'b0;
            rd_burst_cnt     <= 4'd0;
            rd_output_active <= 1'b0;

            for (rd_i = 0; rd_i < BL; rd_i = rd_i + 1) begin
                rd_data_buf[rd_i] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            if (cmd_valid && (cmd == CMD_RD) && (state == STATE_ACTIVE)) begin
                rd_burst_cnt     <= 4'd0;
                rd_output_active <= 1'b0;

                if (RL > 0) begin
                    rl_active <= 1'b1;
                    rl_cnt    <= RL;
                end else begin
                    rl_active        <= 1'b0;
                    rl_cnt           <= 8'd0;
                    rd_output_active <= 1'b1;
                end

                for (rd_i = 0; rd_i < BL; rd_i = rd_i + 1) begin
                    if ((active_addr + rd_i) < FIFO_DEPTH) begin
                        rd_data_buf[rd_i] <= main_mem[active_addr + rd_i];
                    end else begin
                        rd_data_buf[rd_i] <= {DATA_WIDTH{1'b0}};
                    end
                end
            end else if (rl_active) begin
                if (rl_cnt > 1) begin
                    rl_cnt <= rl_cnt - 1'b1;
                end else begin
                    rl_cnt           <= 8'd0;
                    rl_active        <= 1'b0;
                    rd_output_active <= 1'b1;
                    rd_burst_cnt     <= 4'd0;
                end
            end else if (rd_output_active) begin
                if (rd_burst_cnt == (BL - 1)) begin
                    rd_burst_cnt     <= 4'd0;
                    rd_output_active <= 1'b0;
                end else begin
                    rd_burst_cnt <= rd_burst_cnt + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // DRAM drives DQ only during the read-output window.
    // -------------------------------------------------------------------------
    always @(*) begin
        dq_out = {DATA_WIDTH{1'b0}};
        dq_oe  = 1'b0;

        if (rd_output_active && (rd_burst_cnt < BL)) begin
            dq_out = rd_data_buf[rd_burst_cnt];
            dq_oe  = 1'b1;
        end
    end

endmodule

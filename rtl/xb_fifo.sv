// =============================================================================
// xb_fifo.sv -- small synchronous FIFO (one per virtual output queue)
//
// First-word-fall-through: the head entry is visible on rd_data whenever
// !empty.  DEPTH must be a power of two (the pointers wrap with one extra
// bit to tell full from empty); anything else is refused at elaboration --
// formal found the single-FIFO build overflowing with N*DEPTH = 6.  Pushing when full or popping when empty is a caller error,
// and the formal properties check the switch never does either.
// =============================================================================
module xb_fifo #(
    parameter int W     = 8,
    parameter int DEPTH = 4,
    localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         push,
    input  logic [W-1:0] wr_data,
    input  logic         pop,
    output logic [W-1:0] rd_data,
    output logic         empty,
    output logic         full
);
    generate
        if ((DEPTH & (DEPTH - 1)) != 0 || DEPTH < 2) begin : g_check
            ERROR_xb_fifo_DEPTH_must_be_a_power_of_two_at_least_2 u_error ();
        end
    endgenerate

    logic [W-1:0] mem [DEPTH];
    logic [AW:0]  wp, rp;

    assign empty   = (wp == rp);
    assign full    = (wp[AW-1:0] == rp[AW-1:0]) && (wp[AW] != rp[AW]);
    assign rd_data = mem[rp[AW-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= '0;
            rp <= '0;
        end else begin
            if (push) wp <= wp + 1'b1;
            if (pop)  rp <= rp + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (push) mem[wp[AW-1:0]] <= wr_data;
    end

`ifdef FORMAL
    // F5: the switch never overfills or over-drains a queue.  The occupancy is
    // computed at pointer width: written inline as "(wp - rp) <= DEPTH", the
    // integer DEPTH widens the subtraction to 32 bits and a wrapped pointer
    // pair looks like a huge count (the first run of the proof caught that).
    logic [AW:0] f_count;
    assign f_count = wp - rp;
    always_comb begin
        if (rst_n) begin
            if (push) assert (!full);
            if (pop)  assert (!empty);
            assert (f_count <= DEPTH);
        end
    end
`endif
endmodule

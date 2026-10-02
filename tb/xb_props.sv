// =============================================================================
// xb_props.sv -- formal properties of xb_switch (instantiated inside it when
// FORMAL is defined; open-source Yosys has no hierarchical references)
//
//   F1  each input feeds at most one output in any cycle    (crossbar matching)
//   F2  packets are never interleaved: after a non-last beat on output j, j
//       stays locked to the same input
//   F3  outputs obey AXI4-Stream: with TVALID high and TREADY low, the beat
//       (TDATA, TLAST, TID) and TVALID hold until accepted
//   F4  starvation bound for round-robin outputs: while input i0 is free and
//       has a packet for output j0, at most N-1 OTHER inputs are matched to j0
//       before i0 is.  i0 and j0 are chosen by the solver (anyconst), so the
//       proof covers every input/output pair.
//   F5  (in xb_fifo) no queue is ever pushed when full or popped when empty
//
// F4 is proved with the invariant   losses + ptr_dist(gptr[j0] -> i0) <= N-1 :
// every match that overtakes i0 moves j0's pointer strictly closer to i0.
// =============================================================================
module xb_props #(
    parameter int N  = 3,
    parameter int DW = 2,
    localparam int IW = (N > 1) ? $clog2(N) : 1
) (
    input logic                       clk,
    input logic                       rst_n,
    input logic [N-1:0]               m_tvalid,
    input logic [N-1:0]               m_tready,
    input logic [N*DW-1:0]            m_tdata,
    input logic [N-1:0]               m_tlast,
    input logic [N*IW-1:0]            m_tid,
    input logic [N-1:0]               src_valid,
    input logic [N-1:0][IW-1:0]       src,
    input logic [N-1:0]               out_busy,
    input logic [N-1:0][IW-1:0]       out_src,
    input logic [N-1:0]               in_free,
    input logic [N-1:0][N-1:0]        q_ne,          // [i][j]
    input logic [N-1:0][N-1:0]        match_col,     // [j][i]
    input logic [N-1:0][IW-1:0]       gptr,
    input logic [N-1:0]               cfg_dwrr
);
    logic past_valid = 1'b0;
    always_ff @(posedge clk) past_valid <= 1'b1;

    // the pair the starvation property is about, chosen by the solver
    (* anyconst *) logic [IW-1:0] i0;
    (* anyconst *) logic [IW-1:0] j0;

    always_comb begin
        assume (i0 < N);
        assume (j0 < N);
        assume (!cfg_dwrr[j0]);           // F4 is the round-robin guarantee
    end

    // ---- F1 ---------------------------------------------------------------------
    always_comb begin
        if (rst_n)
            for (int a = 0; a < N; a++)
                for (int b = a + 1; b < N; b++)
                    if (src_valid[a] && src_valid[b]) assert (src[a] != src[b]);
    end

    // ---- F2 + F3 ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (past_valid && rst_n && $past(rst_n)) begin
            for (int j = 0; j < N; j++) begin
                // F2
                if ($past(m_tvalid[j] && m_tready[j] && !m_tlast[j])) begin
                    assert (out_busy[j]);
                    assert (out_src[j] == $past(m_tid[j*IW +: IW]));
                end
                // F3
                if ($past(m_tvalid[j] && !m_tready[j])) begin
                    assert (m_tvalid[j]);
                    assert (m_tdata[j*DW +: DW] == $past(m_tdata[j*DW +: DW]));
                    assert (m_tlast[j] == $past(m_tlast[j]));
                    assert (m_tid[j*IW +: IW] == $past(m_tid[j*IW +: IW]));
                end
            end
        end
    end

    // ---- F4 ---------------------------------------------------------------------
    logic          waiting;              // i0 free and holding a packet for j0
    logic          won;                  // i0 matched to j0 this cycle
    logic          lost;                 // another input matched to j0 instead
    logic [7:0]    losses;
    logic [IW-1:0] ptr_dist;                 // how far j0's pointer is from i0

    assign waiting = q_ne[i0][j0] && in_free[i0];
    assign won     = match_col[j0][i0];
    assign lost    = waiting && (match_col[j0] != '0) && !won;
    assign ptr_dist    = IW'((int'(i0) - int'(gptr[j0]) + N) % N);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 losses <= '0;
        else if (!waiting || won)   losses <= '0;
        else if (lost)              losses <= losses + 8'd1;
    end

    // the bound is tight: N-1 losses really can happen (a hierarchical
    // reference from the harness would silently be an undriven wire in Yosys,
    // so this cover lives here)
    always_ff @(posedge clk)
        if (rst_n) cover (losses == N - 1);

    always_comb begin
        if (rst_n) begin
            assert (losses <= N - 1);                       // F4
            if (losses != 0)
                assert (int'(losses) + int'(ptr_dist) <= N - 1); // inductive invariant
        end
    end

    // ---- invariants of the locks (help induction) -----------------------------------
    always_comb begin
        if (rst_n)
            for (int a = 0; a < N; a++) begin
                assert (out_src[a] < N);
                for (int b = a + 1; b < N; b++)
                    if (out_busy[a] && out_busy[b]) assert (out_src[a] != out_src[b]);
            end
    end
endmodule

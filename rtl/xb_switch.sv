// =============================================================================
// xb_switch.sv -- N x N packet crossbar switch, AXI4-Stream ports
//
//   s_* (N inputs)                                            m_* (N outputs)
//    in 0 --> [VOQ 0->0][VOQ 0->1]...[VOQ 0->N-1] --+
//    in 1 --> [VOQ 1->0] ...                         +--> N x N crossbar --> out j
//     ...                                            |      (out j muxes the
//    in N-1 -> ...                                 --+       VOQs i->j)
//                     ^                ^
//                  requests       allocator: output arbiters (RR or DWRR)
//                                          + input accept arbiters (RR)
//
// Packets
//   AXI4-Stream: TVALID/TREADY, TDATA, TLAST ends a packet, TDEST (first
//   beat) picks the output.  On the output side TID carries the input number.
//   Packets are never interleaved: an output stays locked to one input from
//   the first beat to TLAST (and an input sends one packet at a time).
//
// Head-of-line blocking (VOQ = 1, default)
//   Every input keeps one queue PER OUTPUT ("virtual output queues").  A
//   packet waiting for a busy output never blocks packets behind it that go
//   elsewhere.  VOQ = 0 builds the textbook alternative -- one FIFO per input
//   -- so the testbench can measure what HoL blocking costs (about 1/3 of the
//   throughput under uniform traffic).
//
// Allocation (iSLIP-style, one iteration, every cycle, combinational)
//   1. each FREE output j: arbiter picks one FREE input with a packet for j
//   2. each FREE input i: if several outputs picked it, accept one (RR)
//   3. a matched pair is locked until TLAST; its first beat moves the same
//      cycle, so back-to-back packets have no bubble
//   Pointers move only on an ACCEPTED grant, to one past the winner.  This is
//   what makes iSLIP fair: an input that is granted but declines does not
//   lose its turn, and no requester waits more than N-1 grants (proved in
//   formal/ for the RR outputs).
//
// Output arbitration, per output (cfg_dwrr[j])
//   RR    plain round robin among requesting inputs
//   DWRR  deficit weighted round robin: input i holds a credit counter at
//         each output.  Only inputs with credit > 0 may be granted; every beat
//         sent costs 1 credit (a packet may overdraw, it is never cut).  When
//         no requester has credit left, every input gets cfg_weight[i] more.
//         An input whose queue goes empty loses its credit (classic DRR), so
//         idle inputs cannot hoard.  Long-run bandwidth at a congested output
//         is proportional to the weights.
// =============================================================================
module xb_switch #(
    parameter int N     = 4,        // ports
    parameter int DW    = 32,       // TDATA width
    parameter int DEPTH = 4,        // beats per virtual output queue
    parameter bit VOQ   = 1,        // 0: one FIFO per input (HoL blocking)
    parameter int WW    = 4,        // weight width
    parameter int CW    = 8,        // DWRR credit counter width (signed)
    localparam int IW   = (N > 1) ? $clog2(N) : 1
) (
    input  logic                clk,
    input  logic                rst_n,

    // inputs
    input  logic [N-1:0]        s_tvalid,
    output logic [N-1:0]        s_tready,
    input  logic [N*DW-1:0]     s_tdata,
    input  logic [N-1:0]        s_tlast,
    input  logic [N*IW-1:0]     s_tdest,

    // outputs
    output logic [N-1:0]        m_tvalid,
    input  logic [N-1:0]        m_tready,
    output logic [N*DW-1:0]     m_tdata,
    output logic [N-1:0]        m_tlast,
    output logic [N*IW-1:0]     m_tid,

    // configuration (quasi-static)
    input  logic [N-1:0]        cfg_dwrr,      // per output: 0 RR, 1 DWRR
    input  logic [N*WW-1:0]     cfg_weight     // per input (0 counts as 1)
);
    // =========================================================================
    // helpers
    // =========================================================================
    // round robin: lowest requester at or after position ptr (wrapping)
    // Implemented as a masked priority pick: x & (~x + 1) isolates the lowest
    // set bit, first among requesters at or above the pointer, otherwise among
    // all of them.  An earlier "walk from the pointer until the first
    // requester" loop meant the same thing but synthesised to a ripple chain
    // linear in N; this form maps onto carry logic.
    function automatic logic [N-1:0] rr_pick(input logic [N-1:0] req, input logic [IW-1:0] ptr);
        logic [N-1:0] mask, upper;
        mask  = ~((N'(1) << ptr) - N'(1));          // positions >= ptr
        upper = req & mask;
        if (upper != '0) rr_pick = upper & (~upper + N'(1));
        else             rr_pick = req & (~req + N'(1));
        // (assignment to the function name: the Yosys front end used by the
        //  formal flow has no 'return')
    endfunction

    function automatic logic [IW-1:0] onehot_idx(input logic [N-1:0] v);
        logic [IW-1:0] r;
        r = '0;
        for (int k = 0; k < N; k++)
            if (v[k]) r = IW'(k);
        onehot_idx = r;
    endfunction

    function automatic logic [IW-1:0] next_ptr(input logic [IW-1:0] p);
        next_ptr = (int'(p) == N - 1) ? '0 : p + 1'b1;
    endfunction

    // =========================================================================
    // input side: packet tracking and queues
    // =========================================================================
    logic [N-1:0]          in_pkt;        // input i is in the middle of a packet
    logic [N-1:0][IW-1:0]  cur_dest;
    logic [N-1:0][IW-1:0]  dest_now;
    logic [N-1:0]          s_fire;

    // per (input i, output j) view of the queues -- in VOQ mode these are
    // the N*N queues themselves, in FIFO mode only the head of input i's FIFO
    // is visible, at the one output its destination names
    logic [N-1:0][N-1:0]          q_ne;          // [i][j] has a beat for j
    logic [N-1:0][N-1:0][DW-1:0]  q_data;
    logic [N-1:0][N-1:0]          q_last;
    logic [N-1:0][N-1:0]          q_pop;

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : g_in
            assign dest_now[gi] = in_pkt[gi] ? cur_dest[gi] : s_tdest[gi*IW +: IW];
            assign s_fire[gi]   = s_tvalid[gi] && s_tready[gi];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    in_pkt[gi]   <= 1'b0;
                    cur_dest[gi] <= '0;
                end else if (s_fire[gi]) begin
                    in_pkt[gi]   <= !s_tlast[gi];
                    cur_dest[gi] <= dest_now[gi];
                end
            end

            if (VOQ) begin : g_voq
                logic [N-1:0] full, empty;
                for (gj = 0; gj < N; gj++) begin : g_q
                    xb_fifo #(.W(DW + 1), .DEPTH(DEPTH)) u_q (
                        .clk     (clk),
                        .rst_n   (rst_n),
                        .push    (s_fire[gi] && dest_now[gi] == IW'(gj)),
                        .wr_data ({s_tlast[gi], s_tdata[gi*DW +: DW]}),
                        .pop     (q_pop[gi][gj]),
                        .rd_data ({q_last[gi][gj], q_data[gi][gj]}),
                        .empty   (empty[gj]),
                        .full    (full[gj])
                    );
                    assign q_ne[gi][gj] = !empty[gj];
                end
                assign s_tready[gi] = !full[dest_now[gi]];
            end else begin : g_fifo
                logic          full, empty;
                logic [IW-1:0] h_dest;
                logic [DW-1:0] h_data;
                logic          h_last;
                // same total storage as the VOQs, rounded up to a power of two
                xb_fifo #(.W(IW + DW + 1), .DEPTH(1 << $clog2(N * DEPTH))) u_q (
                    .clk     (clk),
                    .rst_n   (rst_n),
                    .push    (s_fire[gi]),
                    .wr_data ({dest_now[gi], s_tlast[gi], s_tdata[gi*DW +: DW]}),
                    .pop     (|q_pop[gi]),
                    .rd_data ({h_dest, h_last, h_data}),
                    .empty   (empty),
                    .full    (full)
                );
                for (gj = 0; gj < N; gj++) begin : g_view
                    assign q_ne[gi][gj]   = !empty && h_dest == IW'(gj);
                    assign q_data[gi][gj] = h_data;
                    assign q_last[gi][gj] = h_last;
                end
                assign s_tready[gi] = !full;
            end
        end
    endgenerate

    // =========================================================================
    // locks: output j is streaming a packet from input out_src[j]
    // =========================================================================
    logic [N-1:0]          out_busy;
    logic [N-1:0][IW-1:0]  out_src;
    logic [N-1:0]          in_free, out_free;

    // An input is busy exactly when some output is locked to it.  Deriving it
    // (instead of keeping a second copy) makes the two sides agree by
    // construction.
    always_comb begin
        in_free = '1;
        for (int j = 0; j < N; j++)
            if (out_busy[j]) in_free[out_src[j]] = 1'b0;
        out_free = ~out_busy;
    end

    // =========================================================================
    // allocation
    // =========================================================================
    logic [N-1:0][IW-1:0]          gptr;          // output grant pointers
    logic [N-1:0][IW-1:0]          aptr;          // input accept pointers
    logic [N-1:0][N-1:0]           req_col;       // [j][i] free input i wants free output j
    logic [N-1:0][N-1:0]           elig;          // [j][i] ... and may be granted
    logic [N-1:0][N-1:0]           grant;         // [j][i] output j grants input i
    logic [N-1:0][N-1:0]           grant_row;     // [i][j] transpose
    logic [N-1:0][N-1:0]           accept;        // [i][j] input i accepts output j
    logic [N-1:0][N-1:0]           match_col;     // [j][i] new match
    logic [N-1:0]                  need_refill;

    // DWRR credit counters: credit[j][i] = credit of input i at output j.
    // NOTE: an element selected from a packed array is UNSIGNED even if the
    // array is declared signed, so every comparison below uses $signed().
    logic [N-1:0][N-1:0][CW-1:0] credit;
    logic [N-1:0][N-1:0][CW-1:0] credit_eff;

    // credit + weight, saturating.  Both operands are extended EXPLICITLY:
    // mixing the signed credit with the unsigned weight in one expression made
    // the whole sum unsigned, so an overdrawn (negative) credit was zero-
    // extended into a huge positive one and saturated -- the inputs that had
    // overdrawn were rewarded instead of charged.  Caught by the fairness
    // test (weight-1 input got 74 % of the bandwidth).
    function automatic logic [CW-1:0] sat_add(input logic [CW-1:0] a, input logic [WW-1:0] w);
        logic signed [CW:0] s;
        logic [WW-1:0]      wv;
        wv = (w == '0) ? WW'(1) : w;
        s  = $signed({a[CW-1], a}) + $signed({{(CW + 1 - WW){1'b0}}, wv});
        if (s > $signed({2'b00, {(CW - 1){1'b1}}}))
            sat_add = {1'b0, {(CW - 1){1'b1}}};
        else
            sat_add = s[CW-1:0];
    endfunction

    always_comb begin
        for (int j = 0; j < N; j++) begin
            for (int i = 0; i < N; i++)
                req_col[j][i] = q_ne[i][j] && in_free[i] && out_free[j];

            // DWRR: when nobody who asks has credit left, everyone gets more
            need_refill[j] = 1'b0;
            if (cfg_dwrr[j] && (req_col[j] != '0)) begin
                need_refill[j] = 1'b1;
                for (int i = 0; i < N; i++)
                    if (req_col[j][i] && $signed(credit[j][i]) > 0) need_refill[j] = 1'b0;
            end
            for (int i = 0; i < N; i++) begin
                credit_eff[j][i] = need_refill[j] ? sat_add(credit[j][i], cfg_weight[i*WW +: WW])
                                                  : credit[j][i];
                elig[j][i] = req_col[j][i] && (!cfg_dwrr[j] || $signed(credit_eff[j][i]) > 0);
            end

            grant[j] = rr_pick(elig[j], gptr[j]);
        end

        for (int i = 0; i < N; i++) begin
            for (int j = 0; j < N; j++)
                grant_row[i][j] = grant[j][i];
            accept[i] = rr_pick(grant_row[i], aptr[i]);
        end

        for (int j = 0; j < N; j++)
            for (int i = 0; i < N; i++)
                match_col[j][i] = accept[i][j];
    end

    // =========================================================================
    // crossbar + outputs
    // =========================================================================
    logic [N-1:0][IW-1:0] src;           // input feeding output j this cycle
    logic [N-1:0]         src_valid;
    logic [N-1:0]         m_fire;

    always_comb begin
        q_pop = '0;
        for (int j = 0; j < N; j++) begin
            src_valid[j] = out_busy[j] || (match_col[j] != '0);
            src[j]       = out_busy[j] ? out_src[j] : onehot_idx(match_col[j]);
            m_tvalid[j]  = src_valid[j] && q_ne[src[j]][j];
            m_tdata[j*DW +: DW] = q_data[src[j]][j];
            m_tlast[j]   = q_last[src[j]][j];
            m_tid[j*IW +: IW]   = src[j];
            m_fire[j]    = m_tvalid[j] && m_tready[j];
            if (m_fire[j]) q_pop[src[j]][j] = 1'b1;
        end
    end

    // =========================================================================
    // state updates
    // =========================================================================
    // Credit accounting runs one cycle behind the data: the beat sent in cycle
    // t is charged in cycle t+1, from these registers.  Charging it in the
    // same cycle put grant -> accept -> transfer -> credit update all in one
    // path, which was the critical path (Vivado).  Fairness is a long-run
    // property, so a one-beat lag does not change the bandwidth shares.
    logic [N-1:0]         fire_q;
    logic [N-1:0][IW-1:0] fsrc_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_busy <= '0;
            out_src  <= '0;
            gptr     <= '0;
            aptr     <= '0;
            credit   <= '0;
            fire_q   <= '0;
            fsrc_q   <= '0;
        end else begin
            for (int j = 0; j < N; j++) begin
                // lock on a new match, release after the TLAST beat
                out_busy[j] <= src_valid[j] && !(m_fire[j] && m_tlast[j]);
                out_src[j]  <= src[j];
                fire_q[j]   <= m_fire[j] && cfg_dwrr[j];
                fsrc_q[j]   <= src[j];

                // iSLIP pointer update: only on an accepted grant
                if (match_col[j] != '0)
                    gptr[j] <= next_ptr(onehot_idx(match_col[j]));

                // DWRR credits
                for (int i = 0; i < N; i++) begin
                    logic signed [CW-1:0] c;
                    c = $signed(credit_eff[j][i]);
                    if (fire_q[j] && fsrc_q[j] == IW'(i))
                        c = (c == -(2 ** (CW - 1))) ? c : c - 1;
                    // an input with nothing for j (and not locked to it) keeps
                    // no credit.  (A brand-new match always has a queued beat.)
                    if (!q_ne[i][j] && !(out_busy[j] && out_src[j] == IW'(i)))
                        c = '0;
                    credit[j][i] <= c;
                end
            end
            for (int i = 0; i < N; i++)
                if (accept[i] != '0)
                    aptr[i] <= next_ptr(onehot_idx(accept[i]));
        end
    end

`ifdef FORMAL
    xb_props #(.N(N), .DW(DW)) u_props (
        .clk(clk), .rst_n(rst_n),
        .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tdata(m_tdata), .m_tlast(m_tlast), .m_tid(m_tid),
        .src_valid(src_valid), .src(src), .out_busy(out_busy), .out_src(out_src),
        .in_free(in_free), .q_ne(q_ne), .match_col(match_col), .gptr(gptr), .cfg_dwrr(cfg_dwrr));
`endif

endmodule

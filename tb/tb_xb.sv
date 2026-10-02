// =============================================================================
// tb_xb.sv -- self-checking testbench for xb_switch (Verilator --timing / xsim)
//
// Every beat carries {source, packet number, beat number} in its data, so the
// scoreboard can check each delivered packet precisely:
//   * it arrives at the output it was addressed to, with TID = its source
//   * its beats arrive complete, in order, TLAST on the last one
//   * packets from one source to one output arrive in the order sent
//   * nothing is interleaved (TID stays constant until TLAST)
//   * nothing is lost or invented (all queues empty at the end)
//
// Phases
//   1 functional   random destinations / lengths / gaps / backpressure, a
//                  random mix of RR and DWRR outputs with random weights
//   2 throughput   saturated uniform traffic, 1-beat packets, no backpressure:
//                  the classic head-of-line blocking experiment
//   3 fairness     every input floods output 0; bandwidth shares under RR,
//                  then under DWRR with weights 1:2:3:4
// =============================================================================
`timescale 1ns/1ps
`ifndef N
  `define N 4
`endif
`ifndef VOQ
  `define VOQ 1
`endif
`ifndef SEED
  `define SEED 1
`endif
`ifndef DEPTH
  `define DEPTH 4
`endif

module tb_xb;
    localparam int N  = `N;
    localparam int DW = 32;
    localparam int IW = (N > 1) ? $clog2(N) : 1;
    localparam int WW = 4;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [N-1:0]    s_tvalid = '0, s_tready, s_tlast = '0;
    logic [N*DW-1:0] s_tdata = '0;
    logic [N*IW-1:0] s_tdest = '0;
    logic [N-1:0]    m_tvalid, m_tready = '0, m_tlast;
    logic [N*DW-1:0] m_tdata;
    logic [N*IW-1:0] m_tid;
    logic [N-1:0]    cfg_dwrr = '0;
    logic [N*WW-1:0] cfg_weight = '0;

    xb_switch #(.N(N), .DW(DW), .DEPTH(`DEPTH), .VOQ(`VOQ)) dut (.*);

    // ------------------------------------------------------------------
    // traffic: one packet descriptor queue per input
    // ------------------------------------------------------------------
    typedef struct packed { logic [IW-1:0] dest; logic [7:0] len; logic [15:0] seq; } pkt_t;

    pkt_t   txq [N][$];                  // still to send
    int     exp_len [N][N][$];           // expected (source i, output j): lengths
    int     exp_seq [N][N][$];           //   ... and packet numbers, in order
    int     seq_ctr [N];

    // knobs
    int  gap_pct = 0, ready_pct = 100;
    bit  saturate = 0;                   // inputs never run dry
    int  sat_len_max = 1;
    int  hot_dest = -1;                  // >= 0: every packet goes there

    // stats
    longint cyc = 0;
    longint beats_out = 0, pkts_out = 0, errors = 0;
    longint beats_from [N];
    bit     measuring = 0;

    function automatic logic [DW-1:0] beat_word(int src, int seq, int beat);
        return {8'(src), 16'(seq), 8'(beat)};
    endfunction

    function automatic void new_packet(int i, int dest, int len);
        pkt_t p;
        p.dest = IW'(dest);
        p.len  = 8'(len);
        p.seq  = 16'(seq_ctr[i]);
        txq[i].push_back(p);
        exp_len[i][dest].push_back(len);
        exp_seq[i][dest].push_back(seq_ctr[i]);
        seq_ctr[i]++;
    endfunction

    // ------------------------------------------------------------------
    // input drivers (AXI4-Stream rules: hold a beat until it is accepted)
    // ------------------------------------------------------------------
    pkt_t cur [N];
    int   beat [N];
    bit   active [N];

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n) begin
            for (int i = 0; i < N; i++) begin
                if (s_tvalid[i] && s_tready[i]) begin
                    beat[i]++;
                    if (beat[i] == cur[i].len) active[i] = 0;
                end
                if (!s_tvalid[i] || s_tready[i]) begin
                    if (!active[i]) begin
                        if (txq[i].size() == 0 && saturate)
                            new_packet(i, (hot_dest >= 0) ? hot_dest : $urandom_range(N - 1),
                                       $urandom_range(1, sat_len_max));
                        if (txq[i].size() > 0) begin
                            cur[i]    = txq[i].pop_front();
                            beat[i]   = 0;
                            active[i] = 1;
                        end
                    end
                    if (active[i] && $urandom_range(99) >= gap_pct) begin
                        s_tvalid[i] <= 1'b1;
                        s_tdata[i*DW +: DW] <= beat_word(i, cur[i].seq, beat[i]);
                        s_tdest[i*IW +: IW] <= cur[i].dest;
                        s_tlast[i] <= (beat[i] == cur[i].len - 1);
                    end else begin
                        s_tvalid[i] <= 1'b0;
                    end
                end
            end
            for (int j = 0; j < N; j++)
                m_tready[j] <= ($urandom_range(99) < ready_pct);
        end
    end

    // ------------------------------------------------------------------
    // scoreboard, one per output
    // ------------------------------------------------------------------
    int  o_src  [N];
    int  o_beat [N];
    int  o_len  [N];
    int  o_seq  [N];
    bit  o_busy [N];

    task automatic fail(string msg);
        errors++;
        if (errors <= 10) $display("ERROR @%0d: %s", cyc, msg);
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            for (int j = 0; j < N; j++) begin
                if (m_tvalid[j] && m_tready[j]) begin
                    int src;
                    logic [DW-1:0] w;
                    src = int'(m_tid[j*IW +: IW]);
                    w   = m_tdata[j*DW +: DW];
                    beats_out++;
                    if (measuring) beats_from[src]++;
                    if (!o_busy[j]) begin
                        if (exp_len[src][j].size() == 0) begin
                            fail($sformatf("output %0d: unexpected packet from input %0d", j, src));
                            continue;
                        end
                        o_src[j]  = src;
                        o_len[j]  = exp_len[src][j].pop_front();
                        o_seq[j]  = exp_seq[src][j].pop_front();
                        o_beat[j] = 0;
                        o_busy[j] = 1;
                    end else if (src != o_src[j]) begin
                        fail($sformatf("output %0d: packet from %0d interleaved by %0d", j, o_src[j], src));
                    end
                    if (w !== beat_word(o_src[j], o_seq[j], o_beat[j]))
                        fail($sformatf("output %0d: got %h expected %h", j, w,
                                       beat_word(o_src[j], o_seq[j], o_beat[j])));
                    if (m_tlast[j] !== (o_beat[j] == o_len[j] - 1))
                        fail($sformatf("output %0d: TLAST wrong at beat %0d of %0d", j, o_beat[j], o_len[j]));
                    o_beat[j]++;
                    if (m_tlast[j]) begin
                        o_busy[j] = 0;
                        pkts_out++;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    task automatic drain();
        int t = 0;
        saturate = 0;
        forever begin
            bit idle = 1;
            for (int i = 0; i < N; i++)
                if (txq[i].size() || active[i] || s_tvalid[i]) idle = 0;
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++)
                    if (exp_len[i][j].size()) idle = 0;
            if (idle) break;
            @(posedge clk);
            if (++t > 200000) begin
                fail("drain timeout: packets never delivered");
                break;
            end
        end
        repeat (5) @(posedge clk);
    endtask

    task automatic window(int cycles);
        for (int i = 0; i < N; i++) beats_from[i] = 0;
        measuring = 1;
        repeat (cycles) @(posedge clk);
        measuring = 0;
    endtask

    function automatic longint sum_from();
        longint s = 0;
        for (int i = 0; i < N; i++) s += beats_from[i];
        return s;
    endfunction

    // ------------------------------------------------------------------
    // the test
    // ------------------------------------------------------------------
    int seed_dummy;
    initial begin
        seed_dummy = $urandom(`SEED);
        repeat (5) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        $display("== xb_switch %0dx%0d  %s, depth %0d  seed %0d", N, N,
                 `VOQ ? "VOQ" : "single FIFO per input", `DEPTH, `SEED);

        // ---- 1 functional ------------------------------------------------
        for (int round = 0; round < 4; round++) begin
            cfg_dwrr = N'($urandom);
            for (int i = 0; i < N; i++) cfg_weight[i*WW +: WW] = WW'($urandom_range(0, 15));
            gap_pct   = (round == 0) ? 0 : 30;
            ready_pct = (round == 1) ? 100 : (round == 3 ? 25 : 70);
            for (int i = 0; i < N; i++)
                repeat (150) new_packet(i, $urandom_range(N - 1), $urandom_range(1, 8));
            drain();
        end
        $display("  phase 1 functional: %0d packets, %0d beats delivered, %0d errors",
                 pkts_out, beats_out, errors);

        // ---- 2 throughput under uniform saturated traffic ------------------
        cfg_dwrr = '0; gap_pct = 0; ready_pct = 100;
        saturate = 1; sat_len_max = 1; hot_dest = -1;
        repeat (500) @(posedge clk);                       // warm up
        window(20000);
        $display("  phase 2 throughput (uniform, 1-beat packets, saturated): %5.1f %% of %0d ports x line rate",
                 100.0 * sum_from() / (20000.0 * N), N);
        drain();

        // ---- 3 fairness at a hotspot ------------------------------------
        saturate = 1; sat_len_max = 4; hot_dest = 0;
        for (int i = 0; i < N; i++) cfg_weight[i*WW +: WW] = WW'(i + 1);
        for (int mode = 0; mode < 2; mode++) begin
            cfg_dwrr = mode ? N'(1) : '0;
            repeat (500) @(posedge clk);
            window(20000);
            begin
                // declared, THEN assigned: an initialiser here would run once
                // only (static variable) and the second line would repeat the first
                string line;
                line = "";
                for (int i = 0; i < N; i++)
                    line = {line, $sformatf("  in%0d %4.1f%%", i, 100.0 * beats_from[i] / sum_from())};
                $display("  phase 3 output 0 shares, %s:%s", mode ? "DWRR weights 1:2:3:4" : "round robin        ", line);
            end
        end
        drain();

        $display("");
        if (errors == 0)
            $display("PASS: %0d packets, %0d beats delivered intact, in order, never interleaved", pkts_out, beats_out);
        else begin
            $display("FAIL: %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #200ms;
        $display("FAIL: watchdog");
        $fatal(1);
    end
endmodule

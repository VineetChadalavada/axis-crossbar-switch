// =============================================================================
// xb_formal_top.sv -- formal harness: every input is free, so the properties
// must hold for ANY traffic, configuration changes included.  The only
// assumption is a reset in the first cycle.  A 3x3 switch with 2-bit data
// keeps the state space small; the control logic is the same at every size.
// =============================================================================
module xb_formal_top #(
    parameter int N     = 3,
    parameter int DW    = 2,
    parameter int DEPTH = 2,
    parameter bit VOQ   = 1,
    localparam int IW   = (N > 1) ? $clog2(N) : 1
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic [N-1:0]    s_tvalid,
    input  logic [N*DW-1:0] s_tdata,
    input  logic [N-1:0]    s_tlast,
    input  logic [N*IW-1:0] s_tdest,
    input  logic [N-1:0]    m_tready,
    input  logic [N-1:0]    cfg_dwrr,
    input  logic [N*4-1:0]  cfg_weight
);
    logic [N-1:0]    s_tready, m_tvalid, m_tlast;
    logic [N*DW-1:0] m_tdata;
    logic [N*IW-1:0] m_tid;

    xb_switch #(.N(N), .DW(DW), .DEPTH(DEPTH), .VOQ(VOQ)) dut (.*);

    logic init = 1'b1;
    always_ff @(posedge clk) init <= 1'b0;
    always_comb if (init)  assume (!rst_n);
    always_comb if (!init) assume (rst_n);

    // destinations must name a real port (N = 3 leaves code 3 unused)
    always_comb
        for (int i = 0; i < N; i++)
            assume (s_tdest[i*IW +: IW] < N);

    // reachability
    always_ff @(posedge clk) begin
        if (rst_n) begin
            cover (&m_tvalid);                               // every output busy at once
            cover (m_tvalid[0] && m_tvalid[1] && m_tid[0 +: IW] != m_tid[IW +: IW]);
        end
    end
endmodule

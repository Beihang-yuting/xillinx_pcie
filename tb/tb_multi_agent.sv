//=============================================================================
// 文件名: tb_multi_agent.sv
// 描述: Xilinx PCIe BFM 多 agent 演示 Testbench (1 RC + 3 EP, 无 DUT)
//
// 功能：
//   1. 生成 250MHz 系统时钟（4ns 周期）
//   2. 产生 10+1 周期低电平有效复位
//   3. 实例化 1 套 RC + 3 套 EP 的 xilinx_pcie_if / xilinx_pcie_cfg_if
//   4. 无 DUT：各 agent 在自身 PCIE_IF 上发包，自身 monitor 解码线上内容
//      为使 master 通道不被反压，把 DUT 侧（宏不驱动的）master 通道 tready 拉高
//   5. 通过 WIRE 宏完成 axis_if 例化、桥接、indexed config_db 注册
//   6. 启动 run_test()
//
// 演示新增的可配置 agent 数量特性（cfg.num_rc / cfg.num_ep）。
//=============================================================================

`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_pcie_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import host_mem_pkg::*;
import xilinx_pcie_pkg::*;

module tb_multi_agent;

    //=========================================================================
    // 编译期参数 — 由 +define+DATA_WIDTH=N 驱动
    //=========================================================================
    localparam int DATA_WIDTH     = `XILINX_DATA_W;
    localparam int RQ_TUSER_WIDTH = `XILINX_RQ_TUSER_W;
    localparam int RC_TUSER_WIDTH = `XILINX_RC_TUSER_W;
    localparam int CQ_TUSER_WIDTH = `XILINX_CQ_TUSER_W;
    localparam int CC_TUSER_WIDTH = `XILINX_CC_TUSER_W;

    //=========================================================================
    // 统一内存实例（与 tb_top 保持一致；默认不影响仿真行为）
    //=========================================================================
    host_mem_manager host_mem_inst;
    host_mem_manager dev_mem_inst;

    //=========================================================================
    // 时钟与复位
    //=========================================================================
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #2ns clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
    end

    //=========================================================================
    // xilinx_pcie_if 实例化（1 RC + 3 EP）
    //=========================================================================
    xilinx_pcie_if #(
        .DATA_WIDTH(DATA_WIDTH), .RQ_TUSER_WIDTH(RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH(RC_TUSER_WIDTH), .CQ_TUSER_WIDTH(CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH(CC_TUSER_WIDTH)
    ) rc_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_if #(
        .DATA_WIDTH(DATA_WIDTH), .RQ_TUSER_WIDTH(RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH(RC_TUSER_WIDTH), .CQ_TUSER_WIDTH(CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH(CC_TUSER_WIDTH)
    ) ep0_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_if #(
        .DATA_WIDTH(DATA_WIDTH), .RQ_TUSER_WIDTH(RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH(RC_TUSER_WIDTH), .CQ_TUSER_WIDTH(CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH(CC_TUSER_WIDTH)
    ) ep1_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_if #(
        .DATA_WIDTH(DATA_WIDTH), .RQ_TUSER_WIDTH(RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH(RC_TUSER_WIDTH), .CQ_TUSER_WIDTH(CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH(CC_TUSER_WIDTH)
    ) ep2_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_cfg_if rc_cfg_if  (.clk(clk), .rst_n(rst_n));
    xilinx_pcie_cfg_if ep0_cfg_if (.clk(clk), .rst_n(rst_n));
    xilinx_pcie_cfg_if ep1_cfg_if (.clk(clk), .rst_n(rst_n));
    xilinx_pcie_cfg_if ep2_cfg_if (.clk(clk), .rst_n(rst_n));

    //=========================================================================
    // DUT 侧 master 通道 ready 拉高（无 DUT，故由 TB 顶替 DUT 驱动）
    //   宏仅消费（读取）master 通道的 PCIE_IF.<ch>_tready，不驱动它们：
    //     RC master 通道 = rc / cq  → 拉高 rc_tready / cq_tready
    //     EP master 通道 = rq / cc  → 拉高 rq_tready / cc_tready
    //   slave 通道的 *_tready 由宏（agent 侧）驱动，切勿在此再驱动，否则多驱动错误。
    //=========================================================================
    assign rc_if.rc_tready  = 1'b1;
    assign rc_if.cq_tready  = 1'b1;

    assign ep0_if.rq_tready = 1'b1;
    assign ep0_if.cc_tready = 1'b1;
    assign ep1_if.rq_tready = 1'b1;
    assign ep1_if.cc_tready = 1'b1;
    assign ep2_if.rq_tready = 1'b1;
    assign ep2_if.cc_tready = 1'b1;

    //=========================================================================
    // axis_if 例化 + 桥接 + indexed vif config_db 注册（由 WIRE 宏完成）
    //=========================================================================
    `XILINX_PCIE_WIRE_RC(0, rc_if,  rc_cfg_if,  clk, rst_n)
    `XILINX_PCIE_WIRE_EP(0, ep0_if, ep0_cfg_if, clk, rst_n)
    `XILINX_PCIE_WIRE_EP(1, ep1_if, ep1_cfg_if, clk, rst_n)
    `XILINX_PCIE_WIRE_EP(2, ep2_if, ep2_cfg_if, clk, rst_n)

    //=========================================================================
    // UVM config_db 注册 + run_test()
    //=========================================================================
    initial begin
        // axis vif 与 cfg/int vif 的 indexed 注册由 WIRE 宏完成。
        // 此处仅注入统一内存句柄（与 tb_top 一致）。
        host_mem_inst = new("host_mem");
        dev_mem_inst  = new("dev_mem");
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "host_mem", host_mem_inst);
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "dev_mem",  dev_mem_inst);

        run_test();
    end

    //=========================================================================
    // 波形转储
    //=========================================================================
    initial begin
        if ($test$plusargs("DUMP_WAVES")) begin
            $dumpfile("tb_multi_agent.vcd");
            $dumpvars(0, tb_multi_agent);
            $display("[tb_multi_agent] 波形录制已启动 -> tb_multi_agent.vcd");
        end
    end

    //=========================================================================
    // 仿真超时保护
    //=========================================================================
    initial begin
        #10ms;
        $display("[tb_multi_agent] 错误：仿真超时（10ms），强制结束");
        $finish(2);
    end

endmodule : tb_multi_agent

//=============================================================================
// 文件名: tb_allep_smoke.sv
// 描述: Xilinx PCIe BFM all-EP 冒烟 Testbench (0 RC + 2 EP, 无 DUT)
//
// 目的：证明 num_rc=0 配置可正常 build + connect + run，
//       验证 H1/H2 空指针防护（无 RC agent 时 v_sqr 共享管理器回退 EP，
//       旧 int_agent key 设置被门控）。
//
// 仅例化 EP（WIRE_EP(0)/WIRE_EP(1)），不调用任何 WIRE_RC。
// 各 EP 的 master 通道（rq/cc）DUT 侧 tready 拉高，避免反压。
//=============================================================================

`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_pcie_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import host_mem_pkg::*;
import xilinx_pcie_pkg::*;

module tb_allep_smoke;

    localparam int DATA_WIDTH     = `XILINX_DATA_W;
    localparam int RQ_TUSER_WIDTH = `XILINX_RQ_TUSER_W;
    localparam int RC_TUSER_WIDTH = `XILINX_RC_TUSER_W;
    localparam int CQ_TUSER_WIDTH = `XILINX_CQ_TUSER_W;
    localparam int CC_TUSER_WIDTH = `XILINX_CC_TUSER_W;

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
    // xilinx_pcie_if 实例化（0 RC + 2 EP）
    //=========================================================================
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

    xilinx_pcie_cfg_if ep0_cfg_if (.clk(clk), .rst_n(rst_n));
    xilinx_pcie_cfg_if ep1_cfg_if (.clk(clk), .rst_n(rst_n));

    //=========================================================================
    // EP master 通道（rq/cc）DUT 侧 tready 拉高（无 DUT）
    //=========================================================================
    assign ep0_if.rq_tready = 1'b1;
    assign ep0_if.cc_tready = 1'b1;
    assign ep1_if.rq_tready = 1'b1;
    assign ep1_if.cc_tready = 1'b1;

    //=========================================================================
    // 仅 EP WIRE 宏（无 WIRE_RC）
    //=========================================================================
    `XILINX_PCIE_WIRE_EP(0, ep0_if, ep0_cfg_if, clk, rst_n)
    `XILINX_PCIE_WIRE_EP(1, ep1_if, ep1_cfg_if, clk, rst_n)

    //=========================================================================
    // UVM config_db 注册 + run_test()
    //=========================================================================
    initial begin
        host_mem_inst = new("host_mem");
        dev_mem_inst  = new("dev_mem");
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "host_mem", host_mem_inst);
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "dev_mem",  dev_mem_inst);

        run_test();
    end

    //=========================================================================
    // 仿真超时保护
    //=========================================================================
    initial begin
        #10ms;
        $display("[tb_allep_smoke] 错误：仿真超时（10ms），强制结束");
        $finish(2);
    end

endmodule : tb_allep_smoke

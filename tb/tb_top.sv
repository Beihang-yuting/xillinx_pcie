//=============================================================================
// 文件名: tb_top.sv
// 描述: Xilinx PCIe BFM 回环仿真顶层 Testbench
//
// 功能：
//   1. 生成 250MHz 系统时钟（4ns 周期）
//   2. 产生 10 周期低电平有效复位
//   3. 实例化 RC 和 EP 两套 xilinx_pcie_if 接口
//   4. 实例化 RC 和 EP 两套 xilinx_pcie_cfg_if 接口
//   5. 实例化回环 DUT（xilinx_pcie_loopback_dut）交叉连线四通道
//   6. 为每个 axis_agent 通道（RC/EP 各 4 条，共 8 条）创建 axis_if 实例
//   7. 将所有虚拟接口注册到 UVM config_db
//   8. 启动 run_test()
//   9. 支持 +DUMP_WAVES plusarg 波形转储
//
// axis_if 按 PG213 各通道真实宽度例化，直连参数化 xilinx_pcie_if（无宽度适配）。
//=============================================================================

`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_pcie_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import host_mem_pkg::*;
import xilinx_pcie_pkg::*;

module tb_top;

    //=========================================================================
    // 编译期参数 — 由 +define+DATA_WIDTH=N 驱动
    // PG213 宽度: `DATA_WIDTH (64/128/256/512) + 各通道真实 TUSER 宽度
    //=========================================================================
    localparam int DATA_WIDTH     = `XILINX_DATA_W;
    localparam int RQ_TUSER_WIDTH = `XILINX_RQ_TUSER_W;
    localparam int RC_TUSER_WIDTH = `XILINX_RC_TUSER_W;
    localparam int CQ_TUSER_WIDTH = `XILINX_CQ_TUSER_W;
    localparam int CC_TUSER_WIDTH = `XILINX_CC_TUSER_W;

    //=========================================================================
    // 统一内存实例（$unit 作用域，以 host_mem_api 句柄注入 UVM config_db）
    // 仅在 use_unified_mem=1 时被使用；默认不影响任何仿真行为
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
    // xilinx_pcie_if 实例化（RC + EP）
    //=========================================================================
    xilinx_pcie_if #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) rc_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_if #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) ep_if (.clk(clk), .rst_n(rst_n));

    xilinx_pcie_cfg_if rc_cfg_if (.clk(clk), .rst_n(rst_n));
    xilinx_pcie_cfg_if ep_cfg_if (.clk(clk), .rst_n(rst_n));

    //=========================================================================
    // axis_if 实例化 + 桥接 + vif config_db 注册
    // 由 WIRE 宏完成（各 agent 4 通道 axis_if + tkeep 桥接 + indexed config_db set）
    //=========================================================================
    `XILINX_PCIE_WIRE_RC(0, rc_if, rc_cfg_if, clk, rst_n)
    `XILINX_PCIE_WIRE_EP(0, ep_if, ep_cfg_if, clk, rst_n)

    //=========================================================================
    // 回环 DUT 实例化
    //=========================================================================
    xilinx_pcie_loopback_dut #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) u_loopback_dut (
        .rc_if (rc_if),
        .ep_if (ep_if)
    );

    //=========================================================================
    // UVM config_db 注册 + run_test()
    //=========================================================================
    initial begin
        // 注意: 8 路 axis vif 的 config_db 注册已由 `XILINX_PCIE_WIRE_RC/EP 宏
        //       在 indexed 路径 (rc_agent_0/ep_agent_0) 完成。
        //       此处仅保留 cfg/interrupt agent 的 cfg_if（仍为非索引实例名）及统一内存。

        // RC 侧 cfg_if
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.rc_cfg_agent*", "cfg_vif", rc_cfg_if);
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.rc_int_agent*", "cfg_vif", rc_cfg_if);

        // EP 侧 cfg_if
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_cfg_agent*", "cfg_vif", ep_cfg_if);
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_int_agent*", "cfg_vif", ep_cfg_if);

        // 统一内存：创建具体 host_mem_manager，以 host_mem_api 句柄传入 UVM
        // use_unified_mem=0（默认）时 env/agent 不会调用这些句柄，行为无变化
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
            $dumpfile("tb_top.vcd");
            $dumpvars(0, tb_top);
            $display("[tb_top] 波形录制已启动 -> tb_top.vcd");
        end
    end

    //=========================================================================
    // 仿真超时保护
    //=========================================================================
    initial begin
        #10ms;
        $display("[tb_top] 错误：仿真超时（10ms），强制结束");
        $finish(2);
    end

endmodule : tb_top

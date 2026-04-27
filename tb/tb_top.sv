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
// config_db 注册路径说明（与 xilinx_pcie_base_agent 中的实例名对应）：
//   axis_if   键值 "vif"：
//     uvm_test_top.env.rc_agent.[rq|rc|cq|cc]_agent.*
//     uvm_test_top.env.ep_agent.[rq|rc|cq|cc]_agent.*
//   cfg_if    键值 "cfg_vif"：
//     uvm_test_top.env.rc_cfg_agent.*
//     uvm_test_top.env.ep_cfg_agent.*
//=============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;
import axis_pkg::*;
import xilinx_pcie_pkg::*;

module tb_top;

    //=========================================================================
    // 编译期参数
    //=========================================================================
    // AXI-Stream 数据位宽，通过编译宏 `TB_DATA_WIDTH 配置（默认 256bit）
    // 用法：vcs ... +define+TB_DATA_WIDTH=512
    `ifndef TB_DATA_WIDTH
        `define TB_DATA_WIDTH 256
    `endif
    localparam int DATA_WIDTH     = `TB_DATA_WIDTH;

    // 各通道 tuser 位宽根据 DATA_WIDTH 自动选择（PG213 Table 规范）
    // 64/128 -> 较小宽度；256 -> 中等宽度；512 -> 最大宽度
    localparam int RQ_TUSER_WIDTH = (DATA_WIDTH == 512) ? 285 :
                                    (DATA_WIDTH == 256) ? 137 : 62;
    localparam int RC_TUSER_WIDTH = (DATA_WIDTH == 512) ? 321 :
                                    (DATA_WIDTH == 256) ? 161 : 75;
    localparam int CQ_TUSER_WIDTH = (DATA_WIDTH == 512) ? 375 :
                                    (DATA_WIDTH == 256) ? 183 : 88;
    localparam int CC_TUSER_WIDTH = (DATA_WIDTH == 512) ? 161 :
                                    (DATA_WIDTH == 256) ? 81  : 33;
    // per-DW keep 位宽
    localparam int KEEP_WIDTH     = DATA_WIDTH / 32;

    //=========================================================================
    // 时钟与复位
    //=========================================================================
    logic clk;    // 250MHz PCIe 用户时钟
    logic rst_n;  // 低电平有效同步复位

    // 250MHz 时钟：半周期 2ns，全周期 4ns
    initial clk = 1'b0;
    always #2ns clk = ~clk;

    // 10 周期低有效复位后释放
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
    end

    //=========================================================================
    // xilinx_pcie_if 接口实例化（RC 侧 + EP 侧）
    //=========================================================================

    // RC 侧 PCIe 四通道 AXI-Stream 接口
    xilinx_pcie_if #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) rc_if (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // EP 侧 PCIe 四通道 AXI-Stream 接口
    xilinx_pcie_if #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) ep_if (
        .clk   (clk),
        .rst_n (rst_n)
    );

    //=========================================================================
    // xilinx_pcie_cfg_if 接口实例化（RC 侧 + EP 侧）
    //=========================================================================

    // RC 侧配置管理与中断边带接口
    xilinx_pcie_cfg_if rc_cfg_if (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // EP 侧配置管理与中断边带接口
    xilinx_pcie_cfg_if ep_cfg_if (
        .clk   (clk),
        .rst_n (rst_n)
    );

    //=========================================================================
    // axis_if 实例化（RC/EP 各 4 条通道，共 8 个实例）
    // 使用 axis_if 默认参数（TDATA_WIDTH=512, TUSER_WIDTH=512），
    // 保证所有 virtual axis_if 类型一致，避免参数化类型不匹配。
    // 桥接层负责处理实际 PCIe 位宽（256bit）与 axis_if 位宽（512bit）的转换。
    //=========================================================================

    // RC 侧 RQ 通道（RC agent 作为 SLAVE，接收 EP DMA 请求）
    // 使用 axis_if 默认参数（512/512），与 virtual axis_if 类型匹配
    axis_if rc_rq_if (.aclk(clk), .aresetn(rst_n));

    // RC 侧 RC 通道（RC agent 作为 MASTER，驱动完成数据到 EP）
    axis_if rc_rc_if (.aclk(clk), .aresetn(rst_n));

    // RC 侧 CQ 通道（RC agent 作为 MASTER，驱动请求到 EP）
    axis_if rc_cq_if (.aclk(clk), .aresetn(rst_n));

    // RC 侧 CC 通道（RC agent 作为 SLAVE，接收 EP 完成数据）
    axis_if rc_cc_if (.aclk(clk), .aresetn(rst_n));

    // EP 侧 RQ 通道（EP agent 作为 MASTER，驱动 DMA 请求）
    axis_if ep_rq_if (.aclk(clk), .aresetn(rst_n));

    // EP 侧 RC 通道（EP agent 作为 SLAVE，接收 RC 完成数据）
    axis_if ep_rc_if (.aclk(clk), .aresetn(rst_n));

    // EP 侧 CQ 通道（EP agent 作为 SLAVE，接收 RC 转发的请求）
    axis_if ep_cq_if (.aclk(clk), .aresetn(rst_n));

    // EP 侧 CC 通道（EP agent 作为 MASTER，驱动完成数据到 RC）
    axis_if ep_cc_if (.aclk(clk), .aresetn(rst_n));

    //=========================================================================
    // axis_if <-> xilinx_pcie_if 信号桥接
    // axis_if 使用默认参数（TDATA_WIDTH=512, TUSER_WIDTH=512），
    // xilinx_pcie_if 使用实际 PCIe 位宽（DATA_WIDTH=256, tuser 各通道不同）。
    // 桥接时需要做位宽截取/零填充：
    //   tdata: axis_if(512) <-> pcie_if(256)，高位补零/截取低位
    //   tkeep: axis_if(64=512/8) <-> pcie_if(8=256/32)，per-DW keep
    //   tuser: axis_if(512) <-> pcie_if(各通道不同)，高位补零/截取低位
    //   SLAVE 方向（接收）：axis_if = {0填充, pcie_if信号}
    //   MASTER 方向（发送）：pcie_if信号 = axis_if[低位]
    //=========================================================================
    // axis_if 默认位宽常量
    localparam int AXIS_TDATA_WIDTH = 512;
    localparam int AXIS_TKEEP_WIDTH = AXIS_TDATA_WIDTH / 8;  // 64
    localparam int AXIS_TUSER_WIDTH = 512;

    //=========================================================================
    // tkeep 格式转换辅助信号
    // xilinx_pcie_if 使用 per-DW tkeep（KEEP_WIDTH=8 位，每位对应一个 32-bit DW）
    // axis_if 使用 per-byte tkeep（AXIS_TKEEP_WIDTH=64 位，每位对应一个字节）
    //
    // MASTER 方向（axis_if -> xilinx_pcie_if）：
    //   将 per-byte tkeep 压缩为 per-DW tkeep（每 4 个 byte 位合并为 1 个 DW 位）
    // SLAVE 方向（xilinx_pcie_if -> axis_if）：
    //   将 per-DW tkeep 展开为 per-byte tkeep（每 1 个 DW 位展开为 4 个 byte 位）
    //=========================================================================

    // --- per-byte -> per-DW 压缩函数（MASTER 方向使用） ---
    // 从 axis_if 的 64-bit per-byte tkeep 中提取有效 DW 个数
    function automatic logic [KEEP_WIDTH-1:0] byte_keep_to_dw_keep(
        input logic [AXIS_TKEEP_WIDTH-1:0] byte_keep
    );
        logic [KEEP_WIDTH-1:0] dw_keep;
        // 遍历每个 DW 位置，只要 4 字节中任一有效则该 DW 有效
        for (int dw = 0; dw < KEEP_WIDTH; dw++) begin
            dw_keep[dw] = |byte_keep[dw*4 +: 4];
        end
        return dw_keep;
    endfunction

    // --- per-DW -> per-byte 展开函数（SLAVE 方向使用） ---
    // 将 per-DW tkeep 的每个位展开为对应的 4 个 byte 位
    function automatic logic [AXIS_TKEEP_WIDTH-1:0] dw_keep_to_byte_keep(
        input logic [KEEP_WIDTH-1:0] dw_keep
    );
        logic [AXIS_TKEEP_WIDTH-1:0] byte_keep;
        byte_keep = '0;
        for (int dw = 0; dw < KEEP_WIDTH; dw++) begin
            if (dw_keep[dw])
                byte_keep[dw*4 +: 4] = 4'hF;
        end
        return byte_keep;
    endfunction

    // --- 各通道 per-DW tkeep 中间信号 ---
    logic [KEEP_WIDTH-1:0] rc_rc_dw_keep;  // RC-RC MASTER: axis per-byte -> per-DW
    logic [KEEP_WIDTH-1:0] rc_cq_dw_keep;  // RC-CQ MASTER: axis per-byte -> per-DW
    logic [KEEP_WIDTH-1:0] ep_rq_dw_keep;  // EP-RQ MASTER: axis per-byte -> per-DW
    logic [KEEP_WIDTH-1:0] ep_cc_dw_keep;  // EP-CC MASTER: axis per-byte -> per-DW

    // MASTER 方向：从 axis_if per-byte tkeep 压缩为 per-DW tkeep
    always_comb rc_rc_dw_keep = byte_keep_to_dw_keep(rc_rc_if.tkeep);
    always_comb rc_cq_dw_keep = byte_keep_to_dw_keep(rc_cq_if.tkeep);
    always_comb ep_rq_dw_keep = byte_keep_to_dw_keep(ep_rq_if.tkeep);
    always_comb ep_cc_dw_keep = byte_keep_to_dw_keep(ep_cc_if.tkeep);

    // RC-RQ：axis SLAVE（接收来自 loopback_dut 的 ep->rc rq 数据）
    // SLAVE 方向：per-DW tkeep 展开为 per-byte tkeep
    assign rc_rq_if.tdata              = { {(AXIS_TDATA_WIDTH-DATA_WIDTH){1'b0}}, rc_if.rq_tdata };
    assign rc_rq_if.tkeep              = dw_keep_to_byte_keep(rc_if.rq_tkeep);
    assign rc_rq_if.tlast              = rc_if.rq_tlast;
    assign rc_rq_if.tvalid             = rc_if.rq_tvalid;
    assign rc_rq_if.tuser              = { {(AXIS_TUSER_WIDTH-RQ_TUSER_WIDTH){1'b0}}, rc_if.rq_tuser };
    assign rc_if.rq_tready             = rc_rq_if.tready;

    // RC-RC：axis MASTER（向 ep_if.rc_* 驱动完成数据，经 loopback_dut 转发给 EP）
    // MASTER 方向：per-byte tkeep 压缩为 per-DW tkeep
    assign rc_if.rc_tdata              = rc_rc_if.tdata[DATA_WIDTH-1:0];
    assign rc_if.rc_tkeep              = rc_rc_dw_keep;
    assign rc_if.rc_tlast              = rc_rc_if.tlast;
    assign rc_if.rc_tvalid             = rc_rc_if.tvalid;
    assign rc_if.rc_tuser              = rc_rc_if.tuser[RC_TUSER_WIDTH-1:0];
    assign rc_rc_if.tready             = rc_if.rc_tready;

    // RC-CQ：axis MASTER（向 ep_if.cq_* 驱动请求，经 loopback_dut 转发给 EP）
    // MASTER 方向：per-byte tkeep 压缩为 per-DW tkeep
    assign rc_if.cq_tdata              = rc_cq_if.tdata[DATA_WIDTH-1:0];
    assign rc_if.cq_tkeep              = rc_cq_dw_keep;
    assign rc_if.cq_tlast              = rc_cq_if.tlast;
    assign rc_if.cq_tvalid             = rc_cq_if.tvalid;
    assign rc_if.cq_tuser              = rc_cq_if.tuser[CQ_TUSER_WIDTH-1:0];
    assign rc_cq_if.tready             = rc_if.cq_tready;

    // RC-CC：axis SLAVE（接收来自 loopback_dut 的 ep->rc cc 完成数据）
    // SLAVE 方向：per-DW tkeep 展开为 per-byte tkeep
    assign rc_cc_if.tdata              = { {(AXIS_TDATA_WIDTH-DATA_WIDTH){1'b0}}, rc_if.cc_tdata };
    assign rc_cc_if.tkeep              = dw_keep_to_byte_keep(rc_if.cc_tkeep);
    assign rc_cc_if.tlast              = rc_if.cc_tlast;
    assign rc_cc_if.tvalid             = rc_if.cc_tvalid;
    assign rc_cc_if.tuser              = { {(AXIS_TUSER_WIDTH-CC_TUSER_WIDTH){1'b0}}, rc_if.cc_tuser };
    assign rc_if.cc_tready             = rc_cc_if.tready;

    // EP-RQ：axis MASTER（EP 向 rc_if.rq_* 驱动 DMA 请求）
    // MASTER 方向：per-byte tkeep 压缩为 per-DW tkeep
    assign ep_if.rq_tdata              = ep_rq_if.tdata[DATA_WIDTH-1:0];
    assign ep_if.rq_tkeep              = ep_rq_dw_keep;
    assign ep_if.rq_tlast              = ep_rq_if.tlast;
    assign ep_if.rq_tvalid             = ep_rq_if.tvalid;
    assign ep_if.rq_tuser              = ep_rq_if.tuser[RQ_TUSER_WIDTH-1:0];
    assign ep_rq_if.tready             = ep_if.rq_tready;

    // EP-RC：axis SLAVE（EP 接收来自 loopback_dut 的 rc->ep rc 完成数据）
    // SLAVE 方向：per-DW tkeep 展开为 per-byte tkeep
    assign ep_rc_if.tdata              = { {(AXIS_TDATA_WIDTH-DATA_WIDTH){1'b0}}, ep_if.rc_tdata };
    assign ep_rc_if.tkeep              = dw_keep_to_byte_keep(ep_if.rc_tkeep);
    assign ep_rc_if.tlast              = ep_if.rc_tlast;
    assign ep_rc_if.tvalid             = ep_if.rc_tvalid;
    assign ep_rc_if.tuser              = { {(AXIS_TUSER_WIDTH-RC_TUSER_WIDTH){1'b0}}, ep_if.rc_tuser };
    assign ep_if.rc_tready             = ep_rc_if.tready;

    // EP-CQ：axis SLAVE（EP 接收来自 loopback_dut 的 rc->ep cq 请求数据）
    // SLAVE 方向：per-DW tkeep 展开为 per-byte tkeep
    assign ep_cq_if.tdata              = { {(AXIS_TDATA_WIDTH-DATA_WIDTH){1'b0}}, ep_if.cq_tdata };
    assign ep_cq_if.tkeep              = dw_keep_to_byte_keep(ep_if.cq_tkeep);
    assign ep_cq_if.tlast              = ep_if.cq_tlast;
    assign ep_cq_if.tvalid             = ep_if.cq_tvalid;
    assign ep_cq_if.tuser              = { {(AXIS_TUSER_WIDTH-CQ_TUSER_WIDTH){1'b0}}, ep_if.cq_tuser };
    assign ep_if.cq_tready             = ep_cq_if.tready;

    // EP-CC：axis MASTER（EP 向 rc_if.cc_* 驱动完成数据）
    // MASTER 方向：per-byte tkeep 压缩为 per-DW tkeep
    assign ep_if.cc_tdata              = ep_cc_if.tdata[DATA_WIDTH-1:0];
    assign ep_if.cc_tkeep              = ep_cc_dw_keep;
    assign ep_if.cc_tlast              = ep_cc_if.tlast;
    assign ep_if.cc_tvalid             = ep_cc_if.tvalid;
    assign ep_if.cc_tuser              = ep_cc_if.tuser[CC_TUSER_WIDTH-1:0];
    assign ep_cc_if.tready             = ep_if.cc_tready;

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
    // UVM config_db 虚拟接口注册 + run_test()
    //=========================================================================
    initial begin

        // ------------------------------------------------------------------
        // RC 侧四个通道的 axis_if 虚拟接口
        // 路径与 xilinx_pcie_base_agent.create_axis_agent() 中的实例名一致：
        //   rq_agent / rc_agent / cq_agent / cc_agent
        // ------------------------------------------------------------------
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.rc_agent.rq_agent*", "vif", rc_rq_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.rc_agent.rc_agent*", "vif", rc_rc_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.rc_agent.cq_agent*", "vif", rc_cq_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.rc_agent.cc_agent*", "vif", rc_cc_if);

        // ------------------------------------------------------------------
        // EP 侧四个通道的 axis_if 虚拟接口
        // ------------------------------------------------------------------
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.ep_agent.rq_agent*", "vif", ep_rq_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.ep_agent.rc_agent*", "vif", ep_rc_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.ep_agent.cq_agent*", "vif", ep_cq_if);
        uvm_config_db #(virtual axis_if)::set(
            null, "uvm_test_top.env.ep_agent.cc_agent*", "vif", ep_cc_if);

        // ------------------------------------------------------------------
        // RC 侧 cfg_if 虚拟接口（cfg_agent 与 interrupt_agent 均使用同一接口）
        // ------------------------------------------------------------------
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.rc_cfg_agent*", "cfg_vif", rc_cfg_if);
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.rc_int_agent*", "cfg_vif", rc_cfg_if);

        // ------------------------------------------------------------------
        // EP 侧 cfg_if 虚拟接口
        // ------------------------------------------------------------------
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_cfg_agent*", "cfg_vif", ep_cfg_if);
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_int_agent*", "cfg_vif", ep_cfg_if);

        // 启动 UVM 测试（测试名通过 +UVM_TESTNAME=<name> 传入）
        run_test();
    end

    //=========================================================================
    // 可选波形转储（+DUMP_WAVES plusarg）
    //=========================================================================
    initial begin
        if ($test$plusargs("DUMP_WAVES")) begin
            $dumpfile("tb_top.vcd");
            $dumpvars(0, tb_top);
            $display("[tb_top] 波形录制已启动 -> tb_top.vcd");
        end
    end

    //=========================================================================
    // tready 说明：
    // 修正 agent_mode 映射后，SLAVE 通道的 axis_slave_driver 会正确驱动 tready，
    // MASTER 通道的 tready 由对端 SLAVE 驱动或由 loopback_dut 反压控制。
    // 不再需要 force tready debug hack。
    //=========================================================================

    //=========================================================================
    // 仿真超时保护（10ms 硬限制，防止 UVM objection 未释放导致永久挂起）
    //=========================================================================
    initial begin
        #10ms;
        $display("[tb_top] 错误：仿真超时（10ms），强制结束");
        $finish(2);
    end

endmodule : tb_top

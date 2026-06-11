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
    localparam int KEEP_WIDTH     = `XILINX_KEEP_W;

    //=========================================================================
    // 各通道参数化 vif typedef（参数须与 pkg 中 axis_agent_xx_t 内部 vif_t 一致）
    //=========================================================================
    typedef virtual axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) vif_rq_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) vif_rc_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) vif_cq_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) vif_cc_t;

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
    // axis_if 实例化 — 8 通道, 各通道按 PG213 真实宽度参数化
    //=========================================================================
    axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) rc_rq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) rc_rc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) rc_cq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) rc_cc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) ep_rq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) ep_rc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) ep_cq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) ep_cc_if (.aclk(clk), .aresetn(rst_n));

    //=========================================================================
    // axis_if <-> xilinx_pcie_if 桥接
    // 两侧 tdata/tuser 已等宽，直接 assign。
    // tkeep 仍需转换：axis 为 per-byte，pcie 为 per-DW。
    //=========================================================================
    localparam int AXIS_TKEEP_WIDTH = DATA_WIDTH / 8;

    function automatic logic [KEEP_WIDTH-1:0] byte_keep_to_dw_keep(
        input logic [AXIS_TKEEP_WIDTH-1:0] byte_keep
    );
        logic [KEEP_WIDTH-1:0] dw_keep;
        for (int dw = 0; dw < KEEP_WIDTH; dw++) begin
            dw_keep[dw] = |byte_keep[dw*4 +: 4];
        end
        return dw_keep;
    endfunction

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

    logic [KEEP_WIDTH-1:0] rc_rc_dw_keep;
    logic [KEEP_WIDTH-1:0] rc_cq_dw_keep;
    logic [KEEP_WIDTH-1:0] ep_rq_dw_keep;
    logic [KEEP_WIDTH-1:0] ep_cc_dw_keep;

    always_comb rc_rc_dw_keep = byte_keep_to_dw_keep(rc_rc_if.tkeep[AXIS_TKEEP_WIDTH-1:0]);
    always_comb rc_cq_dw_keep = byte_keep_to_dw_keep(rc_cq_if.tkeep[AXIS_TKEEP_WIDTH-1:0]);
    always_comb ep_rq_dw_keep = byte_keep_to_dw_keep(ep_rq_if.tkeep[AXIS_TKEEP_WIDTH-1:0]);
    always_comb ep_cc_dw_keep = byte_keep_to_dw_keep(ep_cc_if.tkeep[AXIS_TKEEP_WIDTH-1:0]);

    // RC-RQ: axis SLAVE
    assign rc_rq_if.tdata  = rc_if.rq_tdata;
    assign rc_rq_if.tkeep  = dw_keep_to_byte_keep(rc_if.rq_tkeep);
    assign rc_rq_if.tlast  = rc_if.rq_tlast;
    assign rc_rq_if.tvalid = rc_if.rq_tvalid;
    assign rc_rq_if.tuser  = rc_if.rq_tuser;
    assign rc_if.rq_tready = rc_rq_if.tready;

    // RC-RC: axis MASTER
    assign rc_if.rc_tdata  = rc_rc_if.tdata;
    assign rc_if.rc_tkeep  = rc_rc_dw_keep;
    assign rc_if.rc_tlast  = rc_rc_if.tlast;
    assign rc_if.rc_tvalid = rc_rc_if.tvalid;
    assign rc_if.rc_tuser  = rc_rc_if.tuser;
    assign rc_rc_if.tready = rc_if.rc_tready;

    // RC-CQ: axis MASTER
    assign rc_if.cq_tdata  = rc_cq_if.tdata;
    assign rc_if.cq_tkeep  = rc_cq_dw_keep;
    assign rc_if.cq_tlast  = rc_cq_if.tlast;
    assign rc_if.cq_tvalid = rc_cq_if.tvalid;
    assign rc_if.cq_tuser  = rc_cq_if.tuser;
    assign rc_cq_if.tready = rc_if.cq_tready;

    // RC-CC: axis SLAVE
    assign rc_cc_if.tdata  = rc_if.cc_tdata;
    assign rc_cc_if.tkeep  = dw_keep_to_byte_keep(rc_if.cc_tkeep);
    assign rc_cc_if.tlast  = rc_if.cc_tlast;
    assign rc_cc_if.tvalid = rc_if.cc_tvalid;
    assign rc_cc_if.tuser  = rc_if.cc_tuser;
    assign rc_if.cc_tready = rc_cc_if.tready;

    // EP-RQ: axis MASTER
    assign ep_if.rq_tdata  = ep_rq_if.tdata;
    assign ep_if.rq_tkeep  = ep_rq_dw_keep;
    assign ep_if.rq_tlast  = ep_rq_if.tlast;
    assign ep_if.rq_tvalid = ep_rq_if.tvalid;
    assign ep_if.rq_tuser  = ep_rq_if.tuser;
    assign ep_rq_if.tready = ep_if.rq_tready;

    // EP-RC: axis SLAVE
    assign ep_rc_if.tdata  = ep_if.rc_tdata;
    assign ep_rc_if.tkeep  = dw_keep_to_byte_keep(ep_if.rc_tkeep);
    assign ep_rc_if.tlast  = ep_if.rc_tlast;
    assign ep_rc_if.tvalid = ep_if.rc_tvalid;
    assign ep_rc_if.tuser  = ep_if.rc_tuser;
    assign ep_if.rc_tready = ep_rc_if.tready;

    // EP-CQ: axis SLAVE
    assign ep_cq_if.tdata  = ep_if.cq_tdata;
    assign ep_cq_if.tkeep  = dw_keep_to_byte_keep(ep_if.cq_tkeep);
    assign ep_cq_if.tlast  = ep_if.cq_tlast;
    assign ep_cq_if.tvalid = ep_if.cq_tvalid;
    assign ep_cq_if.tuser  = ep_if.cq_tuser;
    assign ep_if.cq_tready = ep_cq_if.tready;

    // EP-CC: axis MASTER
    assign ep_if.cc_tdata  = ep_cc_if.tdata;
    assign ep_if.cc_tkeep  = ep_cc_dw_keep;
    assign ep_if.cc_tlast  = ep_cc_if.tlast;
    assign ep_if.cc_tvalid = ep_cc_if.tvalid;
    assign ep_if.cc_tuser  = ep_cc_if.tuser;
    assign ep_cc_if.tready = ep_if.cc_tready;

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
        // RC 侧四通道
        uvm_config_db #(vif_rq_t)::set(
            null, "uvm_test_top.env.rc_agent.rq_agent*", "vif", rc_rq_if);
        uvm_config_db #(vif_rc_t)::set(
            null, "uvm_test_top.env.rc_agent.rc_agent*", "vif", rc_rc_if);
        uvm_config_db #(vif_cq_t)::set(
            null, "uvm_test_top.env.rc_agent.cq_agent*", "vif", rc_cq_if);
        uvm_config_db #(vif_cc_t)::set(
            null, "uvm_test_top.env.rc_agent.cc_agent*", "vif", rc_cc_if);

        // EP 侧四通道
        uvm_config_db #(vif_rq_t)::set(
            null, "uvm_test_top.env.ep_agent.rq_agent*", "vif", ep_rq_if);
        uvm_config_db #(vif_rc_t)::set(
            null, "uvm_test_top.env.ep_agent.rc_agent*", "vif", ep_rc_if);
        uvm_config_db #(vif_cq_t)::set(
            null, "uvm_test_top.env.ep_agent.cq_agent*", "vif", ep_cq_if);
        uvm_config_db #(vif_cc_t)::set(
            null, "uvm_test_top.env.ep_agent.cc_agent*", "vif", ep_cc_if);

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

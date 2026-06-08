//=============================================================================
// 文件名: tb_with_dut.sv
// 描述: 真实 DUT 连接模板 Testbench（参考文件，不参与回环仿真编译）
//
// 用途：当需要将 EP BFM 连接到真实 Xilinx PCIe IP（而非回环 DUT）时，
//       参考本文件的端口映射方式进行适配。
//
// AXI-Stream 通道与 PCIe IP 端口对应关系（PG213）：
//   m_axis_rq_*  EP -> PCIe IP 请求通道   对应 ep_if.rq_*
//   s_axis_rc_*  PCIe IP -> EP 完成通道   对应 ep_if.rc_*
//   s_axis_cq_*  PCIe IP -> EP 请求通道   对应 ep_if.cq_*
//   m_axis_cc_*  EP -> PCIe IP 完成通道   对应 ep_if.cc_*
//
// 使用说明：
//   1. 将本文件中被注释掉的真实 DUT 实例化段落取消注释
//   2. 将 xdma_0 替换为实际生成的 PCIe IP wrapper 模块名
//   3. 根据实际 IP 端口列表补充或删减端口映射
//   4. 将 tb_with_dut 替换 filelist.f 中的 tb_top 作为仿真顶层
//=============================================================================

`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
import uvm_pkg::*;
import axis_pkg::*;
import xilinx_pcie_pkg::*;

module tb_with_dut;

    //=========================================================================
    // 参数定义 — 由 +define+DATA_WIDTH=N 驱动 (与真实 IP 配置保持一致)
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
    // 时钟与复位
    //=========================================================================
    logic user_clk;    // PCIe IP 输出的用户时钟（user_clk，通常 250MHz）
    logic user_rst_n;  // PCIe IP 输出的用户复位（低有效）
    logic sys_clk_p;   // 系统差分参考时钟正端（100MHz，送入 PCIe IP GT）
    logic sys_clk_n;   // 系统差分参考时钟负端
    logic sys_rst_n;   // 系统板级复位（低有效，连接 PCIe IP sys_rst_n）

    // 模拟 100MHz 差分参考时钟
    initial sys_clk_p = 1'b0;
    always #5ns sys_clk_p = ~sys_clk_p;
    assign sys_clk_n = ~sys_clk_p;

    // 系统复位：上电后拉低 20ns 再释放
    initial begin
        sys_rst_n = 1'b0;
        #20ns;
        sys_rst_n = 1'b1;
    end

    // 用户时钟：仿真中由 tb 产生（实际由 PCIe IP 输出）
    initial user_clk = 1'b0;
    always #2ns user_clk = ~user_clk;   // 250MHz

    // 用户复位：等待 link_up 后撤销（仿真中延迟 20 周期）
    initial begin
        user_rst_n = 1'b0;
        repeat (20) @(posedge user_clk);
        user_rst_n = 1'b1;
    end

    //=========================================================================
    // EP BFM 接口实例化（连接到真实 PCIe IP）
    //=========================================================================

    // EP 侧 PCIe 四通道 AXI-Stream 接口
    xilinx_pcie_if #(
        .DATA_WIDTH     (DATA_WIDTH),
        .RQ_TUSER_WIDTH (RQ_TUSER_WIDTH),
        .RC_TUSER_WIDTH (RC_TUSER_WIDTH),
        .CQ_TUSER_WIDTH (CQ_TUSER_WIDTH),
        .CC_TUSER_WIDTH (CC_TUSER_WIDTH)
    ) ep_if (
        .clk   (user_clk),
        .rst_n (user_rst_n)
    );

    // EP 侧配置管理与中断边带接口
    xilinx_pcie_cfg_if ep_cfg_if (
        .clk   (user_clk),
        .rst_n (user_rst_n)
    );

    //=========================================================================
    // 真实 DUT 实例化（Xilinx PCIe IP，端口映射示例）
    //
    // 取消以下注释，并将 xdma_0 替换为实际 IP wrapper 模块名。
    // 端口名称参考 Xilinx UltraScale+ PCIe Gen3x8 XDMA IP (PG195/PG213)。
    //=========================================================================

    /*
    xdma_0 u_pcie_ip (
        //---------- GT 参考时钟（差分输入）----------
        .sys_clk_p                  (sys_clk_p),
        .sys_clk_n                  (sys_clk_n),
        // 系统复位（低有效）
        .sys_rst_n                  (sys_rst_n),

        //---------- GT 串行接口（物理层）----------
        // 仿真时通常连接 Xilinx GTYE4 BFM 或留空
        .pci_exp_rxp                (4'b0),
        .pci_exp_rxn                (4'b1111),
        .pci_exp_txp                (),
        .pci_exp_txn                (),

        //---------- 用户时钟与复位（IP 输出）----------
        .axi_aclk                   (user_clk),     // IP 输出 250MHz 用户时钟
        .axi_aresetn                (user_rst_n),   // IP 输出高有效复位（注意极性）

        //---------- m_axis_rq：EP -> PCIe IP 请求通道 ----------
        // EP BFM 驱动（MASTER），PCIe IP 接收（SLAVE）
        .m_axis_rq_tdata            (ep_if.rq_tdata),    // 请求数据 [255:0]
        .m_axis_rq_tkeep            (ep_if.rq_tkeep),    // 数据有效（per-DW）[7:0]
        .m_axis_rq_tlast            (ep_if.rq_tlast),    // 包末尾
        .m_axis_rq_tvalid           (ep_if.rq_tvalid),   // 数据有效
        .m_axis_rq_tready           (ep_if.rq_tready),   // IP 反压（IP->EP）
        .m_axis_rq_tuser            (ep_if.rq_tuser),    // 用户边带 [136:0]

        //---------- s_axis_rc：PCIe IP -> EP 完成通道 ----------
        // PCIe IP 驱动（MASTER），EP BFM 接收（SLAVE）
        .s_axis_rc_tdata            (ep_if.rc_tdata),    // 完成数据 [255:0]
        .s_axis_rc_tkeep            (ep_if.rc_tkeep),    // 数据有效（per-DW）[7:0]
        .s_axis_rc_tlast            (ep_if.rc_tlast),    // 包末尾
        .s_axis_rc_tvalid           (ep_if.rc_tvalid),   // 数据有效
        .s_axis_rc_tready           (ep_if.rc_tready),   // EP 反压（EP->IP）
        .s_axis_rc_tuser            (ep_if.rc_tuser),    // 用户边带 [160:0]

        //---------- s_axis_cq：PCIe IP -> EP 请求通道 ----------
        // PCIe IP 驱动（MASTER），EP BFM 接收（SLAVE）
        .s_axis_cq_tdata            (ep_if.cq_tdata),    // 请求数据 [255:0]
        .s_axis_cq_tkeep            (ep_if.cq_tkeep),    // 数据有效（per-DW）[7:0]
        .s_axis_cq_tlast            (ep_if.cq_tlast),    // 包末尾
        .s_axis_cq_tvalid           (ep_if.cq_tvalid),   // 数据有效
        .s_axis_cq_tready           (ep_if.cq_tready),   // EP 反压（EP->IP）
        .s_axis_cq_tuser            (ep_if.cq_tuser),    // 用户边带 [182:0]

        //---------- m_axis_cc：EP -> PCIe IP 完成通道 ----------
        // EP BFM 驱动（MASTER），PCIe IP 接收（SLAVE）
        .m_axis_cc_tdata            (ep_if.cc_tdata),    // 完成数据 [255:0]
        .m_axis_cc_tkeep            (ep_if.cc_tkeep),    // 数据有效（per-DW）[7:0]
        .m_axis_cc_tlast            (ep_if.cc_tlast),    // 包末尾
        .m_axis_cc_tvalid           (ep_if.cc_tvalid),   // 数据有效
        .m_axis_cc_tready           (ep_if.cc_tready),   // IP 反压（IP->EP）
        .m_axis_cc_tuser            (ep_if.cc_tuser),    // 用户边带 [80:0]

        //---------- cfg_mgmt 配置管理接口 ----------
        .cfg_mgmt_addr              (ep_cfg_if.cfg_mgmt_addr),
        .cfg_mgmt_byte_enable       (ep_cfg_if.cfg_mgmt_byte_enable),
        .cfg_mgmt_read              (ep_cfg_if.cfg_mgmt_read),
        .cfg_mgmt_write             (ep_cfg_if.cfg_mgmt_write),
        .cfg_mgmt_write_data        (ep_cfg_if.cfg_mgmt_write_data),
        .cfg_mgmt_read_data         (ep_cfg_if.cfg_mgmt_read_data),
        .cfg_mgmt_read_write_done   (ep_cfg_if.cfg_mgmt_read_write_done),
        .cfg_mgmt_debug_access      (ep_cfg_if.cfg_mgmt_debug_access),

        //---------- cfg_interrupt Legacy ----------
        .cfg_interrupt_int          (ep_cfg_if.cfg_interrupt_int),
        .cfg_interrupt_pending      (ep_cfg_if.cfg_interrupt_pending),
        .cfg_interrupt_sent         (ep_cfg_if.cfg_interrupt_sent),

        //---------- cfg_interrupt MSI ----------
        .cfg_interrupt_msi_enable   (ep_cfg_if.cfg_interrupt_msi_enable),
        .cfg_interrupt_msi_mmenable (ep_cfg_if.cfg_interrupt_msi_mmenable),
        .cfg_interrupt_msi_int      (ep_cfg_if.cfg_interrupt_msi_int),
        .cfg_interrupt_msi_sent     (ep_cfg_if.cfg_interrupt_msi_sent),
        .cfg_interrupt_msi_fail     (ep_cfg_if.cfg_interrupt_msi_fail),

        //---------- cfg_interrupt MSI-X ----------
        .cfg_interrupt_msix_enable  (ep_cfg_if.cfg_interrupt_msix_enable),
        .cfg_interrupt_msix_mask    (ep_cfg_if.cfg_interrupt_msix_mask),
        .cfg_interrupt_msix_int     (ep_cfg_if.cfg_interrupt_msix_int),
        .cfg_interrupt_msix_address (ep_cfg_if.cfg_interrupt_msix_address),
        .cfg_interrupt_msix_data    (ep_cfg_if.cfg_interrupt_msix_data)
    );
    */

    //=========================================================================
    // axis_if 实例化（EP 侧 4 条通道，供 UVM agent 使用）
    //=========================================================================

    // EP-RQ：EP BFM MASTER, EP-RC: SLAVE, EP-CQ: SLAVE, EP-CC: MASTER
    // 各通道按 PG213 真实宽度参数化
    axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) ep_rq_if (.aclk(user_clk), .aresetn(user_rst_n));
    axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) ep_rc_if (.aclk(user_clk), .aresetn(user_rst_n));
    axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) ep_cq_if (.aclk(user_clk), .aresetn(user_rst_n));
    axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) ep_cc_if (.aclk(user_clk), .aresetn(user_rst_n));

    // ---- tkeep 桥接辅助 (axis per-byte <-> pcie per-DW) ----
    localparam int AXIS_TKEEP_WIDTH = DATA_WIDTH / 8;

    function automatic logic [KEEP_WIDTH-1:0] byte_keep_to_dw_keep(
        input logic [AXIS_TKEEP_WIDTH-1:0] byte_keep
    );
        logic [KEEP_WIDTH-1:0] dw_keep;
        for (int dw = 0; dw < KEEP_WIDTH; dw++)
            dw_keep[dw] = |byte_keep[dw*4 +: 4];
        return dw_keep;
    endfunction

    function automatic logic [AXIS_TKEEP_WIDTH-1:0] dw_keep_to_byte_keep(
        input logic [KEEP_WIDTH-1:0] dw_keep
    );
        logic [AXIS_TKEEP_WIDTH-1:0] byte_keep;
        byte_keep = '0;
        for (int dw = 0; dw < KEEP_WIDTH; dw++)
            if (dw_keep[dw]) byte_keep[dw*4 +: 4] = 4'hF;
        return byte_keep;
    endfunction

    //=========================================================================
    // axis_if <-> ep_if 信号桥接（与 tb_top.sv EP 侧相同）
    //=========================================================================

    // EP-RQ: MASTER (ep_rq_if 驱动 ep_if.rq_*)
    assign ep_if.rq_tdata  = ep_rq_if.tdata;
    assign ep_if.rq_tkeep  = byte_keep_to_dw_keep(ep_rq_if.tkeep);
    assign ep_if.rq_tlast  = ep_rq_if.tlast;
    assign ep_if.rq_tvalid = ep_rq_if.tvalid;
    assign ep_if.rq_tuser  = ep_rq_if.tuser;
    assign ep_rq_if.tready = ep_if.rq_tready;

    // EP-RC: SLAVE (ep_if.rc_* 驱动 ep_rc_if)
    assign ep_rc_if.tdata  = ep_if.rc_tdata;
    assign ep_rc_if.tkeep  = dw_keep_to_byte_keep(ep_if.rc_tkeep);
    assign ep_rc_if.tlast  = ep_if.rc_tlast;
    assign ep_rc_if.tvalid = ep_if.rc_tvalid;
    assign ep_rc_if.tuser  = ep_if.rc_tuser;
    assign ep_if.rc_tready = ep_rc_if.tready;

    // EP-CQ: SLAVE (ep_if.cq_* 驱动 ep_cq_if)
    assign ep_cq_if.tdata  = ep_if.cq_tdata;
    assign ep_cq_if.tkeep  = dw_keep_to_byte_keep(ep_if.cq_tkeep);
    assign ep_cq_if.tlast  = ep_if.cq_tlast;
    assign ep_cq_if.tvalid = ep_if.cq_tvalid;
    assign ep_cq_if.tuser  = ep_if.cq_tuser;
    assign ep_if.cq_tready = ep_cq_if.tready;

    // EP-CC: MASTER (ep_cc_if 驱动 ep_if.cc_*)
    assign ep_if.cc_tdata  = ep_cc_if.tdata;
    assign ep_if.cc_tkeep  = byte_keep_to_dw_keep(ep_cc_if.tkeep);
    assign ep_if.cc_tlast  = ep_cc_if.tlast;
    assign ep_if.cc_tvalid = ep_cc_if.tvalid;
    assign ep_if.cc_tuser  = ep_cc_if.tuser;
    assign ep_cc_if.tready = ep_if.cc_tready;

    //=========================================================================
    // UVM config_db 注册 + run_test()
    //=========================================================================
    initial begin
        // 注册 EP 侧各通道 axis_if 虚拟接口
        uvm_config_db #(vif_rq_t)::set(
            null, "uvm_test_top.env.ep_agent.rq_agent*", "vif", ep_rq_if);
        uvm_config_db #(vif_rc_t)::set(
            null, "uvm_test_top.env.ep_agent.rc_agent*", "vif", ep_rc_if);
        uvm_config_db #(vif_cq_t)::set(
            null, "uvm_test_top.env.ep_agent.cq_agent*", "vif", ep_cq_if);
        uvm_config_db #(vif_cc_t)::set(
            null, "uvm_test_top.env.ep_agent.cc_agent*", "vif", ep_cc_if);

        // 注册 EP 侧 cfg_if 虚拟接口
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_cfg_agent*", "cfg_vif", ep_cfg_if);
        uvm_config_db #(virtual xilinx_pcie_cfg_if)::set(
            null, "uvm_test_top.env.ep_int_agent*", "cfg_vif", ep_cfg_if);

        // 启动 UVM 测试（+UVM_TESTNAME=<test_name>）
        run_test();
    end

    //=========================================================================
    // 仿真超时保护
    //=========================================================================
    initial begin
        #10ms;
        $display("[tb_with_dut] 错误：仿真超时（10ms），强制结束");
        $finish(2);
    end

endmodule : tb_with_dut

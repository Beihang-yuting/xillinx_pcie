//=============================================================================
// 文件名: xilinx_pcie_loopback_dut.sv
// 描述: Xilinx PCIe 回环 DUT
//
// 功能：将 RC BFM 和 EP BFM 的 4 条 AXI-Stream 通道交叉连线，
//       实现完整的 PCIe 回环仿真环境，无需真实硬件 IP。
//
// 通道连接关系（PCIe 数据流方向）：
//   RC 侧 CQ 输出 -> EP 侧 CQ 输入    （RC 驱动 CQ，EP 接收请求）
//   EP 侧 CQ tready -> RC 侧 CQ tready （EP 对 RC 的 CQ 反压）
//   EP 侧 CC 输出 -> RC 侧 CC 输入    （EP 驱动 CC，RC 接收完成）
//   RC 侧 CC tready -> EP 侧 CC tready （RC 对 EP 的 CC 反压）
//   EP 侧 RQ 输出 -> RC 侧 RQ 输入    （EP 驱动 RQ，RC 接收请求）
//   RC 侧 RQ tready -> EP 侧 RQ tready （RC 对 EP 的 RQ 反压）
//   RC 侧 RC 输出 -> EP 侧 RC 输入    （RC 驱动 RC，EP 接收完成）
//   EP 侧 RC tready -> RC 侧 RC tready （EP 对 RC 的 RC 反压）
//
// 注意：模块端口使用 xilinx_pcie_if（不带 modport），直接访问接口信号，
//       避免 modport / clocking block 对 assign 语句的限制。
//=============================================================================

module xilinx_pcie_loopback_dut #(
    // AXI-Stream 数据位宽（64/128/256/512 bit）
    parameter int DATA_WIDTH      = 256,
    // 各通道 tuser 位宽（参考 PG213，默认为 256bit 模式的宽度）
    parameter int RQ_TUSER_WIDTH  = 137,
    parameter int RC_TUSER_WIDTH  = 161,
    parameter int CQ_TUSER_WIDTH  = 183,
    parameter int CC_TUSER_WIDTH  = 81
)(
    // RC 侧接口（不带 modport，直接访问所有信号）
    xilinx_pcie_if rc_if,
    // EP 侧接口（不带 modport，直接访问所有信号）
    xilinx_pcie_if ep_if
);

    //=========================================================================
    // 通道 1：CQ 通道连线
    // 方向：RC 侧驱动 CQ 数据 -> EP 侧接收
    // 语义：RC 作为 PCIe IP，向 EP 转发外部主机发来的请求
    //=========================================================================

    // RC 驱动 CQ 有效数据 -> EP 接收
    assign ep_if.cq_tdata  = rc_if.cq_tdata;   // CQ 请求数据
    assign ep_if.cq_tkeep  = rc_if.cq_tkeep;   // CQ 数据有效（per-DW）
    assign ep_if.cq_tlast  = rc_if.cq_tlast;   // CQ 包末尾指示
    assign ep_if.cq_tvalid = rc_if.cq_tvalid;  // CQ 数据有效脉冲
    assign ep_if.cq_tuser  = rc_if.cq_tuser;   // CQ 用户边带信号

    // EP 驱动 CQ tready（反压方向相反）-> RC 接收
    assign rc_if.cq_tready = ep_if.cq_tready;  // EP 对 RC CQ 的反压

    //=========================================================================
    // 通道 2：CC 通道连线
    // 方向：EP 侧驱动 CC 数据 -> RC 侧接收
    // 语义：EP 作为端点，向外部主机（经由 RC）返回读/写完成
    //=========================================================================

    // EP 驱动 CC 有效数据 -> RC 接收
    assign rc_if.cc_tdata  = ep_if.cc_tdata;   // CC 完成数据
    assign rc_if.cc_tkeep  = ep_if.cc_tkeep;   // CC 数据有效（per-DW）
    assign rc_if.cc_tlast  = ep_if.cc_tlast;   // CC 包末尾指示
    assign rc_if.cc_tvalid = ep_if.cc_tvalid;  // CC 数据有效脉冲
    assign rc_if.cc_tuser  = ep_if.cc_tuser;   // CC 用户边带信号

    // RC 驱动 CC tready（反压方向相反）-> EP 接收
    assign ep_if.cc_tready = rc_if.cc_tready;  // RC 对 EP CC 的反压

    //=========================================================================
    // 通道 3：RQ 通道连线
    // 方向：EP 侧驱动 RQ 数据 -> RC 侧接收
    // 语义：EP 作为 DMA 发起方，向主机（RC）发送内存读写请求
    //=========================================================================

    // EP 驱动 RQ 有效数据 -> RC 接收
    assign rc_if.rq_tdata  = ep_if.rq_tdata;   // RQ 请求数据
    assign rc_if.rq_tkeep  = ep_if.rq_tkeep;   // RQ 数据有效（per-DW）
    assign rc_if.rq_tlast  = ep_if.rq_tlast;   // RQ 包末尾指示
    assign rc_if.rq_tvalid = ep_if.rq_tvalid;  // RQ 数据有效脉冲
    assign rc_if.rq_tuser  = ep_if.rq_tuser;   // RQ 用户边带信号

    // RC 驱动 RQ tready（反压方向相反）-> EP 接收
    assign ep_if.rq_tready = rc_if.rq_tready;  // RC 对 EP RQ 的反压

    //=========================================================================
    // 通道 4：RC 通道连线
    // 方向：RC 侧驱动 RC 数据 -> EP 侧接收
    // 语义：RC 作为 PCIe IP，向 EP 返回 DMA 读请求的完成数据
    //=========================================================================

    // RC 驱动 RC 有效数据 -> EP 接收
    assign ep_if.rc_tdata  = rc_if.rc_tdata;   // RC 完成数据
    assign ep_if.rc_tkeep  = rc_if.rc_tkeep;   // RC 数据有效（per-DW）
    assign ep_if.rc_tlast  = rc_if.rc_tlast;   // RC 包末尾指示
    assign ep_if.rc_tvalid = rc_if.rc_tvalid;  // RC 数据有效脉冲
    assign ep_if.rc_tuser  = rc_if.rc_tuser;   // RC 用户边带信号

    // EP 驱动 RC tready（反压方向相反）-> RC 接收
    assign rc_if.rc_tready = ep_if.rc_tready;  // EP 对 RC 完成通道的反压

endmodule : xilinx_pcie_loopback_dut

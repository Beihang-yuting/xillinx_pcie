//=============================================================================
// 文件名: xilinx_pcie_err_inject_test.sv
// 描述: 中央错误聚合验证测试（Error Injection Test）
//
// 功能：验证 agent 本地协议检查经 err_ap -> error tap -> collector.record_error
//       正确进入中央 collector 的 per-agent err_count，并在 report_phase 以
//       PROTO_ERR 打印。覆盖以下 TYPE，全部注入到 rc_agent_0，EP agent 保持干净：
//         MALFORMED      - 空 axis_packet（write_rq 解码路径）
//         RQ_PROTO       - 完成类 TLP 出现在 RQ（请求）通道
//         RC_PROTO       - 非完成类 TLP 出现在 RC（完成）通道
//         CQ_PROTO       - 完成类 TLP 出现在 CQ（请求）通道
//         CC_PROTO       - 非完成类 TLP 出现在 CC（完成）通道
//         DESC_FORMAT    - tag 超出配置 tag 空间
//         TUSER          - 写请求 first_be=0
//         PAYLOAD_ALIGN  - payload 字节数与 length*4 不符
//
//       方向类（*_PROTO）与 desc/tuser/payload 类检查在标准 write_* 解码路径中，
//       decode 会按通道强制 TLP 类别/字段，故无法经普通流量触发；本测试通过
//       monitor.inject_check_tlp() 定向钩子，用调用方构造的 TLP 运行真实
//       run_protocol_checks()，逐条触发各 TYPE 并验证经 tap 进入 collector。
//
// 验收：report_phase 应对 rc_agent_0（XILINX_PCIE_RC_0）打印每个 TYPE x1，
//       且 EP agent（XILINX_PCIE_EP_0）不出现任何 PROTO_ERR。
//       monitor 本地 uvm_error 仍会触发（每次注入 1 个 UVM_ERROR），属注入正常现象。
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_err_inject_test
//=============================================================================

// 本测试直接构造 pcie_tl_pkg 的 TLP 子类（cpl/mem）并引用其枚举（TLP_*/FMT_*/
// CPL_STATUS_*）。tb_top 仅 import xilinx_pcie_pkg，未 import pcie_tl_pkg，故这些
// 类型在 $unit 作用域不可见——此处显式 import 使其可见。
import pcie_tl_pkg::*;

class xilinx_pcie_err_inject_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_err_inject_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    // 构造一个“干净”的完成 TLP（length==payload/4, tag 合法）
    protected function pcie_tl_cpl_tlp make_clean_cpl();
        pcie_tl_cpl_tlp c;
        c = pcie_tl_cpl_tlp::type_id::create("inj_cpl");
        c.kind       = TLP_CPLD;
        c.fmt        = FMT_3DW_WITH_DATA;
        c.length     = 10'd1;
        c.tag        = 10'd0;
        c.cpl_status = CPL_STATUS_SC;
        c.payload    = new[4];
        return c;
    endfunction

    // 构造一个“干净”的写请求 TLP（length==payload/4, first_be 非零, tag 合法）
    protected function pcie_tl_mem_tlp make_clean_mwr();
        pcie_tl_mem_tlp m;
        m = pcie_tl_mem_tlp::type_id::create("inj_mwr");
        m.kind     = TLP_MEM_WR;
        m.fmt      = FMT_3DW_WITH_DATA;
        m.length   = 10'd1;
        m.tag      = 10'd0;
        m.first_be = 4'hF;
        m.last_be  = 4'h0;
        m.payload  = new[4];
        return m;
    endfunction

    //=========================================================================
    // run_phase：逐条注入各协议检查违规，全部命中 rc_agent_0
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        axis_packet     empty_pkt;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_mem_tlp mwr;
        xilinx_pcie_monitor mon;

        phase.raise_objection(this, "xilinx_pcie_err_inject_test");

        `uvm_info(get_type_name(), "===== Error Inject Test 开始 =====", UVM_LOW)

        if (env.rc_agents.size() == 0)
            `uvm_fatal(get_type_name(), "本测试需要至少 1 个 RC agent")

        mon = env.rc_agents[0].monitor;

        // ---- MALFORMED：空 axis_packet 经 write_rq 解码路径 ----
        empty_pkt = axis_packet::type_id::create("empty_pkt");
        mon.write_rq(empty_pkt);

        // ---- RQ_PROTO：完成类 TLP 出现在 RQ（请求）通道 ----
        cpl = make_clean_cpl();
        mon.inject_check_tlp(cpl, XILINX_CH_RQ);

        // ---- RC_PROTO：非完成类（写请求）TLP 出现在 RC（完成）通道 ----
        mwr = make_clean_mwr();
        mon.inject_check_tlp(mwr, XILINX_CH_RC);

        // ---- CC_PROTO：非完成类 TLP 出现在 CC（完成）通道 ----
        mwr = make_clean_mwr();
        mon.inject_check_tlp(mwr, XILINX_CH_CC);

        // ---- CQ_PROTO：完成类 TLP 出现在 CQ（请求）通道 ----
        cpl = make_clean_cpl();
        mon.inject_check_tlp(cpl, XILINX_CH_CQ);

        // ---- DESC_FORMAT：tag 超出配置 tag 空间（默认 max_outstanding=256）----
        cpl = make_clean_cpl();
        cpl.tag = 10'd300;            // >= 256，越界
        mon.inject_check_tlp(cpl, XILINX_CH_RC);  // RC 通道，方向合法，仅 DESC 触发

        // ---- TUSER：CQ 写请求 first_be=0 ----
        mwr = make_clean_mwr();
        mwr.first_be = 4'h0;          // 数据传输首 DW BE 全零，非法
        mon.inject_check_tlp(mwr, XILINX_CH_CQ);  // 请求通道，方向合法，仅 TUSER 触发

        // ---- PAYLOAD_ALIGN：length 与 payload 不符 ----
        mwr = make_clean_mwr();
        mwr.length = 10'd8;           // 期望 32B，实际 payload 仍 4B
        mon.inject_check_tlp(mwr, XILINX_CH_CQ);  // 请求通道，first_be 非零，仅 PAYLOAD 触发

        `uvm_info(get_type_name(), "===== 注入完成，等待 report_phase =====", UVM_LOW)

        #1us;

        phase.drop_objection(this, "xilinx_pcie_err_inject_test");
    endtask : run_phase

endclass : xilinx_pcie_err_inject_test

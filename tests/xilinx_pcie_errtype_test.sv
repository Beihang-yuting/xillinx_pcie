//=============================================================================
// 文件名: xilinx_pcie_errtype_test.sv
// 描述: 错误类型识别 + 隔离测试（Error-Type Identification Test）
//
// 目标（"正常识别并报出"）：证明中央 collector 对每一种错误类型都能
//   * 正确识别 TYPE 标签，
//   * 记在正确的 agent 上，
//   * 互不串扰（无跨 agent 污染、无误分类/多余 TYPE）。
//
// 与 err_inject_test 的区别：err_inject 仅"全部打一遍并在 report 里出现"；
// 本测试对 collector 的 per-(agent,type) 计数做精确断言（每类恰好 1 次，
// 未注入 agent 恰好 0 种类型，注入 agent 的类型集合恰好等于注入集合）。
//
// 拓扑：1 RC + 3 EP（tb_multi_agent / filelist_multi.f）。
//   全部错误注入到 rc_agent_0（XILINX_PCIE_RC_0）；EP_0/1/2 保持干净，作为
//   隔离见证。每种 check TYPE 用一个"只触发该一项不变式"的精心构造 TLP，
//   经 monitor.inject_check_tlp() 钩子运行真实 run_protocol_checks()。
//   POISONED 不经 check 钩子——它来自 record()（解码 TLP 的 ep_bit=1），
//   故用 rc_agent_0.tlp_rx_ap.write(<poisoned cpl>) 走 TLP tap 路径触发。
//
// 验收（PASS 判据 = check_phase 断言，非 UVM_ERROR==0）：
//   每注入 TYPE 在 RC_0 上 get_err_count==1，其余 TYPE==0；
//   RC_0 总类型数 == 注入类型数；EP_0/1/2 total_err_types==0。
//   通过则打印 "ERRTYPE TEST PASSED"，任一不符则 uvm_error("ERRTYPE_MISMATCH").
//
// 注：每个 check 注入同时触发 monitor 现场本地 uvm_error，故本测试 UVM_ERROR
//     非零属预期（注入违规数 + report_phase 的 PROTO_ERR 再发）。
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_errtype_test
//=============================================================================

// 直接构造 pcie_tl_pkg 的 TLP 子类（cpl/mem）并引用其枚举，需显式 import。
import pcie_tl_pkg::*;

class xilinx_pcie_errtype_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_errtype_test)

    // 注入目标 agent_key（role.name()_id）。全部错误命中此 agent。
    localparam string AK_INJ = "XILINX_PCIE_RC_0";

    // 期望在 RC_0 上出现的全部错误类型（注入集合）。check_phase 据此断言：
    //   * 每个均 ==1；
    //   * 不在此集合内的常见类型均 ==0；
    //   * RC_0 总类型数 == 本集合大小。
    string exp_types[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // 覆盖 _parse_plusargs：在 env 构建前设 num_rc=1 / num_ep=3，匹配
    // tb_multi_agent 接线（1 RC + 3 EP），提供多 agent 隔离见证。
    //=========================================================================
    protected virtual function void _parse_plusargs();
        super._parse_plusargs();
        cfg.num_rc = 1;
        cfg.num_ep = 3;
        `uvm_info(get_type_name(),
            $sformatf("errtype: num_rc=%0d num_ep=%0d", cfg.num_rc, cfg.num_ep),
            UVM_LOW)
    endfunction : _parse_plusargs

    //-------------------------------------------------------------------------
    // 构造"干净"完成 TLP（length==payload/4, tag 合法, 不带毒）
    //-------------------------------------------------------------------------
    protected function pcie_tl_cpl_tlp make_clean_cpl();
        pcie_tl_cpl_tlp c;
        c = pcie_tl_cpl_tlp::type_id::create("inj_cpl");
        c.kind       = TLP_CPLD;
        c.fmt        = FMT_3DW_WITH_DATA;
        c.length     = 10'd1;
        c.tag        = 10'd0;
        c.cpl_status = CPL_STATUS_SC;
        c.ep_bit     = 1'b0;
        c.payload    = new[4];
        return c;
    endfunction

    //-------------------------------------------------------------------------
    // 构造"干净"写请求 TLP（length==payload/4, first_be 非零, tag 合法）
    //-------------------------------------------------------------------------
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
    // run_phase：逐类注入到 rc_agent_0，每类恰好 1 次；EP 保持干净。
    // 每个构造 TLP 仅触发其目标不变式（其余检查对该 TLP 恒成立）。
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        axis_packet         empty_pkt;
        pcie_tl_cpl_tlp     cpl;
        pcie_tl_mem_tlp     mwr;
        xilinx_pcie_agent   rc_a;
        xilinx_pcie_monitor mon;

        phase.raise_objection(this, "xilinx_pcie_errtype_test");

        `uvm_info(get_type_name(), "===== ErrType Test 开始 =====", UVM_LOW)

        if (env.rc_agents.size() == 0)
            `uvm_fatal(get_type_name(), "本测试需要至少 1 个 RC agent")

        rc_a = env.rc_agents[0];
        mon  = rc_a.monitor;

        // 记录预期注入类型集合（与下方注入一一对应）。
        exp_types = '{ "MALFORMED", "RQ_PROTO", "RC_PROTO", "CC_PROTO",
                       "CQ_PROTO", "DESC_FORMAT", "TUSER", "PAYLOAD_ALIGN",
                       "POISONED" };

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

        // ---- DESC_FORMAT：tag 超出配置 tag 空间（tag_space=256）；
        //      RC 通道方向合法，仅 DESC 触发 ----
        cpl = make_clean_cpl();
        cpl.tag = 10'd300;
        mon.inject_check_tlp(cpl, XILINX_CH_RC);

        // ---- TUSER：CQ 写请求 first_be=0；请求通道方向合法，length/payload
        //      一致，仅 TUSER 触发 ----
        mwr = make_clean_mwr();
        mwr.first_be = 4'h0;
        mon.inject_check_tlp(mwr, XILINX_CH_CQ);

        // ---- PAYLOAD_ALIGN：length 与 payload 不符；first_be 非零，仅 PAYLOAD 触发 ----
        mwr = make_clean_mwr();
        mwr.length = 10'd8;     // 期望 32B，实际 payload 4B
        mon.inject_check_tlp(mwr, XILINX_CH_CQ);

        // ---- POISONED：经 TLP tap 路径（record()），非 check 钩子 ----
        //      构造带毒完成 TLP，直接写入 agent 的 tlp_rx_ap，使其经 collector
        //      tap 进入 record()，因 ep_bit=1 增计 err_count[RC_0]["POISONED"]。
        cpl = make_clean_cpl();
        cpl.ep_bit = 1'b1;
        rc_a.tlp_rx_ap.write(cpl);

        `uvm_info(get_type_name(), "===== 注入完成，等待排空 =====", UVM_LOW)

        #2us;

        phase.drop_objection(this, "xilinx_pcie_errtype_test");
    endtask : run_phase

    //=========================================================================
    // check_phase：对 collector 做精确断言。
    //   1) 注入集合每类 == 1；
    //   2) RC_0 总类型数 == 注入类型数（无多余/误分类类型）；
    //   3) 抽样未注入类型 == 0（无误分类）；
    //   4) EP_0/1/2 total_err_types == 0（隔离）。
    // 任一失败 -> uvm_error("ERRTYPE_MISMATCH") + 打印 FAILED；全过 -> PASSED。
    //=========================================================================
    virtual function void check_phase(uvm_phase phase);
        bit pass = 1'b1;
        int unsigned cnt;
        int unsigned ntypes;
        // 所有可能的 check/poisoned 类型全集（用于"未注入类型 == 0"扫描）
        string all_types[$] = '{ "MALFORMED", "RQ_PROTO", "RC_PROTO", "CQ_PROTO",
                                 "CC_PROTO", "DESC_FORMAT", "TUSER",
                                 "PAYLOAD_ALIGN", "POISONED" };
        string clean_aks[$]  = '{ "XILINX_PCIE_EP_0", "XILINX_PCIE_EP_1",
                                  "XILINX_PCIE_EP_2" };

        super.check_phase(phase);

        `uvm_info(get_type_name(),
            "===== ErrType check_phase：逐类型识别断言 =====", UVM_LOW)

        // (1) 注入集合每类恰好 1
        foreach (exp_types[i]) begin
            cnt = env.scb.get_err_count(AK_INJ, exp_types[i]);
            if (cnt == 1) begin
                `uvm_info(get_type_name(),
                    $sformatf("OK  [%s] %-13s = %0d (期望 1)",
                              AK_INJ, exp_types[i], cnt), UVM_LOW)
            end else begin
                pass = 1'b0;
                `uvm_error("ERRTYPE_MISMATCH",
                    $sformatf("[%s] %s = %0d，期望 1（漏报/重复/误分类）",
                              AK_INJ, exp_types[i], cnt))
            end
        end

        // (2) RC_0 类型总数 == 注入类型数（无多余类型）
        ntypes = env.scb.total_err_types(AK_INJ);
        if (ntypes == exp_types.size()) begin
            `uvm_info(get_type_name(),
                $sformatf("OK  [%s] total_err_types = %0d (期望 %0d)",
                          AK_INJ, ntypes, exp_types.size()), UVM_LOW)
        end else begin
            pass = 1'b0;
            `uvm_error("ERRTYPE_MISMATCH",
                $sformatf("[%s] total_err_types = %0d，期望 %0d（出现多余/误分类类型）",
                          AK_INJ, ntypes, exp_types.size()))
        end

        // (3) 全集中不属注入集合的类型必须为 0（无误分类到别的 TYPE）
        foreach (all_types[i]) begin
            bit is_expected = 1'b0;
            foreach (exp_types[j])
                if (exp_types[j] == all_types[i]) is_expected = 1'b1;
            if (!is_expected) begin
                cnt = env.scb.get_err_count(AK_INJ, all_types[i]);
                if (cnt != 0) begin
                    pass = 1'b0;
                    `uvm_error("ERRTYPE_MISMATCH",
                        $sformatf("[%s] 非注入类型 %s = %0d，期望 0（误分类）",
                                  AK_INJ, all_types[i], cnt))
                end
            end
        end

        // (4) 隔离：未注入 agent 不得有任何错误类型
        foreach (clean_aks[i]) begin
            ntypes = env.scb.total_err_types(clean_aks[i]);
            if (ntypes == 0) begin
                `uvm_info(get_type_name(),
                    $sformatf("OK  [%s] total_err_types = 0（隔离）",
                              clean_aks[i]), UVM_LOW)
            end else begin
                pass = 1'b0;
                `uvm_error("ERRTYPE_MISMATCH",
                    $sformatf("[%s] total_err_types = %0d，期望 0（跨 agent 污染）",
                              clean_aks[i], ntypes))
            end
        end

        if (pass)
            `uvm_info(get_type_name(),
                "ERRTYPE TEST PASSED — 各错误类型均被正确识别、归属正确、互不串扰",
                UVM_LOW)
        else
            `uvm_error("ERRTYPE_MISMATCH",
                "ERRTYPE TEST FAILED — 见上方 ERRTYPE_MISMATCH 明细")
    endfunction : check_phase

endclass : xilinx_pcie_errtype_test


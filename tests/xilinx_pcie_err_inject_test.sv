//=============================================================================
// 文件名: xilinx_pcie_err_inject_test.sv
// 描述: 中央错误聚合验证测试（Error Injection Test）
//
// 功能：验证 agent 本地协议检查（monitor 的 malformed 检查）经
//       err_ap -> error tap -> collector.record_error 正确进入中央 collector
//       的 per-agent err_count，并在 report_phase 以 PROTO_ERR 打印。
//
// 注入方式：向 rc_agent_0 的 monitor.write_rq 喂入一个空 axis_packet
//           （beats.size()==0，属 malformed）。正常流量不会产生空包，
//           故仅此一处定向注入触发。
//
// 验收：report_phase 应打印
//         PROTO_ERR [XILINX_PCIE_RC_0] MALFORMED x1
//       且 EP agent（XILINX_PCIE_EP_0）不出现任何 PROTO_ERR。
//       本测试的 monitor 本地 uvm_error 仍会触发（预期 1 个 UVM_ERROR），
//       属注入测试正常现象。
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_err_inject_test
//=============================================================================

class xilinx_pcie_err_inject_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_err_inject_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：向 rc_agent_0 的 monitor 注入一个空 axis_packet 触发 malformed
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        axis_packet empty_pkt;

        phase.raise_objection(this, "xilinx_pcie_err_inject_test");

        `uvm_info(get_type_name(), "===== Error Inject Test 开始 =====", UVM_LOW)

        if (env.rc_agents.size() == 0)
            `uvm_fatal(get_type_name(), "本测试需要至少 1 个 RC agent")

        // 构造空 axis_packet（无 beat）并喂入 rc_agent_0 的 RQ 回调，
        // 触发 monitor 的 malformed 本地检查（uvm_error + publish_error）。
        empty_pkt = axis_packet::type_id::create("empty_pkt");
        env.rc_agents[0].monitor.write_rq(empty_pkt);

        `uvm_info(get_type_name(), "===== 注入完成，等待 report_phase =====", UVM_LOW)

        #1us;

        phase.drop_objection(this, "xilinx_pcie_err_inject_test");
    endtask : run_phase

endclass : xilinx_pcie_err_inject_test

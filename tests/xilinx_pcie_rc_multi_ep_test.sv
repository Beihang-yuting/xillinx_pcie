//=============================================================================
// 文件名: xilinx_pcie_rc_multi_ep_test.sv
// 描述: Xilinx PCIe BFM 1 RC + 多 EP 回归测试 (1 RC + 4 EP)
//
// 验证目标：可配置 agent 数量特性在 num_rc=1 / num_ep=4 下正常工作，
//   RC 与全部 EP agent 均被驱动并被 collector 观测。
//   - 覆盖 _parse_plusargs 设置 num_rc=1 / num_ep=4，在 env 构建前生效
//   - run_phase 每个 EP 各发若干 posted MWr，并在 RC sequencer 上发若干笔
//   - check_phase 断言 collector 观测到 RC_0 + EP_0..3，且无 PROTO_ERR / UVM_ERROR
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_rc_multi_ep_test
//=============================================================================

class xilinx_pcie_rc_multi_ep_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_rc_multi_ep_test)

    localparam int NUM_RC      = 1;
    localparam int NUM_EP      = 4;
    localparam int MWR_PER_EP  = 3;
    localparam int MWR_ON_RC   = 2;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // 覆盖 _parse_plusargs：在 validate()+env build 之前设置 1 RC + 多 EP 配置
    //=========================================================================
    protected virtual function void _parse_plusargs();
        super._parse_plusargs();
        cfg.num_rc = NUM_RC;
        cfg.num_ep = NUM_EP;
        `uvm_info(get_type_name(),
            $sformatf("rc-multi-EP: num_rc=%0d num_ep=%0d", cfg.num_rc, cfg.num_ep),
            UVM_LOW)
    endfunction : _parse_plusargs

    //=========================================================================
    // 辅助：在给定 sequencer 上发 cnt 笔 posted MWr
    //=========================================================================
    protected task drive_mwr(uvm_sequencer_base sqr, string tag, int cnt);
        for (int n = 0; n < cnt; n++) begin
            xilinx_pcie_mem_seq s;
            s = xilinx_pcie_mem_seq::type_id::create($sformatf("%s_mwr%0d", tag, n));
            s.cfg = cfg;
            if (!s.randomize() with {
                    is_write == 1'b1;
                    length inside {[1:64]};
                    addr[63:32] == 32'h0;
                })
                `uvm_error(get_type_name(),
                    $sformatf("%s MWr%0d randomize 失败", tag, n))
            s.start(sqr);
        end
    endtask : drive_mwr

    //=========================================================================
    // run_phase：每个 EP 发 MWR_PER_EP 笔；RC sequencer 发 MWR_ON_RC 笔
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "xilinx_pcie_rc_multi_ep_test");

        `uvm_info(get_type_name(),
            $sformatf("===== RC+Multi-EP Test 开始 (RC 数=%0d EP 数=%0d) =====",
                      env.v_sqr.rc_sqr_arr.size(), env.v_sqr.ep_sqr_arr.size()), UVM_LOW)

        // RC 侧发若干 posted MWr（rc_sqr 即 rc_sqr_arr[0] 的别名）
        if (env.v_sqr.rc_sqr != null)
            drive_mwr(env.v_sqr.rc_sqr, "rc0", MWR_ON_RC);
        else
            `uvm_error(get_type_name(), "run_phase: v_sqr.rc_sqr 为 null（期望 num_rc=1）")

        // 每个 EP 侧发若干 posted MWr
        foreach (env.v_sqr.ep_sqr_arr[i])
            drive_mwr(env.v_sqr.ep_sqr_arr[i], $sformatf("ep%0d", i), MWR_PER_EP);

        #40us;

        `uvm_info(get_type_name(), "===== RC+Multi-EP Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_rc_multi_ep_test");
    endtask : run_phase

    //=========================================================================
    // check_phase：断言 collector 观测到 RC_0 + EP_0..3，且无 PROTO_ERR / UVM_ERROR
    //=========================================================================
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);

        if (env == null || env.scb == null) begin
            `uvm_error(get_type_name(), "check_phase: env/scb 为 null，无法断言 agent 覆盖")
            return;
        end

        if (!env.scb.has_agent_key("XILINX_PCIE_RC_0"))
            `uvm_error(get_type_name(),
                "check_phase: collector 未观测到 RC agent XILINX_PCIE_RC_0（覆盖缺失）")

        for (int i = 0; i < NUM_EP; i++) begin
            string ak = $sformatf("XILINX_PCIE_EP_%0d", i);
            if (!env.scb.has_agent_key(ak))
                `uvm_error(get_type_name(),
                    $sformatf("check_phase: collector 未观测到 EP agent %s（覆盖缺失）", ak))
        end

        if (env.scb.num_agent_keys() != (NUM_RC + NUM_EP))
            `uvm_error(get_type_name(),
                $sformatf("check_phase: 期望 collector 观测 %0d 个 agent，实际 %0d",
                          NUM_RC + NUM_EP, env.scb.num_agent_keys()))
    endfunction : check_phase

endclass : xilinx_pcie_rc_multi_ep_test

//=============================================================================
// 文件名: xilinx_pcie_multi_ep_test.sv
// 描述: Xilinx PCIe BFM 纯多 EP 回归测试 (0 RC + 4 EP)
//
// 验证目标：可配置 agent 数量特性在 num_rc=0 / num_ep=4 下正常工作，
//   且 num_rc=0 路径不崩溃（回归守护 all-EP 空指针防护）。
//   - 覆盖 _parse_plusargs 设置 num_rc=0 / num_ep=4，在 env 构建前生效
//   - run_phase 每个 EP 各发若干 posted MWr（is_write=1，无 MRd），
//     避免 completion 超时
//   - check_phase 断言 collector 观测到全部 4 个 EP（has_agent_key），
//     且无 PROTO_ERR / UVM_ERROR
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_multi_ep_test
//=============================================================================

class xilinx_pcie_multi_ep_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_multi_ep_test)

    localparam int NUM_EP      = 4;
    localparam int MWR_PER_EP  = 3;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // 覆盖 _parse_plusargs：在 validate()+env build 之前设置纯多 EP 配置
    //=========================================================================
    protected virtual function void _parse_plusargs();
        super._parse_plusargs();
        cfg.num_rc = 0;
        cfg.num_ep = NUM_EP;
        `uvm_info(get_type_name(),
            $sformatf("multi-EP: num_rc=%0d num_ep=%0d", cfg.num_rc, cfg.num_ep),
            UVM_LOW)
    endfunction : _parse_plusargs

    //=========================================================================
    // run_phase：每个 EP sequencer 各发 MWR_PER_EP 笔 posted MWr
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "xilinx_pcie_multi_ep_test");

        `uvm_info(get_type_name(),
            $sformatf("===== Multi-EP Test 开始 (EP 数=%0d) =====",
                      env.v_sqr.ep_sqr_arr.size()), UVM_LOW)

        foreach (env.v_sqr.ep_sqr_arr[i]) begin
            for (int n = 0; n < MWR_PER_EP; n++) begin
                xilinx_pcie_mem_seq s;
                s = xilinx_pcie_mem_seq::type_id::create(
                        $sformatf("ep%0d_mwr%0d", i, n));
                // 在普通 sequencer（非 v_sqr）上启动，手动注入 cfg，
                // 使 c_mps_limit/c_wr_data_size 约束可用。
                s.cfg = cfg;
                if (!s.randomize() with {
                        is_write == 1'b1;
                        length inside {[1:64]};
                        addr[63:32] == 32'h0;
                    })
                    `uvm_error(get_type_name(),
                        $sformatf("EP%0d MWr%0d randomize 失败", i, n))
                s.start(env.v_sqr.ep_sqr_arr[i]);
            end
        end

        #30us;

        `uvm_info(get_type_name(), "===== Multi-EP Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_multi_ep_test");
    endtask : run_phase

    //=========================================================================
    // check_phase：断言 collector 观测到全部 4 个 EP（无 RC），
    //   且无 PROTO_ERR / UVM_ERROR（PROTO_ERR 经 report_phase 转 uvm_error，
    //   故 UVM_ERROR=0 已覆盖之；此处额外正向断言 agent 覆盖）。
    //=========================================================================
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);

        if (env == null || env.scb == null) begin
            `uvm_error(get_type_name(), "check_phase: env/scb 为 null，无法断言 agent 覆盖")
            return;
        end

        for (int i = 0; i < NUM_EP; i++) begin
            string ak = $sformatf("XILINX_PCIE_EP_%0d", i);
            if (!env.scb.has_agent_key(ak))
                `uvm_error(get_type_name(),
                    $sformatf("check_phase: collector 未观测到 EP agent %s（覆盖缺失）", ak))
        end

        if (env.scb.num_agent_keys() != NUM_EP)
            `uvm_error(get_type_name(),
                $sformatf("check_phase: 期望 collector 观测 %0d 个 agent，实际 %0d",
                          NUM_EP, env.scb.num_agent_keys()))
    endfunction : check_phase

endclass : xilinx_pcie_multi_ep_test

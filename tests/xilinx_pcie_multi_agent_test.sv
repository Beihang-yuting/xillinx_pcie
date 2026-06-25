//=============================================================================
// 文件名: xilinx_pcie_multi_agent_test.sv
// 描述: Xilinx PCIe BFM 多 agent 演示测试 (1 RC + 3 EP)
//
// 验证目标：可配置 agent 数量特性（cfg.num_rc / cfg.num_ep）。
//   - 在 base_test 构建 env 之前，把 num_rc=1 / num_ep=3 写入 cfg
//     （通过覆盖 protected 钩子 _parse_plusargs，确保在 validate()+env build 前生效）
//   - run_phase 中每个 EP 各发若干 posted Memory Write（is_write=1，无 MRd），
//     避免 completion 超时（演示 EP 无应答对端）
//   - 各 EP 自身 monitor 解码线上 MWr，collector 在 report_phase 打印
//     [XILINX_PCIE_EP_0/1/2] TLP_MEM_WR = N，作为 3 个 EP 均被驱动的客观证据
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_multi_agent_test
//=============================================================================

class xilinx_pcie_multi_agent_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_multi_agent_test)

    // 每个 EP 发送的 posted MWr 笔数
    localparam int MWR_PER_EP = 4;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // 覆盖 _parse_plusargs：base_test 在 build_phase 中按
    //   create(cfg) -> _parse_plusargs() -> validate() -> create(env)
    // 顺序执行，故在此设置 num_rc/num_ep 可在 env 构建前生效。
    //=========================================================================
    protected virtual function void _parse_plusargs();
        super._parse_plusargs();
        cfg.num_rc = 1;
        cfg.num_ep = 3;
        `uvm_info(get_type_name(),
            $sformatf("multi-agent: num_rc=%0d num_ep=%0d", cfg.num_rc, cfg.num_ep),
            UVM_LOW)
    endfunction : _parse_plusargs

    //=========================================================================
    // run_phase：每个 EP sequencer 各发 MWR_PER_EP 笔 posted MWr
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "xilinx_pcie_multi_agent_test");

        `uvm_info(get_type_name(),
            $sformatf("===== Multi-Agent Test 开始 (EP 数=%0d) =====",
                      env.v_sqr.ep_sqr_arr.size()), UVM_LOW)

        foreach (env.v_sqr.ep_sqr_arr[i]) begin
            for (int n = 0; n < MWR_PER_EP; n++) begin
                xilinx_pcie_mem_seq s;
                s = xilinx_pcie_mem_seq::type_id::create(
                        $sformatf("ep%0d_mwr%0d", i, n));
                // 在普通 sequencer（非 v_sqr）上启动，pre_body 无法自动取 cfg，
                // 故手动注入，使 c_mps_limit/c_wr_data_size 约束可用。
                s.cfg = cfg;
                // posted MWr：is_write=1（禁随机），length 受约束随机
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

        `uvm_info(get_type_name(),
            "===== Multi-Agent Test 序列完成，等待线上 TLP 解码 =====", UVM_LOW)

        #50us;

        `uvm_info(get_type_name(), "===== Multi-Agent Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_multi_agent_test");
    endtask : run_phase

endclass : xilinx_pcie_multi_agent_test

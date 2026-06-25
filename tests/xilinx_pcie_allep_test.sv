//=============================================================================
// 文件名: xilinx_pcie_allep_test.sv
// 描述: Xilinx PCIe BFM all-EP 冒烟测试 (0 RC + 2 EP)
//
// 验证目标：num_rc=0 配置（原始需求 "multiple agents, all EP"）可正常
//   build + connect + run，不触发空指针 fatal（H1/H2 防护）。
//   - 覆盖 _parse_plusargs 设置 num_rc=0 / num_ep=2，在 env 构建前生效
//   - run_phase 每个 EP 各发若干 posted MWr，避免 completion 超时
//   - collector 在 report_phase 打印 [XILINX_PCIE_EP_0/1] TLP_MEM_WR = N
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_allep_test
//=============================================================================

class xilinx_pcie_allep_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_allep_test)

    localparam int MWR_PER_EP = 2;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // 覆盖 _parse_plusargs：在 validate()+env build 之前设置 all-EP 配置
    //=========================================================================
    protected virtual function void _parse_plusargs();
        super._parse_plusargs();
        cfg.num_rc = 0;
        cfg.num_ep = 2;
        `uvm_info(get_type_name(),
            $sformatf("all-EP: num_rc=%0d num_ep=%0d", cfg.num_rc, cfg.num_ep),
            UVM_LOW)
    endfunction : _parse_plusargs

    //=========================================================================
    // run_phase：每个 EP sequencer 各发 MWR_PER_EP 笔 posted MWr
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "xilinx_pcie_allep_test");

        `uvm_info(get_type_name(),
            $sformatf("===== All-EP Test 开始 (EP 数=%0d) =====",
                      env.v_sqr.ep_sqr_arr.size()), UVM_LOW)

        foreach (env.v_sqr.ep_sqr_arr[i]) begin
            for (int n = 0; n < MWR_PER_EP; n++) begin
                xilinx_pcie_mem_seq s;
                s = xilinx_pcie_mem_seq::type_id::create(
                        $sformatf("ep%0d_mwr%0d", i, n));
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

        #20us;

        `uvm_info(get_type_name(), "===== All-EP Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_allep_test");
    endtask : run_phase

endclass : xilinx_pcie_allep_test

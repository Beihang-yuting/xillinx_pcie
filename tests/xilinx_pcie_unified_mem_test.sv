//=============================================================================
// 文件名: xilinx_pcie_unified_mem_test.sv
// 描述: Xilinx PCIe BFM 统一内存模式端到端验证测试
//
// 功能：
//   开启 use_unified_mem=1，通过 xilinx_pcie_unified_mem_vseq 执行：
//     Phase A：RC↔EP dev_mem 双向 MWr/MRd roundtrip + 直接内存比较
//     Phase B：EP↔RC host_mem 双向 MWr/MRd roundtrip + 直接内存比较
//     Phase C：host_mem / dev_mem 泄漏检查
//   Scoreboard 独立检查 Completion 匹配 + 数据完整性。
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_unified_mem_test
//   建议附加：+DATA_WIDTH=256 +MPS=256 +MRRS=512
//=============================================================================

class xilinx_pcie_unified_mem_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_unified_mem_test)

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：父类完成 plusarg/cfg 后覆盖统一内存专项参数
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        cfg.use_unified_mem      = 1'b1;
        cfg.mem_access_mode      = XILINX_MEM_PER_BUFFER;
        cfg.mem_alloc_mode       = MODE_LINEAR;  // 避免 buddy addr_to_level(4GB) 32-bit 截断 bug
        cfg.scb_enable           = 1'b1;
        cfg.scb_completion_check = 1'b1;
        cfg.scb_data_integrity   = 1'b1;
        cfg.scb_descriptor_check = 1'b0;  // 编解码往返不是本测试重点
        cfg.interrupt_enable     = 1'b0;

        `uvm_info(get_type_name(),
            "build_phase 覆盖完成：use_unified_mem=1 PER_BUFFER scb=1 int=0",
            UVM_LOW)
    endfunction : build_phase

    //=========================================================================
    // run_phase：启动统一内存验证虚拟序列并等待在途 Completion 排空
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        xilinx_pcie_unified_mem_vseq vseq;

        phase.raise_objection(this, "xilinx_pcie_unified_mem_test");

        `uvm_info(get_type_name(), "===== unified_mem_test run_phase 开始 =====", UVM_LOW)

        vseq = xilinx_pcie_unified_mem_vseq::type_id::create("vseq");
        vseq.start(env.v_sqr);

        `uvm_info(get_type_name(),
            "===== 序列完成，等待在途 Completion 排空 =====", UVM_LOW)

        // drain：等待 scoreboard 在途请求清零，上限 200us
        begin
            int unsigned drain_us = 0;
            while (env.scb != null && env.scb.outstanding_reqs.size() > 0 &&
                   drain_us < 200) begin
                #1us;
                drain_us++;
            end
            if (env.scb != null && env.scb.outstanding_reqs.size() > 0)
                `uvm_warning(get_type_name(),
                    $sformatf("drain 超时：仍有 %0d 笔在途请求",
                              env.scb.outstanding_reqs.size()))
        end

        // 额外等待确保最后的 completion 已被 scoreboard 处理
        #50us;

        `uvm_info(get_type_name(), "===== unified_mem_test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_unified_mem_test");
    endtask : run_phase

endclass : xilinx_pcie_unified_mem_test

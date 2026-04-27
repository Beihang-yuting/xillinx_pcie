//=============================================================================
// 文件名: xilinx_pcie_sanity_test.sv
// 描述: Xilinx PCIe BFM 冒烟测试（Sanity Test）
//
// 功能：继承 xilinx_pcie_base_test，在 run_phase 中以默认参数启动
//       xilinx_pcie_loopback_vseq 回环虚拟序列。
//
// 测试目标：快速验证 RC/EP 双侧 BFM 基本功能可通，覆盖：
//   - 阶段 1：Config 枚举（CfgRd0 读取配置寄存器）
//   - 阶段 2：Memory Write + Read（MWr/MRd + CplD）
//   - 阶段 3：DMA Write + Read（EP 发起 DMA 请求）
//   - 阶段 4：MSI 中断发送
//   num_transactions = 20（适合快速冒烟，不覆盖所有边界条件）
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_sanity_test
//=============================================================================

class xilinx_pcie_sanity_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_sanity_test)

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：启动回环虚拟序列（20 笔事务）
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        xilinx_pcie_loopback_vseq vseq;

        // 提升 objection，防止 phase 在序列完成前提前退出
        phase.raise_objection(this, "xilinx_pcie_sanity_test");

        `uvm_info(get_type_name(), "===== Sanity Test 开始 =====", UVM_LOW)

        // 创建回环虚拟序列实例
        vseq = xilinx_pcie_loopback_vseq::type_id::create("vseq");

        // 冒烟测试：20 笔事务，max_payload_bytes=64（短包加速仿真）
        vseq.num_transactions = 20;
        vseq.max_payload_bytes = 64;

        // 在 env.v_sqr（xilinx_pcie_virtual_sequencer）上启动序列
        vseq.start(env.v_sqr);

        `uvm_info(get_type_name(), "===== Sanity Test 序列完成，等待 EP 完成回复 =====", UVM_LOW)

        // 等待 EP 的 CplD 响应全部传输完毕（drain time）
        // 20 对 MWr+MRd，每对 500ns 间隔 + EP 响应延迟，需较长 drain
        #50us;

        `uvm_info(get_type_name(), "===== Sanity Test 完成 =====", UVM_LOW)

        // 降低 objection，允许仿真正常结束
        phase.drop_objection(this, "xilinx_pcie_sanity_test");
    endtask : run_phase

endclass : xilinx_pcie_sanity_test

//=============================================================================
// 文件名: xilinx_pcie_straddle_test.sv
// 描述: Xilinx PCIe BFM Straddle 模式专项测试
//
// 功能：继承 xilinx_pcie_base_test，在 build_phase 中使能 Straddle 模式
//       相关配置，然后在 run_phase 中以小 payload（16 字节）运行大量事务，
//       充分激励 TLP 跨 beat 边界对齐的 Straddle 逻辑。
//
// 测试目标：
//   - 验证 straddle_enable=1 时的 TLP 打包/拆包正确性
//   - 触发 Straddle covergroup（cov_straddle=1）全覆盖
//   - tx_valid_mode=VALID_ZERO_IDLE：连续 valid，无主动空闲
//   - rx_ready_mode=READY_ALWAYS：接收侧无反压，隔离 Straddle 时序
//   - max_payload_bytes=16：一个 beat 可容纳多个 TLP，最大化 Straddle 触发率
//   num_transactions = 200
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_straddle_test
//   建议附加：+DATA_WIDTH=256 +STRADDLE_EN=1
//=============================================================================

class xilinx_pcie_straddle_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_straddle_test)

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：调用父类配置后，覆盖 Straddle 专项参数
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        // 先调用父类：完成 plusarg 解析、cfg 创建、env 实例化
        super.build_phase(phase);

        // ------------------------------------------------------------------
        // 覆盖 Straddle 专项配置
        // 父类 build_phase 已完成 cfg 对象创建，此处直接修改字段
        // ------------------------------------------------------------------

        // 使能 Straddle 模式（TLP 可跨 beat 边界对齐放置）
        cfg.straddle_enable  = 1'b1;

        // 使能覆盖率采集，并开启 Straddle 专项 covergroup
        cfg.cov_enable       = 1'b1;
        cfg.cov_straddle     = 1'b1;

        // TX valid 模式：VALID_ZERO_IDLE（连续 valid，背靠背传输）
        // 使相邻 TLP 紧密排列，最大化跨 beat 对齐触发概率
        cfg.tx_valid_mode    = VALID_ZERO_IDLE;

        // RX ready 模式：READY_ALWAYS（接收侧始终就绪，无反压）
        // 避免 ready 抖动干扰 Straddle 时序的纯净观测
        cfg.rx_ready_mode    = READY_ALWAYS;

        `uvm_info(get_type_name(),
            "build_phase 覆盖完成：straddle_enable=1 cov_straddle=1 VALID_ZERO_IDLE READY_ALWAYS",
            UVM_LOW)
    endfunction : build_phase

    //=========================================================================
    // run_phase：以 16 字节小 payload 运行 200 笔事务，充分激励 Straddle 逻辑
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        xilinx_pcie_loopback_vseq vseq;

        phase.raise_objection(this, "xilinx_pcie_straddle_test");

        `uvm_info(get_type_name(), "===== Straddle Test 开始 =====", UVM_LOW)

        // 创建回环虚拟序列
        vseq = xilinx_pcie_loopback_vseq::type_id::create("vseq");

        // 200 笔事务：覆盖各种 Straddle 对齐边界场景
        vseq.num_transactions  = 200;

        // 16 字节 payload：小于一个 256bit beat（32 字节），
        // 保证每个 beat 可容纳多个 TLP，频繁触发 Straddle 条件
        vseq.max_payload_bytes = 16;

        // 在 virtual sequencer 上启动序列
        vseq.start(env.v_sqr);

        `uvm_info(get_type_name(), "===== Straddle Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_straddle_test");
    endtask : run_phase

endclass : xilinx_pcie_straddle_test

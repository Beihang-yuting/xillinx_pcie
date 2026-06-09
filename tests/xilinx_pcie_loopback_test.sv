//=============================================================================
// 文件名: xilinx_pcie_loopback_test.sv
// 描述: Xilinx PCIe BFM 完整回环压力测试
//
// 功能：继承 xilinx_pcie_base_test，在 build_phase 中开启全量覆盖率和
//       通道独立混合背压配置，在 run_phase 中以 500 笔事务进行长时间回环
//       压力测试，覆盖 Tag 耗尽、FC credit 边界、completion 超时等边界条件。
//
// 测试目标：
//   - 全量覆盖率（cov_enable + 全部子 covergroup）
//   - per_channel_bw_config=1：各通道独立背压
//     RQ/CC（发送侧）：VALID_WEIGHTED 70%，模拟突发传输间隙
//     RC/CQ（接收侧）：READY_WEIGHTED 80%，模拟接收侧偶发反压
//   - num_transactions=500：充分激励各种边界场景
//
// 使用方式：
//   +UVM_TESTNAME=xilinx_pcie_loopback_test
//   建议附加：+DATA_WIDTH=256 +MPS=256 +MRRS=512
//=============================================================================

class xilinx_pcie_loopback_test extends xilinx_pcie_base_test;

    `uvm_component_utils(xilinx_pcie_loopback_test)

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：调用父类配置后，覆盖压力测试专项参数
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        // 先调用父类：完成 plusarg 解析、cfg 创建、env 实例化
        super.build_phase(phase);

        // ------------------------------------------------------------------
        // 覆盖 1：全量覆盖率使能
        // ------------------------------------------------------------------
        cfg.cov_enable     = 1'b1;   // 覆盖率总开关
        cfg.cov_tlp_type   = 1'b1;   // TLP 类型分布
        cfg.cov_descriptor = 1'b1;   // 描述符关键字段取值分布
        cfg.cov_tuser      = 1'b1;   // tuser 边带字段取值组合
        cfg.cov_straddle   = 1'b1;   // Straddle 跨 beat 对齐情况
        cfg.cov_channel    = 1'b1;   // 四通道事务数量分布
        cfg.cov_fc         = 1'b1;   // FC credit 接近耗尽边界条件

        // ------------------------------------------------------------------
        // 覆盖 2：启用通道独立带宽配置
        // per_channel_bw_config=1 后 env 读取 channel_bw_cfg[] 而非全局参数
        // 通道索引：RQ=0, RC=1, CQ=2, CC=3（与 xilinx_channel_e 编码一致）
        // ------------------------------------------------------------------
        cfg.per_channel_bw_config = 1'b1;

        // RQ 通道（索引 0）：EP 发送 DMA 请求，70% valid 突发模式
        cfg.channel_bw_cfg[0].valid_mode   = VALID_WEIGHTED;
        cfg.channel_bw_cfg[0].ready_mode   = READY_ALWAYS;
        cfg.channel_bw_cfg[0].valid_weight = 70;   // 70% valid 占空比
        cfg.channel_bw_cfg[0].ready_weight = 100;
        cfg.channel_bw_cfg[0].idle_cycles  = 0;

        // RC 通道（索引 1）：RC 向 EP 返回完成，80% ready（偶发反压）
        cfg.channel_bw_cfg[1].valid_mode   = VALID_ZERO_IDLE;
        cfg.channel_bw_cfg[1].ready_mode   = READY_WEIGHTED;
        cfg.channel_bw_cfg[1].valid_weight = 100;
        cfg.channel_bw_cfg[1].ready_weight = 80;   // 20% 概率拉低 ready
        cfg.channel_bw_cfg[1].idle_cycles  = 0;

        // CQ 通道（索引 2）：RC 向 EP 转发主机请求，80% ready（偶发反压）
        cfg.channel_bw_cfg[2].valid_mode   = VALID_ZERO_IDLE;
        cfg.channel_bw_cfg[2].ready_mode   = READY_WEIGHTED;
        cfg.channel_bw_cfg[2].valid_weight = 100;
        cfg.channel_bw_cfg[2].ready_weight = 80;   // 20% 概率拉低 ready
        cfg.channel_bw_cfg[2].idle_cycles  = 0;

        // CC 通道（索引 3）：EP 返回完成给 RC，70% valid 突发模式
        cfg.channel_bw_cfg[3].valid_mode   = VALID_WEIGHTED;
        cfg.channel_bw_cfg[3].ready_mode   = READY_ALWAYS;
        cfg.channel_bw_cfg[3].valid_weight = 70;   // 70% valid 占空比
        cfg.channel_bw_cfg[3].ready_weight = 100;
        cfg.channel_bw_cfg[3].idle_cycles  = 0;

        `uvm_info(get_type_name(),
            "build_phase 覆盖完成：全量 cov=1 per_channel_bw_config=1 RQ/CC 70% RC/CQ 80%ready",
            UVM_LOW)
    endfunction : build_phase

    //=========================================================================
    // run_phase：500 笔事务长时间回环压力测试
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        xilinx_pcie_loopback_vseq vseq;

        phase.raise_objection(this, "xilinx_pcie_loopback_test");

        `uvm_info(get_type_name(), "===== Loopback Stress Test 开始 =====", UVM_LOW)

        // 创建回环虚拟序列
        vseq = xilinx_pcie_loopback_vseq::type_id::create("vseq");

        // 500 笔事务：充分激励 Tag 池耗尽、FC credit 边界、completion 超时
        vseq.num_transactions = 500;

        // 在 virtual sequencer 上启动序列（5 阶段全量执行）
        vseq.start(env.v_sqr);

        `uvm_info(get_type_name(), "===== Loopback 序列完成，等待在途 Completion 排空 =====", UVM_LOW)

        // drain：最后一批 MEM_RD（含 4096B 大读）的 CplD 仍在途中。轮询
        // scoreboard 在途请求清零再撤销 objection；500us 上限防止真实挂死时死等。
        begin
            int unsigned drain_us = 0;
            while (env.scb != null && env.scb.outstanding_reqs.size() > 0 &&
                   drain_us < 500) begin
                #1us;
                drain_us++;
            end
            if (env.scb != null && env.scb.outstanding_reqs.size() > 0)
                `uvm_warning(get_type_name(),
                    $sformatf("drain 超时：仍有 %0d 笔在途请求", env.scb.outstanding_reqs.size()))
        end

        `uvm_info(get_type_name(), "===== Loopback Stress Test 完成 =====", UVM_LOW)

        phase.drop_objection(this, "xilinx_pcie_loopback_test");
    endtask : run_phase

endclass : xilinx_pcie_loopback_test

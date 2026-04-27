//=============================================================================
// Xilinx PCIe TL-Layer BFM - 回环虚拟序列
// 运行在 xilinx_pcie_virtual_sequencer 上的多阶段回环测试
// 5 个阶段：Config 枚举 -> Memory RW -> DMA -> 中断 -> Straddle 压力
//=============================================================================

class xilinx_pcie_loopback_vseq extends uvm_sequence;

    `uvm_object_utils(xilinx_pcie_loopback_vseq)

    //=========================================================================
    // 随机化字段
    //=========================================================================

    // 每个阶段的事务数量
    rand int num_transactions;

    // 最大 payload 字节数（用于 Memory 和 DMA 阶段）
    rand int max_payload_bytes;

    //=========================================================================
    // 默认值约束
    //=========================================================================
    constraint c_defaults {
        soft num_transactions   == 20;
        soft max_payload_bytes  == 256;
    }

    constraint c_ranges {
        num_transactions  inside {[1:1000]};
        max_payload_bytes inside {[4:4096]};
    }

    //=========================================================================
    // 内部引用（由 body 从 virtual sequencer 获取）
    //=========================================================================
    xilinx_pcie_virtual_sequencer v_sqr;
    xilinx_pcie_env_config        cfg;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_loopback_vseq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：5 阶段回环测试
    //=========================================================================
    virtual task body();

        // 获取 virtual sequencer 引用
        if (!$cast(v_sqr, m_sequencer)) begin
            `uvm_fatal(get_type_name(),
                "body: m_sequencer 不是 xilinx_pcie_virtual_sequencer，无法执行虚拟序列")
        end

        cfg = v_sqr.cfg;
        if (cfg == null) begin
            `uvm_fatal(get_type_name(),
                "body: virtual sequencer 的 cfg 为 null")
        end

        `uvm_info(get_type_name(),
            $sformatf("回环测试开始: num_transactions=%0d, max_payload_bytes=%0d",
                      num_transactions, max_payload_bytes),
            UVM_LOW)

        // =====================================================================
        // 阶段 1：Config 枚举
        // RC 通过 CQ 发送 CfgRd0，EP 自动回复 CplD
        // =====================================================================
        `uvm_info(get_type_name(), "===== 阶段 1: Config 枚举 =====", UVM_LOW)
        _phase_config_enum();

        #100ns;

        // =====================================================================
        // 阶段 2：Memory Write + Read
        // RC 发送 MWr -> EP 存储 -> RC 发送 MRd -> EP 回复 CplD
        // =====================================================================
        `uvm_info(get_type_name(), "===== 阶段 2: Memory Write + Read =====", UVM_LOW)
        _phase_mem_rw();

        #100ns;

        // =====================================================================
        // 阶段 3：DMA
        // EP 发起 DMA MWr 和 DMA MRd
        // =====================================================================
        `uvm_info(get_type_name(), "===== 阶段 3: DMA =====", UVM_LOW)
        _phase_dma();

        #100ns;

        // =====================================================================
        // 阶段 4：中断
        // EP 发起 MSI 中断（如果 interrupt_enable）
        // =====================================================================
        `uvm_info(get_type_name(), "===== 阶段 4: 中断 =====", UVM_LOW)
        _phase_interrupt();

        #100ns;

        // =====================================================================
        // 阶段 5：Straddle 压力（如果 straddle_enable）
        // 连续发送小 TLP 以测试 Straddle 对齐逻辑
        // =====================================================================
        `uvm_info(get_type_name(), "===== 阶段 5: Straddle 压力 =====", UVM_LOW)
        _phase_straddle_stress();

        `uvm_info(get_type_name(), "回环测试完成", UVM_LOW)
    endtask : body

    //=========================================================================
    // 阶段 1：Config 枚举
    // 在 rc_sqr 上执行若干 CfgRd0 读取配置空间关键寄存器
    //=========================================================================
    protected virtual task _phase_config_enum();
        int cfg_reg_addrs[] = '{
            10'h000,    // Vendor ID / Device ID (DW 0)
            10'h001,    // Status / Command (DW 1)
            10'h002,    // Class Code / Revision ID (DW 2)
            10'h003,    // BIST / Header Type / Latency / Cache Line (DW 3)
            10'h004,    // BAR0 (DW 4)
            10'h005     // BAR1 (DW 5)
        };

        if (v_sqr.rc_sqr == null) begin
            `uvm_warning(get_type_name(),
                "阶段 1: rc_sqr 为 null，跳过 Config 枚举")
            return;
        end

        foreach (cfg_reg_addrs[i]) begin
            xilinx_pcie_cfg_seq cfg_seq;
            cfg_seq = xilinx_pcie_cfg_seq::type_id::create(
                $sformatf("cfg_rd_%0d", i));
            cfg_seq.reg_addr   = cfg_reg_addrs[i];
            cfg_seq.is_write   = 1'b0;
            cfg_seq.is_type1   = 1'b0;
            cfg_seq.first_be   = 4'hF;
            cfg_seq.target_bdf = 16'h0100;  // Bus=1, Dev=0, Func=0
            cfg_seq.cfg        = cfg;
            cfg_seq.start(v_sqr.rc_sqr);
        end

        `uvm_info(get_type_name(),
            $sformatf("阶段 1 完成: 发送 %0d 个 CfgRd0", cfg_reg_addrs.size()),
            UVM_MEDIUM)
    endtask : _phase_config_enum

    //=========================================================================
    // 阶段 2：Memory Write + Read
    // 先写后读，验证数据完整性（由 scoreboard 自动检查）
    //=========================================================================
    protected virtual task _phase_mem_rw();
        int unsigned payload_size;
        bit [63:0] base_addr;

        if (v_sqr.rc_sqr == null) begin
            `uvm_warning(get_type_name(),
                "阶段 2: rc_sqr 为 null，跳过 Memory RW")
            return;
        end

        base_addr = 64'h0000_0001_0000_0000;  // 高于 4GB，测试 64 位地址

        for (int i = 0; i < num_transactions; i++) begin
            xilinx_pcie_mem_seq wr_seq, rd_seq;
            bit [63:0] target_addr;

            // 计算本次事务的地址（每次偏移 payload_size，避免地址重叠）
            payload_size = (max_payload_bytes < cfg.max_payload_size) ?
                            max_payload_bytes : cfg.max_payload_size;
            target_addr = base_addr + i * payload_size;

            // --- MWr ---
            wr_seq = xilinx_pcie_mem_seq::type_id::create(
                $sformatf("mwr_%0d", i));
            wr_seq.addr     = target_addr;
            wr_seq.length   = payload_size;
            wr_seq.is_write = 1'b1;
            wr_seq.tc       = 3'h0;
            wr_seq.attr     = 3'h0;
            wr_seq.cfg      = cfg;
            // 填充递增写数据
            wr_seq.wr_data = new[payload_size];
            for (int j = 0; j < payload_size; j++)
                wr_seq.wr_data[j] = (i + j) & 8'hFF;

            wr_seq.start(v_sqr.rc_sqr);

            // --- MRd ---
            rd_seq = xilinx_pcie_mem_seq::type_id::create(
                $sformatf("mrd_%0d", i));
            rd_seq.addr     = target_addr;
            rd_seq.length   = payload_size;
            rd_seq.is_write = 1'b0;
            rd_seq.tc       = 3'h0;
            rd_seq.attr     = 3'h0;
            rd_seq.cfg      = cfg;

            rd_seq.start(v_sqr.rc_sqr);
        end

        `uvm_info(get_type_name(),
            $sformatf("阶段 2 完成: %0d 对 MWr+MRd", num_transactions),
            UVM_MEDIUM)
    endtask : _phase_mem_rw

    //=========================================================================
    // 阶段 3：DMA
    // EP 发起 DMA MWr 和 DMA MRd（在 ep_sqr 上执行）
    //=========================================================================
    protected virtual task _phase_dma();
        if (v_sqr.ep_sqr == null) begin
            `uvm_warning(get_type_name(),
                "阶段 3: ep_sqr 为 null，跳过 DMA")
            return;
        end

        // DMA Write: EP -> Host
        begin
            xilinx_pcie_dma_seq dma_wr;
            int unsigned dma_size;

            dma_size = max_payload_bytes * 4;  // 跨多个 MPS 分片
            if (dma_size > 65536) dma_size = 65536;

            dma_wr = xilinx_pcie_dma_seq::type_id::create("dma_wr");
            dma_wr.host_addr    = 64'h0000_0002_0000_0000;
            dma_wr.total_length = dma_size;
            dma_wr.is_write     = 1'b1;
            dma_wr.cfg          = cfg;
            // 填充 DMA 写源数据
            dma_wr.src_data = new[dma_size];
            for (int i = 0; i < dma_size; i++)
                dma_wr.src_data[i] = i & 8'hFF;

            dma_wr.start(v_sqr.ep_sqr);
        end

        // DMA Read: Host -> EP
        begin
            xilinx_pcie_dma_seq dma_rd;
            int unsigned dma_size;

            dma_size = max_payload_bytes * 2;
            if (dma_size > 65536) dma_size = 65536;

            dma_rd = xilinx_pcie_dma_seq::type_id::create("dma_rd");
            dma_rd.host_addr    = 64'h0000_0002_0001_0000;
            dma_rd.total_length = dma_size;
            dma_rd.is_write     = 1'b0;
            dma_rd.cfg          = cfg;

            dma_rd.start(v_sqr.ep_sqr);
        end

        `uvm_info(get_type_name(), "阶段 3 完成: DMA Write + Read", UVM_MEDIUM)
    endtask : _phase_dma

    //=========================================================================
    // 阶段 4：中断
    // EP 发起 MSI 中断（仅在 interrupt_enable 为 1 时执行）
    //=========================================================================
    protected virtual task _phase_interrupt();
        if (!cfg.interrupt_enable) begin
            `uvm_info(get_type_name(),
                "阶段 4: interrupt_enable=0，跳过中断测试", UVM_MEDIUM)
            return;
        end

        // 使用 ep_sqr（如果可用）或 rc_sqr 作为宿主 sequencer
        begin
            xilinx_pcie_msi_seq msi_seq;
            uvm_sequencer_base target_sqr;

            target_sqr = (v_sqr.ep_sqr != null) ? v_sqr.ep_sqr : v_sqr.rc_sqr;
            if (target_sqr == null) begin
                `uvm_warning(get_type_name(),
                    "阶段 4: 无可用 sequencer，跳过中断测试")
                return;
            end

            msi_seq = xilinx_pcie_msi_seq::type_id::create("msi_seq");
            msi_seq.mode       = cfg.interrupt_mode;
            msi_seq.vector_num = 0;
            msi_seq.cfg        = cfg;

            // MSI-X 模式下设置地址和数据
            if (cfg.interrupt_mode == XILINX_INT_MSIX) begin
                msi_seq.msix_addr = 64'hFEE0_0000;   // 典型 MSI-X 地址
                msi_seq.msix_data = 32'h0000_0001;
            end

            msi_seq.start(target_sqr);
        end

        `uvm_info(get_type_name(), "阶段 4 完成: 中断发送", UVM_MEDIUM)
    endtask : _phase_interrupt

    //=========================================================================
    // 阶段 5：Straddle 压力测试
    // 连续发送小 TLP（16 字节 payload）以测试 Straddle 对齐逻辑
    // 仅在 straddle_enable=1 时执行
    //=========================================================================
    protected virtual task _phase_straddle_stress();
        if (!cfg.straddle_enable) begin
            `uvm_info(get_type_name(),
                "阶段 5: straddle_enable=0，跳过 Straddle 压力测试", UVM_MEDIUM)
            return;
        end

        if (v_sqr.rc_sqr == null) begin
            `uvm_warning(get_type_name(),
                "阶段 5: rc_sqr 为 null，跳过 Straddle 压力测试")
            return;
        end

        for (int i = 0; i < num_transactions * 2; i++) begin
            xilinx_pcie_mem_seq small_seq;
            int unsigned small_payload;

            // 使用 16 字节的小 payload 以触发 Straddle 条件
            small_payload = 16;

            small_seq = xilinx_pcie_mem_seq::type_id::create(
                $sformatf("straddle_%0d", i));
            small_seq.addr     = 64'h0000_0003_0000_0000 + i * 16;
            small_seq.length   = small_payload;
            small_seq.is_write = 1'b1;
            small_seq.tc       = 3'h0;
            small_seq.attr     = 3'h0;
            small_seq.cfg      = cfg;
            // 填充小 payload 数据
            small_seq.wr_data = new[small_payload];
            for (int j = 0; j < small_payload; j++)
                small_seq.wr_data[j] = (i + j) & 8'hFF;

            small_seq.start(v_sqr.rc_sqr);
        end

        `uvm_info(get_type_name(),
            $sformatf("阶段 5 完成: 发送 %0d 个小 TLP Straddle 压力", num_transactions * 2),
            UVM_MEDIUM)
    endtask : _phase_straddle_stress

endclass : xilinx_pcie_loopback_vseq

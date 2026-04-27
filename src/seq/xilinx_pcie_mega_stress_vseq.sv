//=============================================================================
// 文件名: xilinx_pcie_mega_stress_vseq.sv
// 描述: Xilinx PCIe BFM 超大规模压力测试虚拟序列
//
// 功能：在 virtual_sequencer 上运行多轮 MWr+MRd 对和 DMA 事务，
//       总计产生 20000+ 报文。每轮使用不同的 payload 大小，覆盖
//       4B（最小包）、64B（中等包）、128B（大包）、256B（MPS 上限）。
//
// 设计要点：
//   - 直接继承 uvm_sequence，运行在 xilinx_pcie_virtual_sequencer 上
//   - 不走 loopback_vseq 的 5 阶段框架，避免单次 num_transactions 上限
//   - 每轮内交替发送 MWr+MRd 对（避免 tag 池耗尽）
//   - 轮间无需等待，因为交替模式保证 tag 逐个释放
//   - DMA 阶段在所有 MWr+MRd 轮完成后执行
//
// 参数：
//   - pairs_per_round: 每轮 MWr+MRd 对数（默认 2500，可通过 plusarg 覆盖）
//   - wr_rd_gap_ns:    MWr 与 MRd 之间的等待时间（默认 200ns）
//   - inter_pair_gap_ns: 每对 MWr+MRd 之间的间隔（默认 500ns）
//   - dma_transactions: DMA 阶段事务数（默认 250 对 = 500 笔）
//
// 报文统计：
//   轮 1: pairs_per_round 对 x 4B payload  = pairs_per_round * 2 TLP
//   轮 2: pairs_per_round 对 x 64B payload = pairs_per_round * 2 TLP
//   轮 3: pairs_per_round 对 x 128B payload= pairs_per_round * 2 TLP
//   轮 4: pairs_per_round 对 x 256B payload= pairs_per_round * 2 TLP
//   DMA:  dma_transactions 对              = dma_transactions * 2 TLP
//   总计: pairs_per_round * 8 + dma_transactions * 2
//   默认: 2500 * 8 + 250 * 2 = 20500 TLP
//=============================================================================

class xilinx_pcie_mega_stress_vseq extends uvm_sequence;

    `uvm_object_utils(xilinx_pcie_mega_stress_vseq)

    //=========================================================================
    // 可配置参数
    //=========================================================================

    // 每轮 MWr+MRd 对数（4 轮共 pairs_per_round * 4 对）
    int unsigned pairs_per_round = 2500;

    // MWr 与 MRd 之间的等待时间（ns），确保 EP 完成 MWr 存储后再发 MRd
    int unsigned wr_rd_gap_ns = 200;

    // 每对 MWr+MRd 之间的间隔（ns），等待 completion 返回释放 tag
    int unsigned inter_pair_gap_ns = 500;

    // DMA 阶段每个方向的事务数（写 + 读）
    int unsigned dma_transactions = 250;

    //=========================================================================
    // 内部引用（由 body 从 virtual sequencer 获取）
    //=========================================================================
    xilinx_pcie_virtual_sequencer v_sqr;
    xilinx_pcie_env_config        cfg;

    //=========================================================================
    // 统计计数器
    //=========================================================================
    int unsigned total_mwr_sent;        // 已发送 MWr 数
    int unsigned total_mrd_sent;        // 已发送 MRd 数
    int unsigned total_dma_wr_sent;     // 已发送 DMA MWr 数
    int unsigned total_dma_rd_sent;     // 已发送 DMA MRd 数

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_mega_stress_vseq");
        super.new(name);
        total_mwr_sent    = 0;
        total_mrd_sent    = 0;
        total_dma_wr_sent = 0;
        total_dma_rd_sent = 0;
    endfunction : new

    //=========================================================================
    // body：多轮压力测试主流程
    //=========================================================================
    virtual task body();
        // 获取 virtual sequencer 引用
        if (!$cast(v_sqr, m_sequencer)) begin
            `uvm_fatal(get_type_name(),
                "body: m_sequencer 不是 xilinx_pcie_virtual_sequencer")
        end

        cfg = v_sqr.cfg;
        if (cfg == null) begin
            `uvm_fatal(get_type_name(),
                "body: virtual sequencer 的 cfg 为 null")
        end

        `uvm_info(get_type_name(),
            $sformatf({"===== 超大规模压力测试开始 =====",
                       "\n  每轮对数=%0d, wr_rd_gap=%0dns, inter_pair_gap=%0dns, DMA=%0d对"},
                      pairs_per_round, wr_rd_gap_ns, inter_pair_gap_ns, dma_transactions),
            UVM_LOW)

        // =====================================================================
        // 轮 1：小包高频（4B payload）
        // 最小合法 payload，测试描述符编解码和 tag 管理的高频行为
        // =====================================================================
        _run_mem_rw_round(
            .round_id   (1),
            .num_pairs  (pairs_per_round),
            .payload_sz (4),
            .base_addr  (64'h0000_0001_0000_0000)
        );

        // 轮间等待：让前一轮尾部的 completion 有时间回收
        #1us;

        // =====================================================================
        // 轮 2：中等包（64B payload）
        // 典型 cache line 大小，中等 DW 数
        // =====================================================================
        _run_mem_rw_round(
            .round_id   (2),
            .num_pairs  (pairs_per_round),
            .payload_sz (64),
            .base_addr  (64'h0000_0001_0100_0000)
        );

        #1us;

        // =====================================================================
        // 轮 3：大包（128B payload）
        // 测试多 beat 传输和 tkeep 边界
        // =====================================================================
        _run_mem_rw_round(
            .round_id   (3),
            .num_pairs  (pairs_per_round),
            .payload_sz (128),
            .base_addr  (64'h0000_0001_0200_0000)
        );

        #1us;

        // =====================================================================
        // 轮 4：最大包（256B = MPS payload）
        // 测试 MPS 上限、最大 DW 数、4KB 边界不跨越
        // =====================================================================
        _run_mem_rw_round(
            .round_id   (4),
            .num_pairs  (pairs_per_round),
            .payload_sz (256),
            .base_addr  (64'h0000_0001_0300_0000)
        );

        #2us;

        // =====================================================================
        // 轮 5：DMA 阶段（EP 发起）
        // EP 向 Host 发起 DMA MWr 和 DMA MRd，测试反方向通道
        // =====================================================================
        _run_dma_round();

        // 打印统计
        `uvm_info(get_type_name(),
            $sformatf({"===== 超大规模压力测试序列完成 =====",
                       "\n  MWr 发送: %0d",
                       "\n  MRd 发送: %0d",
                       "\n  DMA MWr:  %0d",
                       "\n  DMA MRd:  %0d",
                       "\n  总报文:   %0d"},
                      total_mwr_sent, total_mrd_sent,
                      total_dma_wr_sent, total_dma_rd_sent,
                      total_mwr_sent + total_mrd_sent + total_dma_wr_sent + total_dma_rd_sent),
            UVM_LOW)

    endtask : body

    //=========================================================================
    // _run_mem_rw_round：执行一轮 MWr+MRd 交替测试
    // 参数：
    //   round_id   - 轮次编号（用于日志）
    //   num_pairs  - MWr+MRd 对数
    //   payload_sz - 本轮 payload 字节数
    //   base_addr  - 本轮起始地址（各轮使用不同地址区域避免冲突）
    //=========================================================================
    protected virtual task _run_mem_rw_round(
        int unsigned round_id,
        int unsigned num_pairs,
        int unsigned payload_sz,
        bit [63:0]   base_addr
    );
        // 限制 payload 不超过 MPS
        int unsigned actual_payload;
        actual_payload = (payload_sz < cfg.max_payload_size) ?
                          payload_sz : cfg.max_payload_size;

        `uvm_info(get_type_name(),
            $sformatf("轮 %0d 开始: %0d 对 MWr+MRd, payload=%0d B, base_addr=0x%016h",
                      round_id, num_pairs, actual_payload, base_addr),
            UVM_LOW)

        for (int i = 0; i < num_pairs; i++) begin
            xilinx_pcie_mem_seq wr_seq, rd_seq;
            bit [63:0] target_addr;

            // 计算目标地址：每对使用不同地址，在 1MB 范围内循环
            // 确保不跨 4KB 边界（地址按 payload 对齐，且 payload <= MPS <= 4096）
            target_addr = base_addr + ((i * actual_payload) % (64'h0010_0000));

            // --- MWr ---
            wr_seq = xilinx_pcie_mem_seq::type_id::create(
                $sformatf("mega_mwr_r%0d_%0d", round_id, i));
            wr_seq.addr     = target_addr;
            wr_seq.length   = actual_payload;
            wr_seq.is_write = 1'b1;
            wr_seq.tc       = 3'h0;
            wr_seq.attr     = 3'h0;
            wr_seq.cfg      = cfg;
            // 填充递增写数据（pattern 包含轮次信息以区分不同轮）
            wr_seq.wr_data = new[actual_payload];
            for (int j = 0; j < actual_payload; j++)
                wr_seq.wr_data[j] = (round_id + i + j) & 8'hFF;

            wr_seq.start(v_sqr.rc_sqr);
            total_mwr_sent++;

            // 等待 EP 处理完 MWr 存储
            repeat (wr_rd_gap_ns) #1ns;

            // --- MRd ---
            rd_seq = xilinx_pcie_mem_seq::type_id::create(
                $sformatf("mega_mrd_r%0d_%0d", round_id, i));
            rd_seq.addr     = target_addr;
            rd_seq.length   = actual_payload;
            rd_seq.is_write = 1'b0;
            rd_seq.tc       = 3'h0;
            rd_seq.attr     = 3'h0;
            rd_seq.cfg      = cfg;

            rd_seq.start(v_sqr.rc_sqr);
            total_mrd_sent++;

            // 对间间隔：等待 completion 返回释放 tag，防止 tag 池耗尽
            if (inter_pair_gap_ns > 0)
                repeat (inter_pair_gap_ns) #1ns;

            // 每 500 对打印进度
            if ((i + 1) % 500 == 0) begin
                `uvm_info(get_type_name(),
                    $sformatf("轮 %0d 进度: %0d/%0d 对已完成",
                              round_id, i + 1, num_pairs),
                    UVM_LOW)
            end
        end

        `uvm_info(get_type_name(),
            $sformatf("轮 %0d 完成: %0d 对 MWr+MRd (payload=%0d B)",
                      round_id, num_pairs, actual_payload),
            UVM_LOW)
    endtask : _run_mem_rw_round

    //=========================================================================
    // _run_dma_round：执行 DMA 阶段
    // EP 发起 DMA MWr（写 Host 内存）和 DMA MRd（读 Host 内存）
    //=========================================================================
    protected virtual task _run_dma_round();
        if (v_sqr.ep_sqr == null) begin
            `uvm_warning(get_type_name(),
                "DMA 阶段: ep_sqr 为 null，跳过")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("DMA 阶段开始: %0d 对 DMA 写+读", dma_transactions),
            UVM_LOW)

        for (int i = 0; i < dma_transactions; i++) begin
            // --- DMA MWr（EP -> Host）---
            begin
                xilinx_pcie_dma_seq dma_wr;
                int unsigned dma_size;

                // DMA 写大小：128B（单 MPS 分片，简化处理）
                dma_size = 128;

                dma_wr = xilinx_pcie_dma_seq::type_id::create(
                    $sformatf("mega_dma_wr_%0d", i));
                dma_wr.host_addr    = 64'h0000_0002_0000_0000 + i * 256;
                dma_wr.total_length = dma_size;
                dma_wr.is_write     = 1'b1;
                dma_wr.cfg          = cfg;
                // 填充 DMA 写源数据
                dma_wr.src_data = new[dma_size];
                for (int j = 0; j < dma_size; j++)
                    dma_wr.src_data[j] = (i + j) & 8'hFF;

                dma_wr.start(v_sqr.ep_sqr);
                total_dma_wr_sent++;
            end

            // 短暂等待
            #100ns;

            // --- DMA MRd（EP <- Host）---
            begin
                xilinx_pcie_dma_seq dma_rd;
                int unsigned dma_size;

                // DMA 读大小：64B
                dma_size = 64;

                dma_rd = xilinx_pcie_dma_seq::type_id::create(
                    $sformatf("mega_dma_rd_%0d", i));
                dma_rd.host_addr    = 64'h0000_0002_0001_0000 + i * 256;
                dma_rd.total_length = dma_size;
                dma_rd.is_write     = 1'b0;
                dma_rd.cfg          = cfg;

                dma_rd.start(v_sqr.ep_sqr);
                total_dma_rd_sent++;
            end

            // DMA 对间等待，让 completion 返回
            #200ns;

            // 每 50 对打印进度
            if ((i + 1) % 50 == 0) begin
                `uvm_info(get_type_name(),
                    $sformatf("DMA 进度: %0d/%0d 对已完成",
                              i + 1, dma_transactions),
                    UVM_LOW)
            end
        end

        `uvm_info(get_type_name(),
            $sformatf("DMA 阶段完成: %0d 对写+读", dma_transactions),
            UVM_LOW)
    endtask : _run_dma_round

endclass : xilinx_pcie_mega_stress_vseq

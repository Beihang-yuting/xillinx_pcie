//=============================================================================
// Xilinx PCIe TL-Layer BFM - DMA 序列
// EP 发起的 DMA 读写事务，自动按 MPS/MRRS 和 4KB 边界分割
//=============================================================================

class xilinx_pcie_dma_seq extends xilinx_pcie_base_seq;

    `uvm_object_utils(xilinx_pcie_dma_seq)

    //=========================================================================
    // 随机化字段
    //=========================================================================

    // 主机内存目标地址
    rand bit [63:0]      host_addr;

    // 总传输字节数（可超过 MPS/MRRS，序列自动分割）
    rand int unsigned    total_length;

    // 方向：1=DMA 写（EP->Host MWr），0=DMA 读（EP->Host MRd）
    rand bit             is_write;

    // DMA 写时的源数据（从 EP 本地内存读出的数据）
    rand bit [7:0]       src_data[];

    // 由上层 vseq 赋值（EP 发起 DMA → 对端是 host，赋 v_sqr.host_mem）；null 表示不用统一内存
    host_mem_api         target_mem;

    //=========================================================================
    // 约束
    //=========================================================================

    // 总传输长度范围：1 字节 ~ 1MB
    constraint c_total_length_range {
        total_length inside {[1:1048576]};
    }

    // 写时源数据大小必须与 total_length 匹配
    constraint c_src_data_size {
        is_write  -> src_data.size() == total_length;
        !is_write -> src_data.size() == 0;
    }

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_dma_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：将大块 DMA 传输分割为多个合法 Memory TLP 并依次发送
    //=========================================================================
    virtual task body();
        int unsigned remaining;
        bit [63:0]   current_addr;
        int unsigned offset;
        int unsigned chunk;
        int unsigned tlp_idx;

        // use_unified_mem 模式：从目标内存分配对齐缓冲区，覆盖调用方传入的 host_addr
        if (cfg.use_unified_mem && target_mem != null) begin
            host_addr = target_mem.alloc(total_length, 64);
        end

        remaining    = total_length;
        current_addr = host_addr;
        offset       = 0;
        tlp_idx      = 0;

        `uvm_info(get_type_name(),
            $sformatf("DMA %s 开始: host_addr=0x%016h, total_length=%0d bytes",
                      is_write ? "Write" : "Read", host_addr, total_length),
            UVM_MEDIUM)

        while (remaining > 0) begin
            pcie_tl_mem_tlp tlp;
            bit [3:0] f_be, l_be;
            int unsigned dw_count;
            int unsigned first_byte_offset;
            int unsigned last_byte_offset;
            bit is_64;

            // 计算本次分片大小
            chunk = _calc_chunk_size(current_addr, remaining);

            // 创建 Memory TLP
            tlp = pcie_tl_mem_tlp::type_id::create(
                $sformatf("dma_tlp_%0d", tlp_idx));

            // 计算 byte enable
            first_byte_offset = current_addr[1:0];
            last_byte_offset  = (current_addr + chunk - 1) % 4;
            dw_count = (chunk + first_byte_offset + 3) / 4;

            if (dw_count == 1) begin
                f_be = _make_single_dw_be(first_byte_offset, last_byte_offset);
                l_be = 4'b0000;
            end else begin
                f_be = (4'b1111 << first_byte_offset) & 4'b1111;
                l_be = (4'b1111 >> (3 - last_byte_offset)) & 4'b1111;
            end

            // 判断地址宽度
            is_64 = (current_addr[63:32] != 32'h0);

            // 设置 TLP 字段
            tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
            tlp.kind      = is_write ? TLP_MEM_WR : TLP_MEM_RD;
            tlp.addr      = current_addr;
            tlp.is_64bit  = is_64;
            tlp.length    = (dw_count == 1024) ? 10'h0 : dw_count[9:0];
            tlp.first_be  = f_be;
            tlp.last_be   = l_be;
            tlp.tc        = 3'h0;
            tlp.attr      = 3'h0;

            // 设置 fmt
            if (is_write) begin
                tlp.fmt = is_64 ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
            end else begin
                tlp.fmt = is_64 ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
            end

            // 写请求填充 payload
            if (is_write) begin
                tlp.payload = new[dw_count * 4];
                // 前导无效字节填 0
                for (int i = 0; i < first_byte_offset; i++)
                    tlp.payload[i] = 8'h00;
                // 有效数据
                for (int i = 0; i < chunk; i++)
                    tlp.payload[first_byte_offset + i] = src_data[offset + i];
                // 尾部 padding 填 0
                for (int i = first_byte_offset + chunk; i < dw_count * 4; i++)
                    tlp.payload[i] = 8'h00;
            end else begin
                tlp.payload = new[0];
            end

            // 发送 TLP
            `uvm_info(get_type_name(),
                $sformatf("DMA 分片 #%0d: addr=0x%016h, chunk=%0d bytes, dw=%0d, remaining=%0d",
                          tlp_idx, current_addr, chunk, dw_count, remaining - chunk),
                UVM_HIGH)

            start_item(tlp);
            finish_item(tlp);

            // 更新游标
            current_addr += chunk;
            remaining    -= chunk;
            offset       += chunk;
            tlp_idx++;
        end

        `uvm_info(get_type_name(),
            $sformatf("DMA %s 完成: 共发送 %0d 个 TLP",
                      is_write ? "Write" : "Read", tlp_idx),
            UVM_MEDIUM)
    endtask : body

    //=========================================================================
    // 辅助函数：计算本次分片大小
    // 取 remaining、MPS/MRRS、到 4KB 边界距离的最小值
    //=========================================================================
    protected function int unsigned _calc_chunk_size(
        bit [63:0]   addr,
        int unsigned remaining
    );
        int unsigned max_size;
        int unsigned to_4kb;
        int unsigned chunk;

        // 根据方向选择上限：写用 MPS，读用 MRRS
        max_size = is_write ? cfg.max_payload_size : cfg.max_read_request_size;

        // 到下一个 4KB 边界的距离
        to_4kb = 4096 - (addr % 4096);

        // 取三者最小值
        chunk = remaining;
        if (max_size < chunk) chunk = max_size;
        if (to_4kb  < chunk) chunk = to_4kb;

        return chunk;
    endfunction : _calc_chunk_size

    //=========================================================================
    // 辅助函数：计算单 DW 情况下的 byte enable
    //=========================================================================
    protected function bit [3:0] _make_single_dw_be(int lo, int hi);
        bit [3:0] be = 4'b0000;
        for (int i = lo; i <= hi; i++)
            be[i] = 1'b1;
        return be;
    endfunction : _make_single_dw_be

endclass : xilinx_pcie_dma_seq

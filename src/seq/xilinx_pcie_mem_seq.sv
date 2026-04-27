//=============================================================================
// Xilinx PCIe TL-Layer BFM - Memory Read/Write 序列
// 单次 Memory Read 或 Memory Write 事务
// 自动计算 first_be/last_be、fmt、DW length
//=============================================================================

class xilinx_pcie_mem_seq extends xilinx_pcie_base_seq;

    `uvm_object_utils(xilinx_pcie_mem_seq)

    //=========================================================================
    // 随机化字段
    //=========================================================================

    // 目标地址（64 位，支持 32/64 位地址空间）
    rand bit [63:0]      addr;

    // 传输字节数
    rand int unsigned    length;

    // 方向：1=写（MWr），0=读（MRd）
    rand bit             is_write;

    // 写数据（MWr 时有效）
    rand bit [7:0]       wr_data[];

    // Traffic Class
    rand bit [2:0]       tc;

    // Attribute 字段（[0]=RO, [1]=IDO, [2]=NS）
    rand bit [2:0]       attr;

    //=========================================================================
    // 约束
    //=========================================================================

    // 传输字节数范围：1 ~ 4096
    constraint c_length_range {
        length inside {[1:4096]};
    }

    // 不跨 4KB 地址边界
    constraint c_no_4kb_cross {
        (addr % 4096) + length <= 4096;
    }

    // MWr：字节数不超过 Max Payload Size
    constraint c_mps_limit {
        is_write -> length <= cfg.max_payload_size;
    }

    // MRd：字节数不超过 Max Read Request Size
    constraint c_mrrs_limit {
        !is_write -> length <= cfg.max_read_request_size;
    }

    // 写数据大小必须与 length 匹配（写时）
    constraint c_wr_data_size {
        is_write  -> wr_data.size() == length;
        !is_write -> wr_data.size() == 0;
    }

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_mem_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：构造并发送单个 Memory TLP
    //=========================================================================
    virtual task body();
        pcie_tl_mem_tlp tlp;
        bit [3:0] f_be, l_be;
        int unsigned dw_count;
        int unsigned first_byte_offset;
        int unsigned last_byte_offset;
        bit is_64;

        // 步骤 1：创建 pcie_tl_mem_tlp 实例
        tlp = pcie_tl_mem_tlp::type_id::create("mem_tlp");

        // 步骤 2：计算 first_be 和 last_be
        first_byte_offset = addr[1:0];
        last_byte_offset  = (addr + length - 1) % 4;
        dw_count = (length + first_byte_offset + 3) / 4;

        if (dw_count == 1) begin
            // 单 DW：first_be 覆盖 [first_byte_offset, last_byte_offset]
            f_be = _make_single_dw_be(first_byte_offset, last_byte_offset);
            l_be = 4'b0000;
        end else begin
            // 多 DW：first_be 从 first_byte_offset 开始到 DW 末尾
            f_be = (4'b1111 << first_byte_offset) & 4'b1111;
            // last_be 从 DW 开头到 last_byte_offset
            l_be = (4'b1111 >> (3 - last_byte_offset)) & 4'b1111;
        end

        // 步骤 3：判断是否需要 64 位地址格式
        is_64 = (addr[63:32] != 32'h0);

        // 步骤 4：设置 TLP 字段（手动赋值，不使用内建随机化）
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.kind      = is_write ? TLP_MEM_WR : TLP_MEM_RD;
        tlp.addr      = addr;
        tlp.is_64bit  = is_64;
        tlp.length    = (dw_count == 1024) ? 10'h0 : dw_count[9:0];
        tlp.first_be  = f_be;
        tlp.last_be   = l_be;
        tlp.tc        = tc;
        tlp.attr      = attr;

        // 步骤 5：设置 fmt（根据地址宽度和是否携带数据）
        if (is_write) begin
            tlp.fmt = is_64 ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        end else begin
            tlp.fmt = is_64 ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        end

        // 步骤 6：写请求设置 payload（按 DW 对齐填充）
        if (is_write) begin
            // payload 长度 = dw_count * 4 字节（DW 对齐）
            tlp.payload = new[dw_count * 4];
            // 前 first_byte_offset 字节填 0（无效字节，由 first_be 屏蔽）
            for (int i = 0; i < first_byte_offset; i++)
                tlp.payload[i] = 8'h00;
            // 有效数据从 first_byte_offset 开始
            for (int i = 0; i < length; i++)
                tlp.payload[first_byte_offset + i] = wr_data[i];
            // 尾部 padding 填 0（last DW 无效字节，由 last_be 屏蔽）
            for (int i = first_byte_offset + length; i < dw_count * 4; i++)
                tlp.payload[i] = 8'h00;
        end else begin
            tlp.payload = new[0];
        end

        // 步骤 7：通过 sequencer 发送 TLP
        `uvm_info(get_type_name(),
            $sformatf("发送 %s: addr=0x%016h, length=%0d bytes, dw_count=%0d, first_be=0x%01h, last_be=0x%01h",
                      is_write ? "MWr" : "MRd", addr, length, dw_count, f_be, l_be),
            UVM_MEDIUM)

        start_item(tlp);
        finish_item(tlp);
    endtask : body

    //=========================================================================
    // 辅助函数：计算单 DW 情况下的 byte enable
    // 生成覆盖 [lo, hi] 字节偏移的 BE 掩码
    //=========================================================================
    protected function bit [3:0] _make_single_dw_be(int lo, int hi);
        bit [3:0] be = 4'b0000;
        for (int i = lo; i <= hi; i++)
            be[i] = 1'b1;
        return be;
    endfunction : _make_single_dw_be

endclass : xilinx_pcie_mem_seq

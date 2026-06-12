//=============================================================================
// Xilinx PCIe TL-Layer BFM - 统一内存双向往返验证虚拟序列
//
// 功能：以 use_unified_mem=1 模式验证双向内存访问路径
//   Phase A：RC 通过 MWr/MRd 访问 EP dev_mem（RC↔EP）
//   Phase B：EP 通过 MWr/MRd 访问 RC host_mem（EP↔RC）
//   Phase D：EP 发起 AtomicOp（FetchAdd/Swap/CAS）到 RC host_mem，验证原子操作路径
//   Phase C：泄漏检查（host_mem + dev_mem）
//=============================================================================

class xilinx_pcie_unified_mem_vseq extends uvm_sequence;

    `uvm_object_utils(xilinx_pcie_unified_mem_vseq)

    //=========================================================================
    // 内部引用（由 body 从 virtual sequencer 获取）
    //=========================================================================
    xilinx_pcie_virtual_sequencer v_sqr;
    xilinx_pcie_env_config        cfg;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_unified_mem_vseq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：3 阶段统一内存往返验证
    //=========================================================================
    virtual task body();

        // 获取 virtual sequencer 引用
        if (!$cast(v_sqr, m_sequencer)) begin
            `uvm_fatal(get_type_name(),
                "body: m_sequencer 不是 xilinx_pcie_virtual_sequencer，无法执行虚拟序列")
        end

        cfg = v_sqr.cfg;
        if (cfg == null) begin
            `uvm_fatal(get_type_name(), "body: virtual sequencer 的 cfg 为 null")
        end

        if (!cfg.use_unified_mem) begin
            `uvm_warning(get_type_name(),
                "body: use_unified_mem=0，本序列仅在统一内存模式下有意义")
        end

        `uvm_info(get_type_name(), "===== unified_mem_vseq 开始 =====", UVM_LOW)

        _phase_a_dev_mem();
        _phase_b_host_mem();
        _phase_d_atomic();
        _phase_c_leak_check();

        `uvm_info(get_type_name(), "===== unified_mem_vseq 完成 =====", UVM_LOW)
    endtask : body

    //=========================================================================
    // Phase A：dev_mem 往返（RC 写→RC 读→直接验证 EP 侧内存）
    // RC 发 MWr 到 dev_mem，EP 的 mem_resp 存储；
    // RC 发 MRd，EP 的 mem_resp 返回 CplD；
    // 最后直接读 dev_mem 比较 golden，确认存储正确。
    //=========================================================================
    protected virtual task _phase_a_dev_mem();
        bit [63:0] addr;
        int unsigned length;
        byte golden[];
        byte rd_buf[];

        `uvm_info(get_type_name(), "===== Phase A: dev_mem 往返 =====", UVM_LOW)

        length = 256;

        if (v_sqr.dev_mem == null) begin
            `uvm_fatal(get_type_name(), "Phase A: v_sqr.dev_mem 为 null")
        end

        // 分配内存区域
        addr = v_sqr.dev_mem.alloc(length, 64, `__FILE__, `__LINE__);
        `uvm_info(get_type_name(),
            $sformatf("Phase A: dev_mem.alloc addr=0x%016h length=%0d", addr, length),
            UVM_LOW)

        // 构造 golden 数据
        golden = new[length];
        for (int i = 0; i < length; i++)
            golden[i] = byte'((8'hA5 ^ (i & 8'hFF)));

        // --- MWr：RC 写 dev_mem ---
        begin
            xilinx_pcie_mem_seq wr_seq;
            wr_seq = xilinx_pcie_mem_seq::type_id::create("phase_a_mwr");
            wr_seq.addr     = addr;
            wr_seq.length   = length;
            wr_seq.is_write = 1'b1;
            wr_seq.cfg      = cfg;
            wr_seq.wr_data  = new[length];
            foreach (golden[i]) wr_seq.wr_data[i] = golden[i];
            wr_seq.start(v_sqr.rc_sqr);
        end

        // 等待 MWr 完成（Posted，无 completion；给 EP 时间处理写操作）
        #500ns;

        // --- MRd：RC 读回 dev_mem ---
        begin
            xilinx_pcie_mem_seq rd_seq;
            rd_seq = xilinx_pcie_mem_seq::type_id::create("phase_a_mrd");
            rd_seq.addr     = addr;
            rd_seq.length   = length;
            rd_seq.is_write = 1'b0;
            rd_seq.cfg      = cfg;
            rd_seq.start(v_sqr.rc_sqr);
        end

        // 等待 CplD 在途完成
        #1us;

        // --- 直接读取 dev_mem 比较 golden ---
        v_sqr.dev_mem.read_mem(addr, length, rd_buf, `__FILE__, `__LINE__);

        begin
            bit ok = 1'b1;
            for (int i = 0; i < length; i++) begin
                if (rd_buf[i] !== golden[i]) begin
                    `uvm_error(get_type_name(),
                        $sformatf("Phase A mem_compare FAIL: offset=%0d expected=0x%02h got=0x%02h",
                            i, golden[i], rd_buf[i]))
                    ok = 1'b0;
                    break;
                end
            end
            if (ok)
                `uvm_info(get_type_name(),
                    $sformatf("Phase A mem_compare PASS: addr=0x%016h length=%0d", addr, length),
                    UVM_LOW)
        end

        // 释放内存
        v_sqr.dev_mem.free(addr, `__FILE__, `__LINE__);

        `uvm_info(get_type_name(), "Phase A 完成", UVM_LOW)
    endtask : _phase_a_dev_mem

    //=========================================================================
    // Phase B：host_mem 往返（EP 写→EP 读→直接验证 RC 侧内存）
    // EP 发 MWr 到 host_mem，RC 的 mem_resp 存储；
    // EP 发 MRd，RC 的 mem_resp 返回 CplD；
    // 最后直接读 host_mem 比较 golden2，确认存储正确。
    //=========================================================================
    protected virtual task _phase_b_host_mem();
        bit [63:0] haddr;
        int unsigned length;
        byte golden2[];
        byte rd_buf[];

        `uvm_info(get_type_name(), "===== Phase B: host_mem 往返 =====", UVM_LOW)

        length = 256;

        if (v_sqr.host_mem == null) begin
            `uvm_fatal(get_type_name(), "Phase B: v_sqr.host_mem 为 null")
        end

        // 分配内存区域
        haddr = v_sqr.host_mem.alloc(length, 64, `__FILE__, `__LINE__);
        `uvm_info(get_type_name(),
            $sformatf("Phase B: host_mem.alloc haddr=0x%016h length=%0d", haddr, length),
            UVM_LOW)

        // 构造第二 golden 数据
        golden2 = new[length];
        for (int i = 0; i < length; i++)
            golden2[i] = byte'((8'h5A ^ (i & 8'hFF)));

        // --- MWr：EP 写 host_mem ---
        begin
            xilinx_pcie_mem_seq wr_seq;
            wr_seq = xilinx_pcie_mem_seq::type_id::create("phase_b_mwr");
            wr_seq.addr     = haddr;
            wr_seq.length   = length;
            wr_seq.is_write = 1'b1;
            wr_seq.cfg      = cfg;
            wr_seq.wr_data  = new[length];
            foreach (golden2[i]) wr_seq.wr_data[i] = golden2[i];
            wr_seq.start(v_sqr.ep_sqr);
        end

        // 等待 MWr 完成
        #500ns;

        // --- MRd：EP 读回 host_mem ---
        begin
            xilinx_pcie_mem_seq rd_seq;
            rd_seq = xilinx_pcie_mem_seq::type_id::create("phase_b_mrd");
            rd_seq.addr     = haddr;
            rd_seq.length   = length;
            rd_seq.is_write = 1'b0;
            rd_seq.cfg      = cfg;
            rd_seq.start(v_sqr.ep_sqr);
        end

        // 等待 CplD 在途完成
        #1us;

        // --- 直接读取 host_mem 比较 golden2 ---
        v_sqr.host_mem.read_mem(haddr, length, rd_buf, `__FILE__, `__LINE__);

        begin
            bit ok = 1'b1;
            for (int i = 0; i < length; i++) begin
                if (rd_buf[i] !== golden2[i]) begin
                    `uvm_error(get_type_name(),
                        $sformatf("Phase B mem_compare FAIL: offset=%0d expected=0x%02h got=0x%02h",
                            i, golden2[i], rd_buf[i]))
                    ok = 1'b0;
                    break;
                end
            end
            if (ok)
                `uvm_info(get_type_name(),
                    $sformatf("Phase B mem_compare PASS: haddr=0x%016h length=%0d", haddr, length),
                    UVM_LOW)
        end

        // 释放内存
        v_sqr.host_mem.free(haddr, `__FILE__, `__LINE__);

        `uvm_info(get_type_name(), "Phase B 完成", UVM_LOW)
    endtask : _phase_b_host_mem

    //=========================================================================
    // Phase D：原子操作端到端验证（EP → RC host_mem）
    //
    // 32 位操作（is_64bit=0，sz=4），each op 独立分配 / 预置 / 验证 / 释放。
    // 验证顺序：FetchAdd → Swap → CAS(match) → CAS(no-match)
    //=========================================================================
    protected virtual task _phase_d_atomic();
        bit [63:0] a;
        int unsigned sz;
        byte oldb[];
        byte rd[];

        `uvm_info(get_type_name(), "===== Phase D: Atomic 端到端验证 =====", UVM_LOW)

        if (v_sqr.host_mem == null) begin
            `uvm_fatal(get_type_name(), "Phase D: v_sqr.host_mem 为 null")
        end

        sz = 4;  // 32 位操作

        // ------------------------------------------------------------------
        // D1: FetchAdd
        //   old=0x0000_0010, operand=0x0000_0005
        //   expected new = old + operand = 0x0000_0015
        // ------------------------------------------------------------------
        begin
            xilinx_pcie_atomic_seq seq;
            longint unsigned old_val   = 32'h0000_0010;
            longint unsigned opnd      = 32'h0000_0005;
            longint unsigned expected  = old_val + opnd;
            longint unsigned got;

            `uvm_info(get_type_name(), "Phase D1: FetchAdd", UVM_LOW)

            a = v_sqr.host_mem.alloc(sz, sz, `__FILE__, `__LINE__);
            oldb = new[sz];
            for (int i = 0; i < sz; i++)
                oldb[i] = byte'((old_val >> (8*i)) & 32'hFF);
            v_sqr.host_mem.write_mem(a, oldb, `__FILE__, `__LINE__);

            seq = xilinx_pcie_atomic_seq::type_id::create("d1_fetchadd");
            seq.cfg         = cfg;
            seq.addr        = a;
            seq.is_64bit    = 1'b0;
            seq.atomic_kind = TLP_ATOMIC_FETCHADD;
            seq.operand     = opnd;
            seq.start(v_sqr.ep_sqr);

            #1us;
            v_sqr.host_mem.read_mem(a, sz, rd, `__FILE__, `__LINE__);
            got = 0;
            for (int i = 0; i < sz; i++)
                got |= (longint'(rd[i]) & 64'hFF) << (8*i);

            if (got !== expected)
                `uvm_error(get_type_name(),
                    $sformatf("Phase D1 FetchAdd FAIL: expected=0x%08h got=0x%08h",
                        expected, got))
            else
                `uvm_info(get_type_name(),
                    $sformatf("Phase D1 FetchAdd PASS: old=0x%08h op=0x%08h new=0x%08h",
                        old_val, opnd, got), UVM_LOW)

            v_sqr.host_mem.free(a, `__FILE__, `__LINE__);
        end

        // ------------------------------------------------------------------
        // D2: Swap
        //   old=0x0000_ABCD, operand=0x1234_5678
        //   expected new = operand = 0x1234_5678
        // ------------------------------------------------------------------
        begin
            xilinx_pcie_atomic_seq seq;
            longint unsigned old_val  = 32'h0000_ABCD;
            longint unsigned opnd     = 32'h1234_5678;
            longint unsigned expected = opnd;
            longint unsigned got;

            `uvm_info(get_type_name(), "Phase D2: Swap", UVM_LOW)

            a = v_sqr.host_mem.alloc(sz, sz, `__FILE__, `__LINE__);
            oldb = new[sz];
            for (int i = 0; i < sz; i++)
                oldb[i] = byte'((old_val >> (8*i)) & 32'hFF);
            v_sqr.host_mem.write_mem(a, oldb, `__FILE__, `__LINE__);

            seq = xilinx_pcie_atomic_seq::type_id::create("d2_swap");
            seq.cfg         = cfg;
            seq.addr        = a;
            seq.is_64bit    = 1'b0;
            seq.atomic_kind = TLP_ATOMIC_SWAP;
            seq.operand     = opnd;
            seq.start(v_sqr.ep_sqr);

            #1us;
            v_sqr.host_mem.read_mem(a, sz, rd, `__FILE__, `__LINE__);
            got = 0;
            for (int i = 0; i < sz; i++)
                got |= (longint'(rd[i]) & 64'hFF) << (8*i);

            if (got !== expected)
                `uvm_error(get_type_name(),
                    $sformatf("Phase D2 Swap FAIL: expected=0x%08h got=0x%08h",
                        expected, got))
            else
                `uvm_info(get_type_name(),
                    $sformatf("Phase D2 Swap PASS: old=0x%08h opnd=0x%08h new=0x%08h",
                        old_val, opnd, got), UVM_LOW)

            v_sqr.host_mem.free(a, `__FILE__, `__LINE__);
        end

        // ------------------------------------------------------------------
        // D3: CAS（匹配：compare == old，内存变为 swap_val）
        //   old=0xDEAD_BEEF, compare=0xDEAD_BEEF, swap_val=0xCAFE_BABE
        //   expected new = 0xCAFE_BABE
        // ------------------------------------------------------------------
        begin
            xilinx_pcie_atomic_seq seq;
            longint unsigned old_val  = 32'hDEAD_BEEF;
            longint unsigned cmp      = 32'hDEAD_BEEF;
            longint unsigned swp      = 32'hCAFE_BABE;
            longint unsigned expected = swp;
            longint unsigned got;

            `uvm_info(get_type_name(), "Phase D3: CAS (match)", UVM_LOW)

            a = v_sqr.host_mem.alloc(sz, sz, `__FILE__, `__LINE__);
            oldb = new[sz];
            for (int i = 0; i < sz; i++)
                oldb[i] = byte'((old_val >> (8*i)) & 32'hFF);
            v_sqr.host_mem.write_mem(a, oldb, `__FILE__, `__LINE__);

            seq = xilinx_pcie_atomic_seq::type_id::create("d3_cas_match");
            seq.cfg         = cfg;
            seq.addr        = a;
            seq.is_64bit    = 1'b0;
            seq.atomic_kind = TLP_ATOMIC_CAS;
            seq.compare     = cmp;
            seq.swap_val    = swp;
            seq.start(v_sqr.ep_sqr);

            #1us;
            v_sqr.host_mem.read_mem(a, sz, rd, `__FILE__, `__LINE__);
            got = 0;
            for (int i = 0; i < sz; i++)
                got |= (longint'(rd[i]) & 64'hFF) << (8*i);

            if (got !== expected)
                `uvm_error(get_type_name(),
                    $sformatf("Phase D3 CAS-match FAIL: expected=0x%08h got=0x%08h",
                        expected, got))
            else
                `uvm_info(get_type_name(),
                    $sformatf("Phase D3 CAS-match PASS: old=0x%08h cmp=0x%08h swp=0x%08h new=0x%08h",
                        old_val, cmp, swp, got), UVM_LOW)

            v_sqr.host_mem.free(a, `__FILE__, `__LINE__);
        end

        // ------------------------------------------------------------------
        // D4: CAS（不匹配：compare != old，内存不变）
        //   old=0x1111_2222, compare=0xFFFF_FFFF (≠ old), swap_val=0xAAAA_BBBB
        //   expected new = old = 0x1111_2222 (unchanged)
        // ------------------------------------------------------------------
        begin
            xilinx_pcie_atomic_seq seq;
            longint unsigned old_val  = 32'h1111_2222;
            longint unsigned cmp      = 32'hFFFF_FFFF;
            longint unsigned swp      = 32'hAAAA_BBBB;
            longint unsigned expected = old_val;
            longint unsigned got;

            `uvm_info(get_type_name(), "Phase D4: CAS (no-match)", UVM_LOW)

            a = v_sqr.host_mem.alloc(sz, sz, `__FILE__, `__LINE__);
            oldb = new[sz];
            for (int i = 0; i < sz; i++)
                oldb[i] = byte'((old_val >> (8*i)) & 32'hFF);
            v_sqr.host_mem.write_mem(a, oldb, `__FILE__, `__LINE__);

            seq = xilinx_pcie_atomic_seq::type_id::create("d4_cas_nomatch");
            seq.cfg         = cfg;
            seq.addr        = a;
            seq.is_64bit    = 1'b0;
            seq.atomic_kind = TLP_ATOMIC_CAS;
            seq.compare     = cmp;
            seq.swap_val    = swp;
            seq.start(v_sqr.ep_sqr);

            #1us;
            v_sqr.host_mem.read_mem(a, sz, rd, `__FILE__, `__LINE__);
            got = 0;
            for (int i = 0; i < sz; i++)
                got |= (longint'(rd[i]) & 64'hFF) << (8*i);

            if (got !== expected)
                `uvm_error(get_type_name(),
                    $sformatf("Phase D4 CAS-nomatch FAIL: expected=0x%08h got=0x%08h",
                        expected, got))
            else
                `uvm_info(get_type_name(),
                    $sformatf("Phase D4 CAS-nomatch PASS: old=0x%08h cmp=0x%08h (mismatch) new=0x%08h (unchanged)",
                        old_val, cmp, got), UVM_LOW)

            v_sqr.host_mem.free(a, `__FILE__, `__LINE__);
        end

        `uvm_info(get_type_name(), "Phase D 完成", UVM_LOW)
    endtask : _phase_d_atomic

    //=========================================================================
    // Phase C：泄漏检查
    // 所有 alloc 已 free，leak_check 应报告 0 泄漏
    //=========================================================================
    protected virtual task _phase_c_leak_check();
        `uvm_info(get_type_name(), "===== Phase C: 泄漏检查 =====", UVM_LOW)

        if (v_sqr.host_mem != null)
            v_sqr.host_mem.leak_check(`__FILE__, `__LINE__);
        else
            `uvm_warning(get_type_name(), "Phase C: host_mem 为 null，跳过 leak_check")

        if (v_sqr.dev_mem != null)
            v_sqr.dev_mem.leak_check(`__FILE__, `__LINE__);
        else
            `uvm_warning(get_type_name(), "Phase C: dev_mem 为 null，跳过 leak_check")

        `uvm_info(get_type_name(), "Phase C 完成", UVM_LOW)
    endtask : _phase_c_leak_check

endclass : xilinx_pcie_unified_mem_vseq

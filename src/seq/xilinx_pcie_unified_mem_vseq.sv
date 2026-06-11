//=============================================================================
// Xilinx PCIe TL-Layer BFM - 统一内存双向往返验证虚拟序列
//
// 功能：以 use_unified_mem=1 模式验证双向内存访问路径
//   Phase A：RC 通过 MWr/MRd 访问 EP dev_mem（RC↔EP）
//   Phase B：EP 通过 MWr/MRd 访问 RC host_mem（EP↔RC）
//   Phase C：泄漏检查（host_mem + dev_mem）
//
// 原子操作（FetchAdd/Swap/CAS）暂未包含，作为后续 follow-up 任务处理。
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

//=============================================================================
// Xilinx PCIe TL-Layer BFM - RC Agent（Root Complex 特化）
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：继承 xilinx_pcie_agent，添加 RC 特有功能：
//   1. Completion 超时追踪：监控 Non-Posted 请求的 completion 是否超时
//   2. BAR 地址分配：为 EP 分配 BAR 基地址（RC 枚举功能）
//   3. 订阅 monitor 的 tlp_rx_ap 以追踪 completion 匹配
//=============================================================================

class xilinx_pcie_rc_agent extends xilinx_pcie_agent;

    `uvm_component_utils(xilinx_pcie_rc_agent)

    //=========================================================================
    // RC 特有成员
    //=========================================================================

    // outstanding 请求 map：tag -> 原始请求 TLP
    pcie_tl_tlp                     outstanding_reqs[bit [9:0]];

    // outstanding 请求发送时间：tag -> 发送时的仿真时间
    time                            outstanding_times[bit [9:0]];

    // BAR 地址分配器：下一个可用基地址（从 4GB 开始）
    bit [63:0]                      next_bar_addr = 64'h0000_0001_0000_0000;

    // Completion 超时检查间隔（ns）
    int                             timeout_check_interval_ns = 1000;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：在调用 super 之前强制 role=RC
    // 因为 test 层级 config_db 优先级高于 env，rc_agent 可能拿到 EP role
    // 先获取 cfg 并修正 role，再调用 super 执行实际创建
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        // 先手动获取 cfg（不调用 super）
        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "未找到 cfg")
        // 强制为 RC role
        cfg.role = XILINX_PCIE_RC;
        // 重新注册修正后的 cfg，确保 super.build_phase 和子组件拿到正确的 role
        uvm_config_db #(xilinx_pcie_env_config)::set(this, "*", "cfg", cfg);
        // 调用父类 build（会再次 get cfg，此时 role 已是 RC）
        super.build_phase(phase);
        // analysis_imp 必须在 build_phase 创建 (UVM 规定)
        rc_rx_imp = new("rc_rx_imp", this);
    endfunction : build_phase

    //=========================================================================
    // connect_phase：调用父类连接后，订阅分析端口
    //=========================================================================
    // analysis_imp 订阅 monitor.tlp_rx_ap, 触发 completion 释放 tag
    typedef uvm_analysis_imp #(pcie_tl_tlp, xilinx_pcie_rc_agent) rc_rx_imp_t;
    rc_rx_imp_t rc_rx_imp;

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (monitor != null && rc_rx_imp != null)
            monitor.tlp_rx_ap.connect(rc_rx_imp);
    endfunction : connect_phase

    // analysis_imp 回调: 所有 RX TLP 进 handle_completion (内部仅处理 cpl 类型)
    function void write(pcie_tl_tlp t);
        handle_completion(t);
    endfunction : write

    //=========================================================================
    // run_phase：启动 completion 超时检查后台任务
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        fork
            check_completion_timeout();
        join_none
    endtask : run_phase

    //=========================================================================
    // register_outstanding_req：注册 outstanding 请求
    // 由上层序列或 driver 回调在发送 Non-Posted TLP 后调用
    //=========================================================================
    function void register_outstanding_req(pcie_tl_tlp tlp);
        if (tlp.requires_completion()) begin
            outstanding_reqs[tlp.tag]  = tlp;
            outstanding_times[tlp.tag] = $time;
            // 同步到 tag_mgr
            tag_mgr.register_outstanding(tlp.tag, tlp);
            `uvm_info(get_type_name(),
                $sformatf("注册 outstanding 请求: tag=0x%03h, kind=%s",
                    tlp.tag, tlp.kind.name()),
                UVM_HIGH)
        end
    endfunction : register_outstanding_req

    //=========================================================================
    // handle_completion：处理接收到的 Completion
    // 由上层通过 monitor.tlp_rx_ap 回调触发
    //=========================================================================
    function void handle_completion(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;

        // 尝试 $cast 为 completion TLP
        if (!$cast(cpl, tlp)) return;

        // 检查是否是 completion 类型
        if (tlp.kind != TLP_CPL && tlp.kind != TLP_CPLD &&
            tlp.kind != TLP_CPL_LK && tlp.kind != TLP_CPLD_LK) return;

        // 在 outstanding map 中查找匹配的请求
        if (outstanding_reqs.exists(cpl.tag)) begin
            `uvm_info(get_type_name(),
                $sformatf("收到 Completion: tag=0x%03h, status=%s, 延迟=%0t ns",
                    cpl.tag, cpl.cpl_status.name(), $time - outstanding_times[cpl.tag]),
                UVM_MEDIUM)

            // 释放 outstanding 记录
            outstanding_reqs.delete(cpl.tag);
            outstanding_times.delete(cpl.tag);
        end else begin
            `uvm_info(get_type_name(),
                $sformatf("收到 Completion (无显式 outstanding 注册): tag=0x%03h, req_id=0x%04h",
                    cpl.tag, cpl.requester_id),
                UVM_HIGH)
        end

        // 始终释放 tag — driver 在 alloc 时未必走 register_outstanding_req 路径
        // 因此只要收到 cpl 就归还 tag, 避免 pool 泄漏
        if (tag_mgr != null)
            tag_mgr.free_tag(cpl.tag, 0);
    endfunction : handle_completion

    //=========================================================================
    // check_completion_timeout：后台任务，定期检查 outstanding 请求是否超时
    //=========================================================================
    protected task check_completion_timeout();
        forever begin
            #(timeout_check_interval_ns * 1ns);

            foreach (outstanding_times[tag]) begin
                time elapsed;
                elapsed = $time - outstanding_times[tag];

                if (elapsed > cfg.cpl_timeout_ns * 1ns) begin
                    `uvm_error(get_type_name(),
                        $sformatf("Completion 超时: tag=0x%03h, kind=%s, 已等待=%0t ns, 门限=%0d ns",
                            tag, outstanding_reqs[tag].kind.name(),
                            elapsed, cfg.cpl_timeout_ns))

                    // 清理超时请求
                    outstanding_reqs.delete(tag);
                    outstanding_times.delete(tag);
                    tag_mgr.free_tag(tag, 0);
                end
            end
        end
    endtask : check_completion_timeout

    //=========================================================================
    // allocate_bar_address：为 EP 分配 BAR 基地址
    // 返回按 size 对齐的地址，并推进 next_bar_addr
    //=========================================================================
    function bit [63:0] allocate_bar_address(int size);
        bit [63:0] aligned_addr;
        bit [63:0] size_64 = size;
        bit [63:0] mask;

        // 确保 size 是 2 的幂次（BAR 大小要求）
        if (size <= 0 || (size & (size - 1)) != 0) begin
            `uvm_error(get_type_name(),
                $sformatf("allocate_bar_address: size=%0d 非法，必须为 2 的幂次", size))
            return 64'h0;
        end

        // 按 size 对齐 next_bar_addr
        mask = size_64 - 1;
        aligned_addr = (next_bar_addr + mask) & ~mask;

        // 推进分配指针
        next_bar_addr = aligned_addr + size_64;

        `uvm_info(get_type_name(),
            $sformatf("分配 BAR 地址: base=0x%016h, size=%0d bytes",
                aligned_addr, size),
            UVM_MEDIUM)

        return aligned_addr;
    endfunction : allocate_bar_address

endclass : xilinx_pcie_rc_agent

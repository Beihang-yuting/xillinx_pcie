//=============================================================================
// Xilinx PCIe TL-Layer BFM - 统一 Agent 类（role 参数化）
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：组合 4 个 axis_agent（RQ/RC/CQ/CC）、PCIe driver、monitor
//       以及 TL 层共享组件（tag_mgr、fc_mgr、ord_eng、cfg_space），
//       形成完整的 PCIe BFM agent。
//       role 通过 cfg.role 在 build_phase 前由 env 设置，运行时不变。
//       RC 特有功能（completion 超时追踪、BAR 分配）通过 if(cfg.role==XILINX_PCIE_RC) 守护。
//       EP 特有功能（自动响应、稀疏内存、DMA）通过 if(cfg.role==XILINX_PCIE_EP) 守护。
//=============================================================================

// 内部辅助 sequence：用于在 TLP sequencer 上发送单个 pcie_tl_tlp
// agent 不能直接调用 sequencer.wait_for_grant()/send_request()，
// 必须通过 sequence 的 start_item/finish_item 协议发送
class tlp_oneshot_seq extends uvm_sequence #(pcie_tl_tlp);

    `uvm_object_utils(tlp_oneshot_seq)

    // 待发送的 TLP 事务
    pcie_tl_tlp tlp_item;

    function new(string name = "tlp_oneshot_seq");
        super.new(name);
    endfunction : new

    virtual task body();
        // 通过 sequence 的 start_item/finish_item 将 TLP 发送到 sequencer
        start_item(tlp_item);
        finish_item(tlp_item);
    endtask : body

endclass : tlp_oneshot_seq

class xilinx_pcie_agent extends uvm_agent;

    `uvm_component_utils(xilinx_pcie_agent)

    //=========================================================================
    // 单一 RX analysis imp（监听 monitor.tlp_rx_ap）
    // RC 和 EP 共用同一 imp + write()，内部按 role 分发
    //=========================================================================
    typedef uvm_analysis_imp #(pcie_tl_tlp, xilinx_pcie_agent) tlp_rx_imp_t;
    tlp_rx_imp_t tlp_rx_imp;

    //=========================================================================
    // 环境配置
    //=========================================================================

    // 环境配置对象（由 config_db 获取）
    xilinx_pcie_env_config              cfg;

    //=========================================================================
    // PCIe 驱动与监控
    //=========================================================================

    // TLP 驱动器：将 pcie_tl_tlp 编码为 AXI-Stream beat 并发送
    xilinx_pcie_driver                  driver;

    // TLP 监控器：监听 axis_monitor 输出并解码回 pcie_tl_tlp
    xilinx_pcie_monitor                 monitor;

    // TLP sequencer：上层序列通过此 sequencer 提交 TLP 事务
    uvm_sequencer #(pcie_tl_tlp)        sequencer;

    //=========================================================================
    // 编解码与路由组件
    //=========================================================================

    // tuser 编解码器（根据 DATA_WIDTH 参数化）
    xilinx_tuser_codec                  tuser_codec;

    // Straddle 组包/拆包引擎
    xilinx_straddle_engine              straddle_eng;

    // 通道路由器：根据角色和 TLP 类别确定 AXI-Stream 通道
    xilinx_pcie_channel_router          router;

    //=========================================================================
    // 4 个 AXI-Stream Agent（一个通道一个）
    //=========================================================================

    // RQ（Requester Request）通道 agent
    axis_agent_rq_t                     rq_agent;
    // RC（Requester Completion）通道 agent
    axis_agent_rc_t                     rc_agent;
    // CQ（Completer Request）通道 agent
    axis_agent_cq_t                     cq_agent;
    // CC（Completer Completion）通道 agent
    axis_agent_cc_t                     cc_agent;

    //=========================================================================
    // TL 层共享管理器
    //=========================================================================

    // Tag 管理器：分配和回收 PCIe 请求 Tag
    pcie_tl_tag_manager                 tag_mgr;

    // 流量控制管理器：跟踪和检查 FC credit
    pcie_tl_fc_manager                  fc_mgr;

    // 排序引擎：维护 PCIe TLP 排序规则
    pcie_tl_ordering_engine             ord_eng;

    // 配置空间管理器：模拟 PCI 配置空间
    pcie_tl_cfg_space_manager           cfg_space;

    //=========================================================================
    // 分析端口
    //=========================================================================

    // TLP 发送分析端口：每成功发送一个 TLP 后广播
    uvm_analysis_port #(pcie_tl_tlp)    tlp_tx_ap;

    // TLP 接收分析端口：每解码一个 TLP 后广播
    uvm_analysis_port #(pcie_tl_tlp)    tlp_rx_ap;

    //=========================================================================
    // RC 特有成员（仅 cfg.role==XILINX_PCIE_RC 时使用）
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
    // 统一内存成员（use_unified_mem=1 时使用）
    //=========================================================================

    // 本实例内存（RC=host_mem, EP=dev_mem），从 config_db 获取
    host_mem_api              mem;

    // 内存应答器实例（wire 完成后用于下一步接入 RX 路径）
    xilinx_pcie_mem_responder mem_resp;

    //=========================================================================
    // EP 特有成员（仅 cfg.role==XILINX_PCIE_EP 时使用）
    //=========================================================================

    // 稀疏内存模型：地址 -> 字节数据
    bit [7:0]                       mem_space[bit [63:0]];

    // EP 自身的 completer_id（Bus/Dev/Func），由上层配置
    bit [15:0]                      completer_id = 16'h0100;

    // Completion 发送队列（function 上下文中排入，run_phase 后台任务发送）
    pcie_tl_cpl_tlp                 cpl_send_queue[$];

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建所有子组件
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 1：从 config_db 获取环境配置并验证
        // -----------------------------------------------------------------
        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal(get_type_name(),
                "未在 config_db 中找到 xilinx_pcie_env_config，路径: cfg")
        end

        if (!cfg.validate()) begin
            `uvm_fatal(get_type_name(),
                "环境配置验证失败，请检查 xilinx_pcie_env_config 参数")
        end

        // -----------------------------------------------------------------
        // UVM config_db 优先级修正：test 层的 "env*" set 在 VCS UVM 1.2 中
        // 优先级高于 env 层的 "rc_agent*"/"ep_agent*" set（父上下文胜子上下文），
        // 导致两个 agent 都拿到同一个共享 cfg 对象。若直接修改 cfg.role 会污染
        // 另一个 agent（两者共享同一对象引用，最后运行的 build 胜出）。
        // 修正：先 clone 一份私有 cfg，再在私有副本上设置正确的 role，然后
        // 用更深的 scope ("*") 替换 config_db，供自己及子组件使用。
        // 与原 xilinx_pcie_rc_agent 的 build_phase 修正逻辑等价（行为保持不变）。
        // -----------------------------------------------------------------
        begin
            string inst = get_name();
            if (inst.substr(0, 7) == "rc_agent" || inst.substr(0, 7) == "ep_agent") begin
                xilinx_pcie_env_config priv_cfg;
                $cast(priv_cfg, cfg.clone());
                if (inst.substr(0, 7) == "rc_agent")
                    priv_cfg.role = XILINX_PCIE_RC;
                else
                    priv_cfg.role = XILINX_PCIE_EP;
                // 将私有 cfg 注册到更深的 scope，覆盖子组件配置
                uvm_config_db #(xilinx_pcie_env_config)::set(this, "*", "cfg", priv_cfg);
                // 用私有 cfg 替换 this.cfg，后续所有引用使用独立副本
                cfg = priv_cfg;
            end
        end

        // 同步 is_active 设置
        is_active = cfg.is_active;

        // 根据 role 设置 completer_id（BDF）：RC=0x0000, EP=0x0100
        // 这个字段用于：① generate_completion() 中填充 completer_id 字段
        //               ② 驱动器 own_requester_id（在 connect_phase 中传递）
        //               ③ write() 回调中识别自发 TLP
        if (cfg.role == XILINX_PCIE_RC)
            completer_id = 16'h0000;
        else
            completer_id = 16'h0100;

        // -----------------------------------------------------------------
        // 步骤 2：创建编解码器和路由器
        // -----------------------------------------------------------------
        `uvm_info(get_type_name(),
            $sformatf("DEBUG cfg.role=%s for %s", cfg.role.name(), get_full_name()), UVM_LOW)
        tuser_codec  = new(cfg.DATA_WIDTH);
        straddle_eng = new(cfg.straddle_enable, cfg.DATA_WIDTH);
        router       = new(cfg.role);

        // -----------------------------------------------------------------
        // 步骤 3：创建 4 个 AXI-Stream Agent
        // 每个通道独立创建 axis_config 并注册到 config_db
        // 四通道 axis_agent 类型不同（按 PG213 真实 TUSER 宽度参数化），
        // 无法用泛型 helper，逐通道内联 create + config 设置
        // -----------------------------------------------------------------
        begin
            axis_config acfg_rq = cfg.create_axis_config(XILINX_CH_RQ);
            uvm_config_db #(axis_config)::set(this, "rq_agent*", "cfg", acfg_rq);
            rq_agent = axis_agent_rq_t::type_id::create("rq_agent", this);
        end
        begin
            axis_config acfg_rc = cfg.create_axis_config(XILINX_CH_RC);
            uvm_config_db #(axis_config)::set(this, "rc_agent*", "cfg", acfg_rc);
            rc_agent = axis_agent_rc_t::type_id::create("rc_agent", this);
        end
        begin
            axis_config acfg_cq = cfg.create_axis_config(XILINX_CH_CQ);
            uvm_config_db #(axis_config)::set(this, "cq_agent*", "cfg", acfg_cq);
            cq_agent = axis_agent_cq_t::type_id::create("cq_agent", this);
        end
        begin
            axis_config acfg_cc = cfg.create_axis_config(XILINX_CH_CC);
            uvm_config_db #(axis_config)::set(this, "cc_agent*", "cfg", acfg_cc);
            cc_agent = axis_agent_cc_t::type_id::create("cc_agent", this);
        end

        // -----------------------------------------------------------------
        // 步骤 4：若为 ACTIVE 模式，创建 sequencer 和 driver
        // -----------------------------------------------------------------
        if (is_active == UVM_ACTIVE) begin
            sequencer = uvm_sequencer #(pcie_tl_tlp)::type_id::create("sequencer", this);
            driver    = xilinx_pcie_driver::type_id::create("driver", this);
        end

        // -----------------------------------------------------------------
        // 步骤 5：创建 monitor（无论 ACTIVE/PASSIVE 都需要）
        // -----------------------------------------------------------------
        monitor = xilinx_pcie_monitor::type_id::create("monitor", this);

        // -----------------------------------------------------------------
        // 步骤 6：创建 TL 层共享管理器
        // -----------------------------------------------------------------
        tag_mgr   = pcie_tl_tag_manager::type_id::create("tag_mgr");
        fc_mgr    = pcie_tl_fc_manager::type_id::create("fc_mgr");
        ord_eng   = pcie_tl_ordering_engine::type_id::create("ord_eng");
        cfg_space = pcie_tl_cfg_space_manager::type_id::create("cfg_space");

        // 初始化 Tag 管理器
        tag_mgr.extended_tag_enable = cfg.extended_tag_enable;
        tag_mgr.max_outstanding     = cfg.max_outstanding;
        tag_mgr.init_pool(0, cfg.extended_tag_enable, 1'b0);

        // 初始化 FC 管理器
        fc_mgr.fc_enable       = cfg.fc_enable;
        fc_mgr.infinite_credit = cfg.infinite_credit;
        fc_mgr.init_credits(
            cfg.init_ph_credit,  cfg.init_pd_credit,
            cfg.init_nph_credit, cfg.init_npd_credit,
            cfg.init_cplh_credit, cfg.init_cpld_credit
        );

        // 初始化排序引擎
        ord_eng.relaxed_ordering_enable  = cfg.relaxed_ordering_enable;
        ord_eng.id_based_ordering_enable = cfg.id_based_ordering_enable;
        ord_eng.bypass_ordering          = cfg.bypass_ordering;

        // 初始化配置空间管理器
        if (cfg.cfg_enable) begin
            cfg_space.init_type0_header(
                .vendor_id   (cfg.vendor_id),
                .device_id   (cfg.device_id),
                .class_code  (cfg.class_code)
            );
        end

        // -----------------------------------------------------------------
        // 步骤 7：创建分析端口
        // -----------------------------------------------------------------
        tlp_tx_ap = new("tlp_tx_ap", this);
        tlp_rx_ap = new("tlp_rx_ap", this);

        // -----------------------------------------------------------------
        // 步骤 8：创建单一 RX analysis imp（RC/EP 共用，write() 内部 role 分发）
        // -----------------------------------------------------------------
        tlp_rx_imp = new("tlp_rx_imp", this);

        // -----------------------------------------------------------------
        // 步骤 9：统一内存句柄获取 + mem_responder 创建（门控）
        // 仅在 use_unified_mem=1 时执行；默认 0 时完全跳过，行为无变化。
        // -----------------------------------------------------------------
        if (cfg.use_unified_mem) begin
            if (!uvm_config_db#(host_mem_api)::get(this, "", "mem", mem))
                `uvm_warning(get_type_name(), "use_unified_mem=1 但未拿到 mem 句柄")
            mem_resp = new(mem, (cfg.role == XILINX_PCIE_EP) ? 16'h0100 : 16'h0000);
        end

    endfunction : build_phase

    //=========================================================================
    // connect_phase：连接所有子组件
    //=========================================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 0：为 axis_agent 的 reset_listener 设置 dummy 事件
        // axis_agent 的 rst_listener 需要 reset_handler 的事件引用
        // 我们不使用 axis_env，所以手动创建 dummy 事件防止 null 访问
        // -----------------------------------------------------------------
        // 四通道 agent 类型不同，无法放入同一队列，逐通道分别设置
        begin
            uvm_event dummy_assert_evt  = new("dummy_reset_assert");
            uvm_event dummy_active_evt  = new("dummy_reset_active");
            uvm_event dummy_deassert_evt = new("dummy_reset_deassert");
            if (rq_agent.rst_listener != null) begin
                rq_agent.rst_listener.reset_asserted_evt   = dummy_assert_evt;
                rq_agent.rst_listener.reset_active_evt     = dummy_active_evt;
                rq_agent.rst_listener.reset_deasserted_evt = dummy_deassert_evt;
            end
            if (rc_agent.rst_listener != null) begin
                rc_agent.rst_listener.reset_asserted_evt   = dummy_assert_evt;
                rc_agent.rst_listener.reset_active_evt     = dummy_active_evt;
                rc_agent.rst_listener.reset_deasserted_evt = dummy_deassert_evt;
            end
            if (cq_agent.rst_listener != null) begin
                cq_agent.rst_listener.reset_asserted_evt   = dummy_assert_evt;
                cq_agent.rst_listener.reset_active_evt     = dummy_active_evt;
                cq_agent.rst_listener.reset_deasserted_evt = dummy_deassert_evt;
            end
            if (cc_agent.rst_listener != null) begin
                cc_agent.rst_listener.reset_asserted_evt   = dummy_assert_evt;
                cc_agent.rst_listener.reset_active_evt     = dummy_active_evt;
                cc_agent.rst_listener.reset_deasserted_evt = dummy_deassert_evt;
            end
        end

        // -----------------------------------------------------------------
        // 步骤 1：若为 ACTIVE 模式，连接 driver
        // -----------------------------------------------------------------
        if (is_active == UVM_ACTIVE) begin
            // 连接 driver 的 seq_item_port 到 sequencer
            driver.seq_item_port.connect(sequencer.seq_item_export);

            // 设置 driver 的引用：编解码器、路由器、管理器
            driver.tuser_codec       = this.tuser_codec;
            driver.straddle_eng      = this.straddle_eng;
            driver.router            = this.router;
            driver.tag_mgr           = this.tag_mgr;
            driver.fc_mgr            = this.fc_mgr;
            driver.cfg               = this.cfg;
            // 告知 driver 本 agent 的 BDF，用于在 TLP 中打上 requester_id
            driver.own_requester_id  = this.completer_id;

            // 将 4 个 axis_agent 的 sequencer 引用设置到 driver
            // 注意：axis_agent.sqr 仅在 UVM_ACTIVE 且非 MONITOR_ONLY 时创建
            if (rq_agent.sqr != null) driver.rq_sqr = rq_agent.sqr;
            if (rc_agent.sqr != null) driver.rc_sqr = rc_agent.sqr;
            if (cq_agent.sqr != null) driver.cq_sqr = cq_agent.sqr;
            if (cc_agent.sqr != null) driver.cc_sqr = cc_agent.sqr;
        end

        // -----------------------------------------------------------------
        // 步骤 2：设置 monitor 的引用
        // -----------------------------------------------------------------
        monitor.tuser_codec  = this.tuser_codec;
        monitor.straddle_eng = this.straddle_eng;
        monitor.cfg          = this.cfg;

        // -----------------------------------------------------------------
        // 步骤 3：连接 axis_monitor 的 packet_ap 到 xilinx_pcie_monitor 的 imp
        // 所有 4 个通道都连接，monitor 内部根据通道类型分别解码
        // -----------------------------------------------------------------
        rq_agent.mon.packet_ap.connect(monitor.rq_imp);
        rc_agent.mon.packet_ap.connect(monitor.rc_imp);
        cq_agent.mon.packet_ap.connect(monitor.cq_imp);
        cc_agent.mon.packet_ap.connect(monitor.cc_imp);

        // -----------------------------------------------------------------
        // 步骤 4：连接分析端口到 agent 级别
        // -----------------------------------------------------------------
        monitor.tlp_rx_ap.connect(this.tlp_rx_ap);

        if (is_active == UVM_ACTIVE && driver != null) begin
            driver.tlp_tx_ap.connect(this.tlp_tx_ap);
        end

        // -----------------------------------------------------------------
        // 步骤 5：将 monitor.tlp_rx_ap 连接到统一 tlp_rx_imp
        // RC role：write() 调用 handle_completion 释放 tag / outstanding
        // EP role：write() 调用 handle_rx_tlp 处理请求并自动响应
        // -----------------------------------------------------------------
        monitor.tlp_rx_ap.connect(tlp_rx_imp);

    endfunction : connect_phase

    //=========================================================================
    // write：统一 RX analysis imp 回调，按 role 分发
    // RC：处理 completion（outstanding 释放 + tag free）
    // EP：处理请求（自动响应 MRd/MWr/IO/Cfg）；DMA completion 也在此释放 tag
    // 统一内存路径（use_unified_mem=1）：访存请求经 mem_resp 应答；
    //   EP 仍先走 handle_rx_tlp 处理 Cfg/IO 类型；mem_resp 仅处理 MRd/MWr/Atomic
    //=========================================================================
    function void write(pcie_tl_tlp t);
        if (t.kind inside {TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK}) begin
            // Completion 包 —— UNCHANGED
            if (cfg.role == XILINX_PCIE_RC) begin
                handle_completion(t);
            end else if (cfg.role == XILINX_PCIE_EP) begin
                // EP DMA 完成释放 tag（等同于 ep_agent 原 TLP_CPL* case 逻辑）
                pcie_tl_cpl_tlp cpl_in;
                if ($cast(cpl_in, t) && tag_mgr != null) begin
                    tag_mgr.free_tag(cpl_in.tag, 0);
                    `uvm_info(get_type_name(),
                        $sformatf("EP 释放 DMA tag=0x%03h (cpl 已收到)", cpl_in.tag),
                        UVM_HIGH)
                end
            end
        end else begin
            // 非 Completion 包（请求类）
            if (cfg.use_unified_mem) begin
                // 过滤：跳过本 agent 自发的 TLP
                // requester_id==completer_id 说明是本 agent 从自己 sequencer 发出的 TLP，
                // 回环 monitor 让发送方也能看到自己的 TLP，不能响应自己。
                if (t.requester_id == this.completer_id) begin
                    `uvm_info(get_type_name(),
                        $sformatf("write() 跳过自发 TLP: kind=%s req_id=0x%04h",
                            t.kind.name(), t.requester_id),
                        UVM_HIGH)
                end
                // EP 仍先处理 Cfg/IO（不在 mem_resp 管辖）
                else if (cfg.role == XILINX_PCIE_EP &&
                    t.kind inside {TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1,
                                   TLP_IO_RD, TLP_IO_WR}) begin
                    `uvm_info(get_type_name(),
                        $sformatf("write() Cfg/IO: kind=%s, tag=0x%03h, payload=%0d bytes",
                            t.kind.name(), t.tag, t.payload.size()),
                        UVM_MEDIUM)
                    handle_rx_tlp(t);
                end else if (mem_resp != null) begin
                    pcie_tl_cpl_tlp cpl;
                    `uvm_info(get_type_name(),
                        $sformatf("write() mem_resp: kind=%s, tag=0x%03h, payload=%0d bytes",
                            t.kind.name(), t.tag, t.payload.size()),
                        UVM_MEDIUM)
                    cpl = mem_resp.handle_mem_request(t); // MWr→null；MRd/MRdLk/Atomic→CplD
                    if (cpl != null) send_completion(cpl);
                end
            end else begin
                // use_unified_mem=0：原稀疏内存路径（不变）
                if (cfg.role == XILINX_PCIE_EP) begin
                    `uvm_info(get_type_name(),
                        $sformatf("write() 回调: kind=%s, tag=0x%03h, payload=%0d bytes",
                            t.kind.name(), t.tag, t.payload.size()),
                        UVM_MEDIUM)
                    handle_rx_tlp(t);
                end
            end
        end
    endfunction : write

    //=========================================================================
    // run_phase：按 role 启动后台任务
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        if (cfg.role == XILINX_PCIE_RC) begin
            fork
                check_completion_timeout();
            join_none
        end
        // EP 自动响应队列（传统路径）
        if (cfg.role == XILINX_PCIE_EP) begin
            if (is_active == UVM_ACTIVE && cfg.ep_auto_response) begin
                fork
                    process_cpl_send_queue();
                join_none
            end
        end
        // 统一内存路径：use_unified_mem=1 时 RC/EP 都可能向 cpl_send_queue 推入
        // completion（mem_resp 应答访存请求）；若队列处理器尚未启动则在此启动
        if (cfg.use_unified_mem && is_active == UVM_ACTIVE) begin
            // EP 且 ep_auto_response=1 时上面已经 fork 了，避免重复 fork
            if (!(cfg.role == XILINX_PCIE_EP && cfg.ep_auto_response)) begin
                fork
                    process_cpl_send_queue();
                join_none
            end
        end
    endtask : run_phase

    //==========================================================================
    // ===== RC 特有方法（仅在 cfg.role==XILINX_PCIE_RC 时有意义）=====
    //==========================================================================

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
    // 由 write() 在 RC role 下触发
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

    //==========================================================================
    // ===== EP 特有方法（仅在 cfg.role==XILINX_PCIE_EP 时有意义）=====
    //==========================================================================

    //=========================================================================
    // handle_rx_tlp：处理接收到的 TLP（由 write() 在 EP role 下调用）
    // 仅当 cfg.ep_auto_response == 1 时启用自动响应
    //=========================================================================
    function void handle_rx_tlp(pcie_tl_tlp tlp);
        if (!cfg.ep_auto_response) return;

        case (tlp.kind)
            // -----------------------------------------------------------------
            // MWr：内存写请求 -> 写入 mem_space，无回复
            // -----------------------------------------------------------------
            TLP_MEM_WR: begin
                pcie_tl_mem_tlp mem_tlp;
                if ($cast(mem_tlp, tlp)) begin
                    mem_write(mem_tlp.addr, mem_tlp.payload,
                              mem_tlp.first_be, mem_tlp.last_be);
                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 MWr: addr=0x%016h, len=%0d bytes",
                            mem_tlp.addr, mem_tlp.payload.size()),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // MRd：内存读请求 -> 从 mem_space 读取，生成 CplD
            // -----------------------------------------------------------------
            TLP_MEM_RD, TLP_MEM_RD_LK: begin
                pcie_tl_mem_tlp mem_tlp;
                if ($cast(mem_tlp, tlp)) begin
                    bit [7:0] data[];
                    int byte_count;
                    pcie_tl_cpl_tlp cpl;

                    // 计算读取字节数：length 字段以 DW 为单位，0 表示 1024 DW
                    byte_count = (tlp.length == 0) ? 4096 : tlp.length * 4;
                    mem_read(mem_tlp.addr, byte_count, data);

                    // 生成 CplD 响应
                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 MRd: addr=0x%016h, len=%0d bytes -> CplD",
                            mem_tlp.addr, byte_count),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // IORd：IO 读请求 -> 从 mem_space 读取，生成 CplD（单 DW）
            // -----------------------------------------------------------------
            TLP_IO_RD: begin
                pcie_tl_io_tlp io_tlp;
                if ($cast(io_tlp, tlp)) begin
                    bit [7:0] data[];
                    pcie_tl_cpl_tlp cpl;

                    mem_read({32'h0, io_tlp.addr}, 4, data);
                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 IORd: addr=0x%08h -> CplD",
                            io_tlp.addr),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // IOWr：IO 写请求 -> 写入 mem_space，生成 Cpl（无数据）
            // -----------------------------------------------------------------
            TLP_IO_WR: begin
                pcie_tl_io_tlp io_tlp;
                if ($cast(io_tlp, tlp)) begin
                    bit [7:0] empty_data[];
                    pcie_tl_cpl_tlp cpl;

                    mem_write({32'h0, io_tlp.addr}, io_tlp.payload,
                              io_tlp.first_be, 4'h0);

                    // IO 写回 Cpl（无数据）
                    empty_data = new[0];
                    cpl = generate_completion(tlp, empty_data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 IOWr: addr=0x%08h -> Cpl",
                            io_tlp.addr),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // CfgRd：配置读请求 -> 读 cfg_space_manager，生成 CplD
            // -----------------------------------------------------------------
            TLP_CFG_RD0, TLP_CFG_RD1: begin
                pcie_tl_cfg_tlp cfg_tlp;
                if ($cast(cfg_tlp, tlp)) begin
                    bit [31:0] cfg_data;
                    bit [7:0] data[];
                    pcie_tl_cpl_tlp cpl;

                    // 从配置空间读取一个 DW
                    cfg_data = cfg_space.read({cfg_tlp.reg_num, 2'b00});

                    // 转为字节数组
                    data = new[4];
                    data[0] = cfg_data[7:0];
                    data[1] = cfg_data[15:8];
                    data[2] = cfg_data[23:16];
                    data[3] = cfg_data[31:24];

                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 CfgRd: reg=0x%03h -> CplD, data=0x%08h",
                            cfg_tlp.reg_num, cfg_data),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // CfgWr：配置写请求 -> 写 cfg_space_manager，生成 Cpl
            // -----------------------------------------------------------------
            TLP_CFG_WR0, TLP_CFG_WR1: begin
                pcie_tl_cfg_tlp cfg_tlp;
                if ($cast(cfg_tlp, tlp)) begin
                    bit [31:0] wr_data;
                    bit [7:0] empty_data[];
                    pcie_tl_cpl_tlp cpl;

                    // 从 payload 提取写入数据（最多 1 DW = 4 bytes）
                    wr_data = 32'h0;
                    if (tlp.payload.size() >= 1) wr_data[7:0]   = tlp.payload[0];
                    if (tlp.payload.size() >= 2) wr_data[15:8]  = tlp.payload[1];
                    if (tlp.payload.size() >= 3) wr_data[23:16] = tlp.payload[2];
                    if (tlp.payload.size() >= 4) wr_data[31:24] = tlp.payload[3];

                    // 写入配置空间
                    cfg_space.write({cfg_tlp.reg_num, 2'b00}, wr_data, cfg_tlp.first_be);

                    // Cfg 写回 Cpl（无数据）
                    empty_data = new[0];
                    cpl = generate_completion(tlp, empty_data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 CfgWr: reg=0x%03h, data=0x%08h -> Cpl",
                            cfg_tlp.reg_num, wr_data),
                        UVM_HIGH)
                end
            end

            default: begin
                `uvm_info(get_type_name(),
                    $sformatf("自动响应：忽略未处理的 TLP 类型 %s",
                        tlp.kind.name()),
                    UVM_HIGH)
            end
        endcase
    endfunction : handle_rx_tlp

    //=========================================================================
    // mem_write：写入稀疏内存模型
    // 根据 first_be 和 last_be 控制有效字节
    //=========================================================================
    function void mem_write(
        bit [63:0]  addr,
        bit [7:0]   data[],
        bit [3:0]   first_be,
        bit [3:0]   last_be
    );
        int data_idx;
        int total_dw;

        if (data.size() == 0) return;

        data_idx = 0;
        total_dw = (data.size() + 3) / 4;

        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be;

            // 确定当前 DW 的字节使能
            if (dw == 0)
                be = first_be;
            else if (dw == total_dw - 1 && total_dw > 1)
                be = last_be;
            else
                be = 4'hF;

            // 按字节使能写入内存
            for (int b = 0; b < 4; b++) begin
                if (data_idx < data.size()) begin
                    if (be[b]) begin
                        mem_space[addr + data_idx] = data[data_idx];
                    end
                    data_idx++;
                end
            end
        end
    endfunction : mem_write

    //=========================================================================
    // mem_read：从稀疏内存模型读取
    // 返回指定长度的字节数组，未初始化地址返回 0
    //=========================================================================
    function void mem_read(
        bit [63:0]  addr,
        int         length,
        output bit [7:0] data[]
    );
        data = new[length];
        for (int i = 0; i < length; i++) begin
            if (mem_space.exists(addr + i))
                data[i] = mem_space[addr + i];
            else
                data[i] = 8'h00;
        end
    endfunction : mem_read

    //=========================================================================
    // generate_completion：根据请求生成 Completion TLP
    // 填充 completer_id、requester_id、tag、lower_addr、byte_count 等
    //=========================================================================
    function pcie_tl_cpl_tlp generate_completion(
        pcie_tl_tlp     req,
        bit [7:0]       data[],
        cpl_status_e    status
    );
        pcie_tl_cpl_tlp cpl;
        cpl = pcie_tl_cpl_tlp::type_id::create("cpl");

        // 设置 Completion 类型：有数据为 CplD，无数据为 Cpl
        if (data.size() > 0) begin
            cpl.kind   = TLP_CPLD;
            cpl.fmt    = FMT_3DW_WITH_DATA;
            cpl.type_f = TLP_TYPE_CPL;
        end else begin
            cpl.kind   = TLP_CPL;
            cpl.fmt    = FMT_3DW_NO_DATA;
            cpl.type_f = TLP_TYPE_CPL;
        end

        // 填充 ID 字段
        cpl.completer_id = this.completer_id;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;

        // 填充 Completion 状态
        cpl.cpl_status = status;
        cpl.bcm        = 1'b0;

        // 计算 byte_count（响应数据总字节数）
        cpl.byte_count = data.size();

        // 计算 lower_addr（基于请求地址低 7 位）
        begin
            pcie_tl_mem_tlp mem_req;
            pcie_tl_io_tlp  io_req;
            pcie_tl_cfg_tlp cfg_req;

            if ($cast(mem_req, req))
                cpl.lower_addr = mem_req.addr[6:0];
            else if ($cast(io_req, req))
                cpl.lower_addr = io_req.addr[6:0];
            else if ($cast(cfg_req, req))
                cpl.lower_addr = {cfg_req.reg_num[4:0], 2'b00};
            else
                cpl.lower_addr = 7'h0;
        end

        // 填充 TLP 通用字段
        cpl.tc        = req.tc;
        cpl.attr      = req.attr;
        cpl.td        = 1'b0;
        cpl.ep_bit    = 1'b0;
        cpl.th        = 1'b0;

        // 计算 length（以 DW 为单位）
        if (data.size() > 0)
            cpl.length = (data.size() + 3) / 4;
        else
            cpl.length = 10'h0;

        // 复制 payload
        cpl.payload = data;

        return cpl;
    endfunction : generate_completion

    //=========================================================================
    // send_completion：将 Completion 排入发送队列
    // 由于 function 上下文中无法调用 task（sequencer 交互），
    // 实际发送由 run_phase 中的 process_cpl_send_queue 后台任务处理
    //=========================================================================
    function void send_completion(pcie_tl_cpl_tlp cpl);
        if (is_active == UVM_ACTIVE) begin
            cpl_send_queue.push_back(cpl);
            // 调试：记录 completion 入队，跟踪队列深度
            `uvm_info(get_type_name(),
                $sformatf("send_completion: tag=0x%03h 入队, 队列深度=%0d",
                    cpl.tag, cpl_send_queue.size()),
                UVM_MEDIUM)
        end else begin
            `uvm_warning(get_type_name(),
                "agent 处于 PASSIVE 模式，无法发送 Completion")
        end
    endfunction : send_completion

    //=========================================================================
    // process_cpl_send_queue：后台任务，从队列中取出 Completion 并发送
    //=========================================================================
    protected task process_cpl_send_queue();
        forever begin
            pcie_tl_cpl_tlp cpl;

            // 等待队列非空
            wait (cpl_send_queue.size() > 0);

            cpl = cpl_send_queue.pop_front();

            // 可选延迟（模拟 EP 处理时间）
            if (cfg.response_delay_max > 0) begin
                int delay;
                delay = $urandom_range(cfg.response_delay_min, cfg.response_delay_max);
                if (delay > 0) begin
                    // 使用 #delay 简化，避免依赖 tb_top 时钟
                    #(delay * 1ns);
                end
            end

            // 通过 one-shot sequence 在 sequencer 上发送 Completion
            // 注意：不使用 clone()，因为 pcie_tl_cpl_tlp 未实现 do_copy()，
            // clone 会丢失所有字段值（kind 回退到默认 TLP_MEM_RD）。
            // cpl 已从队列 pop 出来，可直接使用，无需克隆。
            begin
                tlp_oneshot_seq oneshot;
                oneshot = tlp_oneshot_seq::type_id::create("cpl_oneshot");
                oneshot.tlp_item = cpl;
                oneshot.start(sequencer);
            end

            `uvm_info(get_type_name(),
                $sformatf("已发送 Completion: tag=0x%03h, kind=%s, payload=%0d bytes",
                    cpl.tag, cpl.kind.name(), cpl.payload.size()),
                UVM_MEDIUM)
        end
    endtask : process_cpl_send_queue

    //=========================================================================
    // initiate_dma：发起 DMA 请求（通过 sequencer 发送 MRd/MWr TLP）
    //=========================================================================
    task initiate_dma(bit [63:0] addr, int size, bit is_read);
        pcie_tl_mem_tlp dma_tlp;

        if (is_active != UVM_ACTIVE) begin
            `uvm_error(get_type_name(),
                "initiate_dma: EP agent 处于 PASSIVE 模式，无法发起 DMA")
            return;
        end

        dma_tlp = pcie_tl_mem_tlp::type_id::create("dma_tlp");

        // 设置 TLP 基本字段
        if (is_read) begin
            dma_tlp.kind     = TLP_MEM_RD;
            dma_tlp.fmt      = (addr > 64'hFFFF_FFFF) ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
            dma_tlp.payload  = new[0];
        end else begin
            dma_tlp.kind     = TLP_MEM_WR;
            dma_tlp.fmt      = (addr > 64'hFFFF_FFFF) ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
            // 填充 payload（用递增模式）
            dma_tlp.payload = new[size];
            for (int i = 0; i < size; i++)
                dma_tlp.payload[i] = i[7:0];
        end

        dma_tlp.type_f       = TLP_TYPE_MEM_RD;
        dma_tlp.addr         = addr;
        dma_tlp.is_64bit     = (addr > 64'hFFFF_FFFF);
        dma_tlp.requester_id = this.completer_id;
        dma_tlp.length       = (size + 3) / 4;  // DW 为单位
        dma_tlp.first_be     = 4'hF;
        dma_tlp.last_be      = (dma_tlp.length > 1) ? 4'hF : 4'h0;
        dma_tlp.tc           = 3'h0;
        dma_tlp.attr         = 3'h0;
        dma_tlp.td           = 1'b0;
        dma_tlp.ep_bit       = 1'b0;
        dma_tlp.tag          = 10'h0;  // 由 driver 的 tag_mgr 自动分配

        // 通过 one-shot sequence 在 sequencer 上发送 DMA TLP
        // （不能直接调用 sequencer 的低级 API）
        begin
            tlp_oneshot_seq oneshot;
            oneshot = tlp_oneshot_seq::type_id::create("dma_oneshot");
            oneshot.tlp_item = dma_tlp;
            oneshot.start(sequencer);
        end

        `uvm_info(get_type_name(),
            $sformatf("DMA %s 已发起: addr=0x%016h, size=%0d bytes",
                is_read ? "读" : "写", addr, size),
            UVM_MEDIUM)
    endtask : initiate_dma

endclass : xilinx_pcie_agent

//=============================================================================
// Xilinx PCIe TL-Layer BFM - 基础 Agent 类
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：组合 4 个 axis_agent（RQ/RC/CQ/CC）、PCIe driver、monitor
//       以及 TL 层共享组件（tag_mgr、fc_mgr、ord_eng、cfg_space），
//       形成完整的 PCIe BFM agent。
//
// 子类：xilinx_pcie_rc_agent（RC 特化）、xilinx_pcie_ep_agent（EP 特化）
//=============================================================================

class xilinx_pcie_base_agent extends uvm_agent;

    `uvm_component_utils(xilinx_pcie_base_agent)

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
    axis_agent                          rq_agent;
    // RC（Requester Completion）通道 agent
    axis_agent                          rc_agent;
    // CQ（Completer Request）通道 agent
    axis_agent                          cq_agent;
    // CC（Completer Completion）通道 agent
    axis_agent                          cc_agent;

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

        // 同步 is_active 设置
        is_active = cfg.is_active;

        // -----------------------------------------------------------------
        // 步骤 2：创建编解码器和路由器
        // -----------------------------------------------------------------
        tuser_codec  = new(cfg.DATA_WIDTH);
        straddle_eng = new(cfg.straddle_enable, cfg.DATA_WIDTH);
        router       = new(cfg.role);

        // -----------------------------------------------------------------
        // 步骤 3：创建 4 个 AXI-Stream Agent
        // 每个通道独立创建 axis_config 并注册到 config_db
        // -----------------------------------------------------------------
        create_axis_agent("rq", XILINX_CH_RQ, rq_agent);
        create_axis_agent("rc", XILINX_CH_RC, rc_agent);
        create_axis_agent("cq", XILINX_CH_CQ, cq_agent);
        create_axis_agent("cc", XILINX_CH_CC, cc_agent);

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

    endfunction : build_phase

    //=========================================================================
    // connect_phase：连接所有子组件
    //=========================================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 1：若为 ACTIVE 模式，连接 driver
        // -----------------------------------------------------------------
        if (is_active == UVM_ACTIVE) begin
            // 连接 driver 的 seq_item_port 到 sequencer
            driver.seq_item_port.connect(sequencer.seq_item_export);

            // 设置 driver 的引用：编解码器、路由器、管理器
            driver.tuser_codec  = this.tuser_codec;
            driver.straddle_eng = this.straddle_eng;
            driver.router       = this.router;
            driver.tag_mgr      = this.tag_mgr;
            driver.fc_mgr       = this.fc_mgr;
            driver.cfg          = this.cfg;

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

    endfunction : connect_phase

    //=========================================================================
    // 辅助方法：创建单个 axis_agent 及其配置
    //=========================================================================
    protected function void create_axis_agent(
        string              name,
        xilinx_channel_e    ch,
        ref axis_agent      agt
    );
        axis_config acfg;

        // 创建 axis_config（根据角色、通道、带宽参数）
        acfg = cfg.create_axis_config(ch);

        // 注册到 config_db，让 axis_agent 的 build_phase 能获取
        uvm_config_db #(axis_config)::set(
            this, $sformatf("%s_agent*", name), "cfg", acfg);

        // 创建 axis_agent 实例
        agt = axis_agent::type_id::create($sformatf("%s_agent", name), this);
    endfunction : create_axis_agent

endclass : xilinx_pcie_base_agent

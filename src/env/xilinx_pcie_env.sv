//=============================================================================
// Xilinx PCIe TL-Layer BFM - 顶层环境
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：组装完整的 PCIe BFM 验证环境：
//   - RC Agent：Root Complex 侧 agent（发送请求、接收 Completion）
//   - EP Agent：Endpoint 侧 agent（接收请求、自动响应、DMA 发起）
//   - Virtual Sequencer：聚合 RC/EP sequencer，供顶层虚拟序列使用
//   - Scoreboard：4 路 TLP 流量检查（Completion 匹配、数据完整性等）
//   - Coverage：6 个 covergroup 采样 TLP 功能覆盖率
//
// 注意：env 为 RC 和 EP 各创建一份 config（role 不同），分别注册到
//       config_db，供各自 agent 的 build_phase 获取。
//=============================================================================

class xilinx_pcie_env extends uvm_env;

    `uvm_component_utils(xilinx_pcie_env)

    //=========================================================================
    // 环境配置
    //=========================================================================

    // 主环境配置对象（由 test 层创建并传入）
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 统一内存句柄（use_unified_mem=1 时从 config_db 获取，默认不使用）
    //=========================================================================
    host_mem_api host_mem;
    host_mem_api dev_mem;

    //=========================================================================
    // 子组件
    //=========================================================================

    // RC Agent：Root Complex role agent（role 由 cfg.role=XILINX_PCIE_RC 设置）
    xilinx_pcie_agent                   rc_agent;

    // EP Agent：Endpoint role agent（role 由 cfg.role=XILINX_PCIE_EP 设置）
    xilinx_pcie_agent                   ep_agent;

    // RC 侧中断 Agent（cfg_interrupt 驱动/监控）
    xilinx_pcie_interrupt_agent         rc_int_agent;

    // EP 侧中断 Agent（cfg_interrupt 驱动/监控）
    xilinx_pcie_interrupt_agent         ep_int_agent;

    // 虚拟 Sequencer：聚合 RC/EP sequencer
    xilinx_pcie_virtual_sequencer       v_sqr;

    // Scoreboard：TLP 流量检查
    xilinx_pcie_scoreboard              scb;

    // Coverage：功能覆盖率收集
    xilinx_pcie_coverage                cov;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建和配置所有子组件
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        xilinx_pcie_env_config rc_cfg;
        xilinx_pcie_env_config ep_cfg;

        super.build_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 1：从 config_db 获取或创建主配置对象
        // -----------------------------------------------------------------
        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info(get_type_name(),
                "未在 config_db 中找到 cfg，创建默认配置", UVM_MEDIUM)
            cfg = xilinx_pcie_env_config::type_id::create("cfg");
        end

        // 验证配置合法性
        if (!cfg.validate()) begin
            `uvm_fatal(get_type_name(),
                "环境配置验证失败，请检查 xilinx_pcie_env_config 参数")
        end

        // -----------------------------------------------------------------
        // 步骤 2：为 RC agent 创建专用配置（clone + 设置 role = RC）
        // -----------------------------------------------------------------
        $cast(rc_cfg, cfg.clone());
        rc_cfg.set_name("rc_cfg");
        rc_cfg.role = XILINX_PCIE_RC;

        // 注册到 config_db，供 RC agent 的 build_phase 获取
        uvm_config_db #(xilinx_pcie_env_config)::set(
            this, "rc_agent*", "cfg", rc_cfg);

        // -----------------------------------------------------------------
        // 步骤 3：为 EP agent 创建专用配置（clone + 设置 role = EP）
        // -----------------------------------------------------------------
        $cast(ep_cfg, cfg.clone());
        ep_cfg.set_name("ep_cfg");
        ep_cfg.role = XILINX_PCIE_EP;

        // 注册到 config_db，供 EP agent 的 build_phase 获取
        uvm_config_db #(xilinx_pcie_env_config)::set(
            this, "ep_agent*", "cfg", ep_cfg);

        // -----------------------------------------------------------------
        // 步骤 3b：统一内存初始化（门控，use_unified_mem=0 时完全跳过）
        // 从 tb_top 通过 config_db 获取 host_mem_manager（以 host_mem_api 传入）
        // 初始化内存区域并向 rc_agent*/ep_agent* 注入各自的 mem 句柄
        // -----------------------------------------------------------------
        if (cfg.use_unified_mem) begin
            if (!uvm_config_db#(host_mem_api)::get(this, "", "host_mem", host_mem))
                `uvm_fatal(get_type_name(), "use_unified_mem=1 但未从 tb 拿到 host_mem")
            if (!uvm_config_db#(host_mem_api)::get(this, "", "dev_mem", dev_mem))
                `uvm_fatal(get_type_name(), "use_unified_mem=1 但未从 tb 拿到 dev_mem")
            host_mem.init_region(64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
            dev_mem.init_region (64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
            if (cfg.mem_access_mode == XILINX_MEM_PREMAP) begin
                void'(host_mem.alloc(cfg.premap_size, cfg.mem_granule));
                void'(dev_mem.alloc (cfg.premap_size, cfg.mem_granule));
            end
            uvm_config_db#(host_mem_api)::set(this, "rc_agent*", "mem", host_mem);
            uvm_config_db#(host_mem_api)::set(this, "ep_agent*", "mem", dev_mem);
        end

        // -----------------------------------------------------------------
        // 步骤 4：创建 RC 和 EP agent
        // -----------------------------------------------------------------
        rc_agent = xilinx_pcie_agent::type_id::create("rc_agent", this);
        ep_agent = xilinx_pcie_agent::type_id::create("ep_agent", this);

        // -----------------------------------------------------------------
        // 步骤 4b：若中断使能，创建 RC/EP 侧中断 Agent
        // 实例名必须与 tb_top 中 config_db 注册的路径匹配：
        //   uvm_test_top.env.rc_int_agent*  / ep_int_agent*
        // 同时将 int_agent 引用注册到 config_db，供 msi_seq 的 body() 获取
        // -----------------------------------------------------------------
        if (cfg.interrupt_enable) begin
            // 创建 RC 侧中断 agent
            rc_int_agent = xilinx_pcie_interrupt_agent::type_id::create(
                "rc_int_agent", this);

            // 创建 EP 侧中断 agent
            ep_int_agent = xilinx_pcie_interrupt_agent::type_id::create(
                "ep_int_agent", this);

            // 将 ep_int_agent 注册到 config_db，key="int_agent"
            // 路径使用通配符 "*"，使 msi_seq 从任意 sequencer 上下文都能获取
            uvm_config_db #(xilinx_pcie_interrupt_agent)::set(
                this, "*", "int_agent", ep_int_agent);
        end

        // -----------------------------------------------------------------
        // 步骤 5：创建 Virtual Sequencer（始终创建）
        // -----------------------------------------------------------------
        v_sqr = xilinx_pcie_virtual_sequencer::type_id::create("v_sqr", this);

        // -----------------------------------------------------------------
        // 步骤 6：按使能开关创建 Scoreboard
        // -----------------------------------------------------------------
        if (cfg.scb_enable) begin
            scb = xilinx_pcie_scoreboard::type_id::create("scb", this);
        end

        // -----------------------------------------------------------------
        // 步骤 7：按使能开关创建 Coverage
        // -----------------------------------------------------------------
        if (cfg.cov_enable) begin
            cov = xilinx_pcie_coverage::type_id::create("cov", this);
        end

    endfunction : build_phase

    //=========================================================================
    // connect_phase：连接所有子组件
    //=========================================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 1：设置 Virtual Sequencer 的引用
        // -----------------------------------------------------------------
        v_sqr.cfg     = this.cfg;
        v_sqr.tag_mgr = rc_agent.tag_mgr;
        v_sqr.fc_mgr  = rc_agent.fc_mgr;
        v_sqr.ord_eng = rc_agent.ord_eng;

        // 连接 RC/EP sequencer 引用
        if (rc_agent.sequencer != null)
            v_sqr.rc_sqr = rc_agent.sequencer;
        if (ep_agent.sequencer != null)
            v_sqr.ep_sqr = ep_agent.sequencer;

        // 统一内存句柄透传到 virtual sequencer（门控）
        if (cfg.use_unified_mem) begin
            v_sqr.host_mem = host_mem;
            v_sqr.dev_mem  = dev_mem;
        end

        // -----------------------------------------------------------------
        // 步骤 2：连接 Scoreboard（若使能）
        // -----------------------------------------------------------------
        if (scb != null) begin
            // 设置 scoreboard 配置
            scb.cfg = this.cfg;

            // RC agent 的 TX/RX 分析端口连接到 scoreboard
            rc_agent.tlp_tx_ap.connect(scb.rc_tx_imp);
            rc_agent.tlp_rx_ap.connect(scb.rc_rx_imp);

            // EP agent 的 TX/RX 分析端口连接到 scoreboard
            ep_agent.tlp_tx_ap.connect(scb.ep_tx_imp);
            ep_agent.tlp_rx_ap.connect(scb.ep_rx_imp);
        end

        // -----------------------------------------------------------------
        // 步骤 3：连接 Coverage subscriber（若使能）
        // -----------------------------------------------------------------
        if (cov != null) begin
            // 设置 coverage 配置
            cov.cfg = this.cfg;

            // 连接所有 4 路 TLP 分析端口到 coverage
            // RC 侧的 TX 和 RX
            rc_agent.tlp_tx_ap.connect(cov.analysis_export);
            rc_agent.tlp_rx_ap.connect(cov.analysis_export);

            // EP 侧的 TX 和 RX
            ep_agent.tlp_tx_ap.connect(cov.analysis_export);
            ep_agent.tlp_rx_ap.connect(cov.analysis_export);
        end

    endfunction : connect_phase

endclass : xilinx_pcie_env

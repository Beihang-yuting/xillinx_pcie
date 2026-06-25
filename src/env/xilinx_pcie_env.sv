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

    // RC/EP Agent 数组（按 cfg.num_rc / cfg.num_ep 例化）
    xilinx_pcie_agent rc_agents[$];
    xilinx_pcie_agent ep_agents[$];
    xilinx_pcie_agent rc_agent;   // 别名 = rc_agents[0]
    xilinx_pcie_agent ep_agent;   // 别名 = ep_agents[0]

    // RC/EP 侧中断 Agent 数组（按 cfg.num_rc / cfg.num_ep 例化）
    xilinx_pcie_interrupt_agent         rc_int_agents[$];
    xilinx_pcie_interrupt_agent         ep_int_agents[$];

    // 虚拟 Sequencer：聚合 RC/EP sequencer
    xilinx_pcie_virtual_sequencer       v_sqr;

    // Scoreboard（重构为协议/错误收集器）
    xilinx_pcie_scoreboard              scb;

    // 每 agent collector tap（RC + EP，各一个；build_phase 创建，connect_phase 连接）
    xilinx_pcie_collector_tap           taps[$];

    // 每 agent error tap（RC + EP，各一个；转发 monitor 本地协议错误到 collector.record_error）
    xilinx_pcie_error_tap               err_taps[$];

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
        // 步骤 2：为每个 RC agent 创建专用配置（clone + 设置 role = RC）
        // -----------------------------------------------------------------
        for (int i = 0; i < cfg.num_rc; i++) begin
            xilinx_pcie_env_config c;
            $cast(c, cfg.clone());
            c.set_name($sformatf("rc_cfg_%0d", i));
            c.role = XILINX_PCIE_RC;
            uvm_config_db #(xilinx_pcie_env_config)::set(
                this, $sformatf("rc_agent_%0d*", i), "cfg", c);
        end

        // -----------------------------------------------------------------
        // 步骤 3：为每个 EP agent 创建专用配置（clone + 设置 role = EP）
        // -----------------------------------------------------------------
        for (int i = 0; i < cfg.num_ep; i++) begin
            xilinx_pcie_env_config c;
            $cast(c, cfg.clone());
            c.set_name($sformatf("ep_cfg_%0d", i));
            c.role = XILINX_PCIE_EP;
            uvm_config_db #(xilinx_pcie_env_config)::set(
                this, $sformatf("ep_agent_%0d*", i), "cfg", c);
        end

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
            for (int i = 0; i < cfg.num_rc; i++)
                uvm_config_db#(host_mem_api)::set(this, $sformatf("rc_agent_%0d*", i), "mem", host_mem);
            for (int i = 0; i < cfg.num_ep; i++)
                uvm_config_db#(host_mem_api)::set(this, $sformatf("ep_agent_%0d*", i), "mem", dev_mem);
        end

        // -----------------------------------------------------------------
        // 步骤 4：创建 RC 和 EP agent（按 num_rc/num_ep 例化为数组）
        // -----------------------------------------------------------------
        for (int i = 0; i < cfg.num_rc; i++) begin
            xilinx_pcie_agent a;
            a = xilinx_pcie_agent::type_id::create($sformatf("rc_agent_%0d", i), this);
            rc_agents.push_back(a);
        end
        for (int i = 0; i < cfg.num_ep; i++) begin
            xilinx_pcie_agent a;
            a = xilinx_pcie_agent::type_id::create($sformatf("ep_agent_%0d", i), this);
            ep_agents.push_back(a);
        end
        // 别名指向 [0]，保持 connect_phase / 旧代码引用兼容
        if (rc_agents.size() > 0) rc_agent = rc_agents[0];
        if (ep_agents.size() > 0) ep_agent = ep_agents[0];

        // -----------------------------------------------------------------
        // 步骤 4b：若中断使能，创建 RC/EP 侧中断 Agent
        // 实例名必须与 tb_top 中 config_db 注册的路径匹配：
        //   uvm_test_top.env.rc_int_agent*  / ep_int_agent*
        // 同时将 int_agent 引用注册到 config_db，供 msi_seq 的 body() 获取
        // -----------------------------------------------------------------
        if (cfg.interrupt_enable) begin
            // 按 num_rc/num_ep 例化为数组；实例名 rc_int_agent_%0d / ep_int_agent_%0d
            // 与连接宏在 config_db 注册的索引路径（rc_int_agent_0* 等）匹配
            // 同时为每个 int agent 注册其 env_config（key="env_config"，与 int agent
            // connect_phase 的 get 匹配），否则 cfg 为 null 退化为 Legacy 模式。
            // 用 per-role 克隆：int driver 依据 cfg.role 分支 RC/EP 行为，且读取
            // msi/interrupt 字段，克隆可避免与主 agent 共享句柄被 role 改写。
            for (int i = 0; i < cfg.num_rc; i++) begin
                xilinx_pcie_env_config ic;
                $cast(ic, cfg.clone());
                ic.set_name($sformatf("rc_int_cfg_%0d", i));
                ic.role = XILINX_PCIE_RC;
                uvm_config_db #(xilinx_pcie_env_config)::set(
                    this, $sformatf("rc_int_agent_%0d*", i), "env_config", ic);
                rc_int_agents.push_back(xilinx_pcie_interrupt_agent::type_id::create(
                    $sformatf("rc_int_agent_%0d", i), this));
            end
            for (int i = 0; i < cfg.num_ep; i++) begin
                xilinx_pcie_env_config ic;
                $cast(ic, cfg.clone());
                ic.set_name($sformatf("ep_int_cfg_%0d", i));
                ic.role = XILINX_PCIE_EP;
                uvm_config_db #(xilinx_pcie_env_config)::set(
                    this, $sformatf("ep_int_agent_%0d*", i), "env_config", ic);
                ep_int_agents.push_back(xilinx_pcie_interrupt_agent::type_id::create(
                    $sformatf("ep_int_agent_%0d", i), this));
            end

            // 旧 key 兼容（msi_seq 用 "int_agent"），指向 ep_int_agents[0]
            // all-RC(num_ep=0) 时 ep_int_agents 为空，跳过此旧 key 设置避免越界
            if (ep_int_agents.size() > 0)
                uvm_config_db #(xilinx_pcie_interrupt_agent)::set(
                    this, "*", "int_agent", ep_int_agents[0]);
            // 按索引 key（多 EP 时 msi_seq 可定向）
            foreach (ep_int_agents[i])
                uvm_config_db #(xilinx_pcie_interrupt_agent)::set(
                    this, "*", $sformatf("int_agent_%0d", i), ep_int_agents[i]);
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

            // 每 agent 创建一个 collector tap（UVM 组件须在 build_phase 创建）。
            // tap 转发 monitor TLP 输出到 collector；连接在 connect_phase 完成。
            foreach (rc_agents[i]) begin
                xilinx_pcie_collector_tap tp;
                tp = xilinx_pcie_collector_tap::type_id::create(
                    $sformatf("rc_tap_%0d", i), this);
                tp.agent_id  = i;
                tp.role      = XILINX_PCIE_RC;
                tp.collector = scb;
                taps.push_back(tp);
            end
            foreach (ep_agents[i]) begin
                xilinx_pcie_collector_tap tp;
                tp = xilinx_pcie_collector_tap::type_id::create(
                    $sformatf("ep_tap_%0d", i), this);
                tp.agent_id  = i;
                tp.role      = XILINX_PCIE_EP;
                tp.collector = scb;
                taps.push_back(tp);
            end

            // 每 agent error tap：与 collector tap 同序（先 RC，再 EP），
            // 连接 monitor.err_ap，转发本地协议错误到 collector.record_error。
            foreach (rc_agents[i]) begin
                xilinx_pcie_error_tap et;
                et = xilinx_pcie_error_tap::type_id::create(
                    $sformatf("rc_err_tap_%0d", i), this);
                et.agent_id  = i;
                et.role      = XILINX_PCIE_RC;
                et.collector = scb;
                err_taps.push_back(et);
            end
            foreach (ep_agents[i]) begin
                xilinx_pcie_error_tap et;
                et = xilinx_pcie_error_tap::type_id::create(
                    $sformatf("ep_err_tap_%0d", i), this);
                et.agent_id  = i;
                et.role      = XILINX_PCIE_EP;
                et.collector = scb;
                err_taps.push_back(et);
            end
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
        // 共享管理器（tag/fc/ord）取自一个 agent：优先 RC，无 RC 时回退 EP，
        // 以支持 all-EP(num_rc=0) / all-RC(num_ep=0) 配置不空指针解引用。
        if (rc_agents.size() > 0) begin
            v_sqr.tag_mgr = rc_agents[0].tag_mgr;
            v_sqr.fc_mgr  = rc_agents[0].fc_mgr;
            v_sqr.ord_eng = rc_agents[0].ord_eng;
        end else if (ep_agents.size() > 0) begin
            v_sqr.tag_mgr = ep_agents[0].tag_mgr;
            v_sqr.fc_mgr  = ep_agents[0].fc_mgr;
            v_sqr.ord_eng = ep_agents[0].ord_eng;
        end

        // 连接 RC/EP sequencer 引用：数组化（每个 agent 一项）+ [0] 别名
        foreach (rc_agents[i])
            if (rc_agents[i].sequencer != null)
                v_sqr.rc_sqr_arr.push_back(rc_agents[i].sequencer);
        foreach (ep_agents[i])
            if (ep_agents[i].sequencer != null)
                v_sqr.ep_sqr_arr.push_back(ep_agents[i].sequencer);
        if (v_sqr.rc_sqr_arr.size() > 0) v_sqr.rc_sqr = v_sqr.rc_sqr_arr[0];
        if (v_sqr.ep_sqr_arr.size() > 0) v_sqr.ep_sqr = v_sqr.ep_sqr_arr[0];

        // 统一内存句柄透传到 virtual sequencer（门控）
        if (cfg.use_unified_mem) begin
            v_sqr.host_mem = host_mem;
            v_sqr.dev_mem  = dev_mem;
        end

        // -----------------------------------------------------------------
        // 步骤 2：连接 Scoreboard（若使能）
        // -----------------------------------------------------------------
        if (scb != null) begin
            // 设置 collector 配置
            scb.cfg = this.cfg;

            // 将每个 agent 的 monitor TLP 输出（tlp_rx_ap，覆盖该 agent 在
            // RQ/RC/CQ/CC 四通道上观测到的全部 TLP）连接到对应 tap。
            // taps[] 创建顺序：先 rc_agents[0..num_rc-1]，再 ep_agents[0..num_ep-1]，
            // 与下方连接顺序一一对齐。
            begin
                int ti = 0;
                foreach (rc_agents[i]) begin
                    rc_agents[i].tlp_rx_ap.connect(taps[ti].analysis_export);
                    ti++;
                end
                foreach (ep_agents[i]) begin
                    ep_agents[i].tlp_rx_ap.connect(taps[ti].analysis_export);
                    ti++;
                end
            end

            // 将每个 agent 的 monitor 错误侧信道（err_ap）连接到对应 error tap。
            // err_taps[] 创建顺序与此处一致（先 RC，再 EP）。
            begin
                int ei = 0;
                foreach (rc_agents[i]) begin
                    rc_agents[i].monitor.err_ap.connect(err_taps[ei].analysis_export);
                    ei++;
                end
                foreach (ep_agents[i]) begin
                    ep_agents[i].monitor.err_ap.connect(err_taps[ei].analysis_export);
                    ei++;
                end
            end
        end

        // -----------------------------------------------------------------
        // 步骤 3：连接 Coverage subscriber（若使能）
        // -----------------------------------------------------------------
        if (cov != null) begin
            // 设置 coverage 配置
            cov.cfg = this.cfg;

            // 连接所有 4 路 TLP 分析端口到 coverage
            // RC 侧的 TX 和 RX（all-EP 配置无 RC agent，需门控避免空指针）
            if (rc_agents.size() > 0) begin
                rc_agent.tlp_tx_ap.connect(cov.analysis_export);
                rc_agent.tlp_rx_ap.connect(cov.analysis_export);
            end

            // EP 侧的 TX 和 RX（all-RC 配置无 EP agent，需门控避免空指针）
            if (ep_agents.size() > 0) begin
                ep_agent.tlp_tx_ap.connect(cov.analysis_export);
                ep_agent.tlp_rx_ap.connect(cov.analysis_export);
            end
        end

    endfunction : connect_phase

endclass : xilinx_pcie_env

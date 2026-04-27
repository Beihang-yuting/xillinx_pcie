//=============================================================================
// 文件名: xilinx_pcie_cfg_agent.sv
// 描述: Xilinx PCIe 配置管理 Agent
//       包含 cfg_driver、cfg_monitor、cfg_agent 三个类
//       负责驱动/监控 cfg_mgmt 边带接口（PG213 cfg_mgmt 时序）
//=============================================================================

//=============================================================================
// xilinx_pcie_cfg_driver
// 功能:
//   EP 角色 —— 提供 cfg_read/cfg_write task，由上层直接调用，驱动 user_cb
//   RC 角色 —— 后台监听 pcie_ip_cb 上的 cfg_mgmt 请求，查询 cfg_space 并响应
//=============================================================================
class xilinx_pcie_cfg_driver extends uvm_driver #(uvm_sequence_item);

    `uvm_component_utils(xilinx_pcie_cfg_driver)

    //-------------------------------------------------------------------------
    // 虚拟接口：连接到 xilinx_pcie_cfg_if 实例
    //-------------------------------------------------------------------------
    virtual xilinx_pcie_cfg_if cfg_vif;

    //-------------------------------------------------------------------------
    // BFM 角色：XILINX_PCIE_EP 或 XILINX_PCIE_RC
    //-------------------------------------------------------------------------
    xilinx_pcie_role_e role;

    //-------------------------------------------------------------------------
    // RC 角色专用：配置空间管理器，用于响应 EP 发来的 cfg_mgmt 请求
    // EP 角色时该字段为 null，不使用
    //-------------------------------------------------------------------------
    pcie_tl_cfg_space_manager cfg_space;

    //-------------------------------------------------------------------------
    // 超时门限：等待 read_write_done 的最大时钟周期数，防止仿真挂起
    //-------------------------------------------------------------------------
    int unsigned timeout_cycles = 1000;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：根据角色分别进入对应处理循环
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        // 等待复位撤销（rst_n 高电平）
        @(posedge cfg_vif.clk);
        wait (cfg_vif.rst_n === 1'b1);

        if (role == XILINX_PCIE_EP) begin
            // EP 角色：初始化输出信号并保持待机
            // 具体读写操作通过 cfg_read/cfg_write task 由上层主动调用
            _ep_idle();
        end else begin
            // RC 角色：后台持续监听并响应 EP 侧的 cfg_mgmt 请求
            _rc_respond_loop();
        end
    endtask : run_phase

    //=========================================================================
    // cfg_read —— EP 角色接口
    // 发起一次配置空间读操作，驱动 user_cb 信号，等待 read_write_done
    //
    // 参数:
    //   addr  - 配置空间 DWORD 地址（10bit，对应字节地址 = addr << 2）
    //   be    - 字节使能（4bit）
    //   data  - 读取到的 32bit 数据（输出）
    //=========================================================================
    task cfg_read(
        input  bit [9:0]  addr,
        input  bit [3:0]  be,
        output bit [31:0] data
    );
        int unsigned wait_cnt;

        // 确保只在 EP 角色下调用
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(),
                "cfg_read: 仅 EP 角色可调用此 task，RC 角色应监听 pcie_ip_cb")
            data = 32'hDEAD_BEEF;
            return;
        end

        // 在时钟上升沿之前驱动控制信号（通过 user_cb clocking block 同步）
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_mgmt_addr        <= addr;
        cfg_vif.user_cb.cfg_mgmt_byte_enable <= be;
        cfg_vif.user_cb.cfg_mgmt_write_data  <= 32'h0;
        cfg_vif.user_cb.cfg_mgmt_read        <= 1'b1;   // 断言读请求
        cfg_vif.user_cb.cfg_mgmt_write       <= 1'b0;

        // 等待 PCIe IP 返回 read_write_done，带超时保护
        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_mgmt_read_write_done !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("cfg_read 超时: addr=0x%03h，等待 %0d 周期后未收到 done",
                              addr, timeout_cycles))
                data = 32'hDEAD_BEEF;
                // 撤销请求信号后退出
                cfg_vif.user_cb.cfg_mgmt_read <= 1'b0;
                return;
            end
        end

        // 采样读数据
        data = cfg_vif.user_cb.cfg_mgmt_read_data;

        // 撤销读请求（下一拍拉低，符合 PG213 单拍脉冲要求）
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_mgmt_read <= 1'b0;

        `uvm_info(get_type_name(),
            $sformatf("cfg_read 完成: addr=0x%03h, be=0x%01h, data=0x%08h",
                      addr, be, data),
            UVM_HIGH)
    endtask : cfg_read

    //=========================================================================
    // cfg_write —— EP 角色接口
    // 发起一次配置空间写操作，驱动 user_cb 信号，等待 read_write_done
    //
    // 参数:
    //   addr  - 配置空间 DWORD 地址（10bit）
    //   be    - 字节使能（4bit）
    //   data  - 待写入的 32bit 数据
    //=========================================================================
    task cfg_write(
        input bit [9:0]  addr,
        input bit [3:0]  be,
        input bit [31:0] data
    );
        int unsigned wait_cnt;

        // 确保只在 EP 角色下调用
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(),
                "cfg_write: 仅 EP 角色可调用此 task，RC 角色应监听 pcie_ip_cb")
            return;
        end

        // 驱动写控制信号
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_mgmt_addr        <= addr;
        cfg_vif.user_cb.cfg_mgmt_byte_enable <= be;
        cfg_vif.user_cb.cfg_mgmt_write_data  <= data;
        cfg_vif.user_cb.cfg_mgmt_write       <= 1'b1;   // 断言写请求
        cfg_vif.user_cb.cfg_mgmt_read        <= 1'b0;

        // 等待 PCIe IP 返回 read_write_done，带超时保护
        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_mgmt_read_write_done !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("cfg_write 超时: addr=0x%03h，等待 %0d 周期后未收到 done",
                              addr, timeout_cycles))
                cfg_vif.user_cb.cfg_mgmt_write <= 1'b0;
                return;
            end
        end

        // 撤销写请求
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_mgmt_write <= 1'b0;

        `uvm_info(get_type_name(),
            $sformatf("cfg_write 完成: addr=0x%03h, be=0x%01h, data=0x%08h",
                      addr, be, data),
            UVM_HIGH)
    endtask : cfg_write

    //=========================================================================
    // 私有 task：EP 角色待机时初始化所有输出信号为无效值
    //=========================================================================
    protected task _ep_idle();
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_mgmt_addr        <= 10'h0;
        cfg_vif.user_cb.cfg_mgmt_byte_enable <= 4'hF;
        cfg_vif.user_cb.cfg_mgmt_read        <= 1'b0;
        cfg_vif.user_cb.cfg_mgmt_write       <= 1'b0;
        cfg_vif.user_cb.cfg_mgmt_write_data  <= 32'h0;
        // EP 角色驱动器保持待机，实际操作通过 cfg_read/cfg_write task 触发
        // 此处直接 return，让 run_phase 结束（由外部 fork 管理生命周期）
    endtask : _ep_idle

    //=========================================================================
    // 私有 task：RC 角色响应循环
    // 持续监听 pcie_ip_cb 上的 cfg_mgmt_read/write 信号，查询 cfg_space 并响应
    //
    // 时序（参考 PG213）：
    //   - EP 断言 cfg_mgmt_read/write，同时提供 addr/byte_enable/write_data
    //   - RC BFM 检测到请求后：
    //     读操作：查询 cfg_space，下一拍驱动 read_data + 断言 read_write_done（单拍脉冲）
    //     写操作：调用 cfg_space.write，下一拍断言 read_write_done（单拍脉冲）
    //=========================================================================
    protected task _rc_respond_loop();
        bit [9:0]  req_addr;
        bit [3:0]  req_be;
        bit [31:0] req_wdata;
        bit        is_read;
        bit        is_write;
        bit [31:0] rd_data;

        // 初始化 RC 侧输出信号（模拟 PCIe IP 上电默认状态）
        @(cfg_vif.pcie_ip_cb);
        cfg_vif.pcie_ip_cb.cfg_mgmt_read_data       <= 32'h0;
        cfg_vif.pcie_ip_cb.cfg_mgmt_read_write_done <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_mgmt_debug_access    <= 1'b0;

        forever begin
            // 等待读或写请求（任一拍为高即触发）
            @(cfg_vif.pcie_ip_cb);
            is_read  = cfg_vif.pcie_ip_cb.cfg_mgmt_read;
            is_write = cfg_vif.pcie_ip_cb.cfg_mgmt_write;

            if (!is_read && !is_write) continue;

            // 采样请求参数
            req_addr  = cfg_vif.pcie_ip_cb.cfg_mgmt_addr;
            req_be    = cfg_vif.pcie_ip_cb.cfg_mgmt_byte_enable;
            req_wdata = cfg_vif.pcie_ip_cb.cfg_mgmt_write_data;

            if (cfg_space == null) begin
                `uvm_error(get_type_name(),
                    "RC 角色 cfg_space 为 null，无法响应 cfg_mgmt 请求，请在 connect_phase 设置")
                continue;
            end

            if (is_read) begin
                // 读操作：cfg_mgmt_addr 是 DWORD 地址，cfg_space.read() 接受字节地址
                // 因此地址左移 2 位（x4）转换为字节地址
                // cfg_space.read() 接受 12bit 地址：{2'b00, req_addr[9:0], 2'b00} = {req_addr, 2'b00}
                rd_data = cfg_space.read({req_addr, 2'b00});

                // 驱动读数据并断言 done（单拍脉冲）
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_mgmt_read_data       <= rd_data;
                cfg_vif.pcie_ip_cb.cfg_mgmt_read_write_done <= 1'b1;

                `uvm_info(get_type_name(),
                    $sformatf("RC 响应 cfg_read: dw_addr=0x%03h, byte_addr=0x%04h, data=0x%08h",
                              req_addr, {req_addr, 2'b00}, rd_data),
                    UVM_HIGH)

            end else begin
                // 写操作：地址同样左移 2 位转换为字节地址
                cfg_space.write({req_addr, 2'b00}, req_wdata, req_be);

                // 断言 done（单拍脉冲），无需提供读数据
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_mgmt_read_data       <= 32'h0;
                cfg_vif.pcie_ip_cb.cfg_mgmt_read_write_done <= 1'b1;

                `uvm_info(get_type_name(),
                    $sformatf("RC 响应 cfg_write: dw_addr=0x%03h, byte_addr=0x%04h, data=0x%08h, be=0x%01h",
                              req_addr, {req_addr, 2'b00}, req_wdata, req_be),
                    UVM_HIGH)
            end

            // 下一拍撤销 done（保持单拍脉冲特性）
            @(cfg_vif.pcie_ip_cb);
            cfg_vif.pcie_ip_cb.cfg_mgmt_read_write_done <= 1'b0;
            cfg_vif.pcie_ip_cb.cfg_mgmt_read_data       <= 32'h0;
        end
    endtask : _rc_respond_loop

endclass : xilinx_pcie_cfg_driver


//=============================================================================
// xilinx_pcie_cfg_monitor
// 功能：监控 cfg_mgmt 总线上的读写事务并记录日志
//       同时提供 analysis port，供 scoreboard / coverage 订阅
//=============================================================================
class xilinx_pcie_cfg_monitor extends uvm_monitor;

    `uvm_component_utils(xilinx_pcie_cfg_monitor)

    //-------------------------------------------------------------------------
    // 虚拟接口
    //-------------------------------------------------------------------------
    virtual xilinx_pcie_cfg_if cfg_vif;

    //-------------------------------------------------------------------------
    // BFM 角色（影响监控使用 user_cb 还是 pcie_ip_cb 方向采样）
    //-------------------------------------------------------------------------
    xilinx_pcie_role_e role;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：持续监控 cfg_mgmt 事务完成事件，打印日志
    // 采样策略：
    //   无论角色，都通过裸信号（posedge clk）采样 done 脉冲
    //   当 done 为高时，同时采样请求信号以还原事务内容
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        // 等待复位撤销
        wait (cfg_vif.rst_n === 1'b1);

        forever begin
            // 等待 read_write_done 上升沿（事务完成的标志）
            @(posedge cfg_vif.clk);
            if (cfg_vif.cfg_mgmt_read_write_done !== 1'b1) continue;

            // 采样本次事务类型
            if (cfg_vif.cfg_mgmt_read) begin
                `uvm_info(get_type_name(),
                    $sformatf("[cfg_monitor] cfg_READ 完成: addr=0x%03h, be=0x%01h, data=0x%08h",
                              cfg_vif.cfg_mgmt_addr,
                              cfg_vif.cfg_mgmt_byte_enable,
                              cfg_vif.cfg_mgmt_read_data),
                    UVM_MEDIUM)
            end else if (cfg_vif.cfg_mgmt_write) begin
                `uvm_info(get_type_name(),
                    $sformatf("[cfg_monitor] cfg_WRITE 完成: addr=0x%03h, be=0x%01h, data=0x%08h",
                              cfg_vif.cfg_mgmt_addr,
                              cfg_vif.cfg_mgmt_byte_enable,
                              cfg_vif.cfg_mgmt_write_data),
                    UVM_MEDIUM)
            end else begin
                // done 信号高但无对应请求（罕见，记录警告）
                `uvm_warning(get_type_name(),
                    "[cfg_monitor] 检测到 read_write_done 但 read/write 均未断言")
            end
        end
    endtask : run_phase

endclass : xilinx_pcie_cfg_monitor


//=============================================================================
// xilinx_pcie_cfg_agent
// 功能：将 cfg_driver 和 cfg_monitor 组合为标准 UVM Agent
//       - build_phase：创建子组件
//       - connect_phase：从 config_db 获取 cfg_vif，分发给 driver/monitor
//=============================================================================
class xilinx_pcie_cfg_agent extends uvm_agent;

    `uvm_component_utils(xilinx_pcie_cfg_agent)

    //-------------------------------------------------------------------------
    // 子组件
    //-------------------------------------------------------------------------
    xilinx_pcie_cfg_driver   driver;
    xilinx_pcie_cfg_monitor  monitor;

    //-------------------------------------------------------------------------
    // 配置：由上层 env 在 build_phase 前通过 config_db 设置
    //-------------------------------------------------------------------------
    // BFM 角色
    xilinx_pcie_role_e        role      = XILINX_PCIE_EP;
    // RC 角色时使用的配置空间管理器（EP 角色置 null）
    pcie_tl_cfg_space_manager cfg_space = null;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：
    //   1. 始终创建 monitor（PASSIVE 模式下仅监控）
    //   2. 若处于 ACTIVE 模式，创建 driver
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // monitor 始终创建
        monitor = xilinx_pcie_cfg_monitor::type_id::create("monitor", this);

        // 仅 ACTIVE 模式创建 driver
        if (get_is_active() == UVM_ACTIVE) begin
            driver = xilinx_pcie_cfg_driver::type_id::create("driver", this);
        end
    endfunction : build_phase

    //=========================================================================
    // connect_phase：
    //   1. 从 config_db 获取 cfg_vif，传给 driver/monitor
    //   2. 设置 driver/monitor 的 role
    //   3. 若 RC 角色，将 cfg_space 引用传给 driver
    //=========================================================================
    virtual function void connect_phase(uvm_phase phase);
        virtual xilinx_pcie_cfg_if vif;

        super.connect_phase(phase);

        // 从 config_db 获取虚拟接口（必须）
        if (!uvm_config_db #(virtual xilinx_pcie_cfg_if)::get(
                this, "", "cfg_vif", vif)) begin
            `uvm_fatal(get_type_name(),
                "connect_phase: 无法从 config_db 获取 cfg_vif，请在 tb_top 中设置")
        end

        // 配置 monitor
        monitor.cfg_vif = vif;
        monitor.role    = role;

        // 配置 driver（仅 ACTIVE 模式）
        if (get_is_active() == UVM_ACTIVE) begin
            driver.cfg_vif   = vif;
            driver.role      = role;
            // RC 角色：传入 cfg_space 引用，用于响应 EP 的 cfg_mgmt 请求
            if (role == XILINX_PCIE_RC) begin
                if (cfg_space == null) begin
                    `uvm_warning(get_type_name(),
                        "RC 角色 cfg_space 为 null，cfg_mgmt 响应将报错，请在 env connect_phase 设置")
                end
                driver.cfg_space = cfg_space;
            end
        end
    endfunction : connect_phase

endclass : xilinx_pcie_cfg_agent

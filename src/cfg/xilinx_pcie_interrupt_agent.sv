//=============================================================================
// 文件名: xilinx_pcie_interrupt_agent.sv
// 描述: Xilinx PCIe 中断 Agent
//       包含 interrupt_driver、interrupt_monitor、interrupt_agent 三个类
//       支持 Legacy INTx / MSI / MSI-X 三种中断模式（参考 PG213）
//=============================================================================

//=============================================================================
// xilinx_pcie_interrupt_driver
// 功能:
//   EP 角色 —— 提供 send_legacy_interrupt / send_msi_interrupt /
//               send_msix_interrupt 三个 task，由上层序列主动调用
//   RC 角色 —— run_phase 后台任务：
//               根据配置驱动 MSI/MSI-X 使能信号；
//               监听中断请求信号，收到后驱动对应 sent 应答脉冲
//=============================================================================
class xilinx_pcie_interrupt_driver extends uvm_driver #(uvm_sequence_item);

    `uvm_component_utils(xilinx_pcie_interrupt_driver)

    //-------------------------------------------------------------------------
    // 虚拟接口：连接到 xilinx_pcie_cfg_if 实例（含中断信号）
    //-------------------------------------------------------------------------
    virtual xilinx_pcie_cfg_if cfg_vif;

    //-------------------------------------------------------------------------
    // BFM 角色
    //-------------------------------------------------------------------------
    xilinx_pcie_role_e role;

    //-------------------------------------------------------------------------
    // 环境配置引用：读取 interrupt_mode、msi_vector_count 等参数
    //-------------------------------------------------------------------------
    xilinx_pcie_env_config cfg;

    //-------------------------------------------------------------------------
    // 超时门限：等待 sent/fail 应答的最大时钟周期数
    //-------------------------------------------------------------------------
    int unsigned timeout_cycles = 1000;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：根据角色分支
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        // 等待复位撤销
        @(posedge cfg_vif.clk);
        wait (cfg_vif.rst_n === 1'b1);

        // EP 角色：用户侧中断输出初始化为无效值，等待上层调用 task
        if (role == XILINX_PCIE_EP)
            _ep_idle_init();

        // 本地 PCIe 硬核 IP 行为模型：在本 cfg_if 的 pcie_ip 侧驱动
        // msi_enable 状态并应答 msi_sent/cfg_interrupt_sent。
        // EP 侧由用户逻辑发起 MSI/MSI-X 中断，必须由【本地】IP 回应
        // cfg_interrupt_msi_sent，故 RC/EP 两种角色都需运行 IP 侧初始化与响应循环。
        fork
            _rc_init_int_status();
            _rc_int_respond_loop();
        join_none
    endtask : run_phase

    //=========================================================================
    // send_legacy_interrupt —— EP 角色接口（Legacy INTx 中断）
    //
    // 行为：断言 cfg_interrupt_int[vector]（拉高），等待 cfg_interrupt_sent
    //       收到 sent 后撤销断言（拉低），符合 PG213 INTx 握手时序
    //
    // 参数:
    //   vector - INTx 向量编号（0=INTA, 1=INTB, 2=INTC, 3=INTD）
    //=========================================================================
    task send_legacy_interrupt(int vector);
        int unsigned wait_cnt;

        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_legacy_interrupt: 仅 EP 角色可调用")
            return;
        end

        // 检查 vector 合法范围
        if (vector < 0 || vector > 3) begin
            `uvm_error(get_type_name(),
                $sformatf("send_legacy_interrupt: vector=%0d 非法，Legacy INTx 仅支持 0~3", vector))
            return;
        end

        // 检查中断功能是否启用
        if (cfg != null && !cfg.interrupt_enable) begin
            `uvm_warning(get_type_name(),
                "send_legacy_interrupt: interrupt_enable=0，跳过中断发送")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("发送 Legacy INTx 中断: vector=%0d (INT%s)",
                      vector, vector == 0 ? "A" : vector == 1 ? "B" : vector == 2 ? "C" : "D"),
            UVM_MEDIUM)

        // 断言对应 INTx 位
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b1;

        // 等待 PCIe IP 发送确认（cfg_interrupt_sent 高脉冲）
        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_interrupt_sent !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("send_legacy_interrupt 超时: vector=%0d，等待 %0d 周期未收到 sent",
                              vector, timeout_cycles))
                cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b0;
                return;
            end
        end

        // 收到 sent 后撤销中断断言
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b0;

        `uvm_info(get_type_name(),
            $sformatf("Legacy INTx 中断发送完成: vector=%0d", vector),
            UVM_MEDIUM)
    endtask : send_legacy_interrupt

    //=========================================================================
    // send_msi_interrupt —— EP 角色接口（MSI 中断）
    //
    // 行为：检查 msi_enable 状态，确认向量号在 mmenable 范围内，
    //       断言 cfg_interrupt_msi_int[vector]，等待 msi_sent 或 msi_fail
    //
    // 参数:
    //   vector - MSI 向量编号（0 ~ msi_vector_count-1）
    //=========================================================================
    task send_msi_interrupt(int vector);
        int unsigned wait_cnt;
        int          max_vec;

        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_msi_interrupt: 仅 EP 角色可调用")
            return;
        end

        if (cfg != null && !cfg.interrupt_enable) begin
            `uvm_warning(get_type_name(),
                "send_msi_interrupt: interrupt_enable=0，跳过中断发送")
            return;
        end

        // 检查 MSI 是否已由 RC 使能（采样 user_cb 输入方向）
        if (cfg_vif.user_cb.cfg_interrupt_msi_enable !== 1'b1) begin
            `uvm_warning(get_type_name(),
                $sformatf("send_msi_interrupt: MSI 尚未使能 (msi_enable=0)，vector=%0d 将被拒绝",
                          vector))
            // 依然尝试发送（硬件也会通过 msi_fail 拒绝），不直接 return
        end

        // 由 mmenable 推算最大有效向量数（2^mmenable）
        max_vec = 1 << int'(cfg_vif.user_cb.cfg_interrupt_msi_mmenable);
        if (vector < 0 || vector >= max_vec) begin
            `uvm_error(get_type_name(),
                $sformatf("send_msi_interrupt: vector=%0d 超出 mmenable 限制 (max=%0d-1)",
                          vector, max_vec))
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("发送 MSI 中断: vector=%0d", vector),
            UVM_MEDIUM)

        // 断言 MSI 向量请求位
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msi_int <= (32'h1 << vector);

        // 等待 msi_sent 或 msi_fail（两者互斥，均表示本次握手结束）
        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_interrupt_msi_sent !== 1'b1 &&
               cfg_vif.user_cb.cfg_interrupt_msi_fail !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("send_msi_interrupt 超时: vector=%0d，等待 %0d 周期",
                              vector, timeout_cycles))
                cfg_vif.user_cb.cfg_interrupt_msi_int <= 32'h0;
                return;
            end
        end

        // 检查发送结果
        if (cfg_vif.user_cb.cfg_interrupt_msi_fail === 1'b1) begin
            `uvm_error(get_type_name(),
                $sformatf("MSI 中断发送失败 (msi_fail=1): vector=%0d", vector))
        end else begin
            `uvm_info(get_type_name(),
                $sformatf("MSI 中断发送完成: vector=%0d", vector),
                UVM_MEDIUM)
        end

        // 撤销中断请求
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msi_int <= 32'h0;
    endtask : send_msi_interrupt

    //=========================================================================
    // send_msix_interrupt —— EP 角色接口（MSI-X 中断）
    //
    // 行为：检查 msix_enable && !msix_mask，设置 address/data，
    //       断言 cfg_interrupt_msix_int 单拍脉冲（PG213 要求同拍提供地址和数据）
    //
    // 参数:
    //   addr - MSI-X 消息目标地址（64bit，来自 MSI-X 表项 Message Address）
    //   data - MSI-X 消息数据（32bit，来自 MSI-X 表项 Message Data）
    //=========================================================================
    task send_msix_interrupt(bit [63:0] addr, bit [31:0] data);
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_msix_interrupt: 仅 EP 角色可调用")
            return;
        end

        if (cfg != null && !cfg.interrupt_enable) begin
            `uvm_warning(get_type_name(),
                "send_msix_interrupt: interrupt_enable=0，跳过中断发送")
            return;
        end

        // 检查 MSI-X 使能状态
        if (cfg_vif.user_cb.cfg_interrupt_msix_enable !== 1'b1) begin
            `uvm_warning(get_type_name(),
                "send_msix_interrupt: MSI-X 尚未使能 (msix_enable=0)")
        end

        // 检查全局 mask（msix_mask=1 时所有 MSI-X 向量被屏蔽）
        if (cfg_vif.user_cb.cfg_interrupt_msix_mask === 1'b1) begin
            `uvm_warning(get_type_name(),
                "send_msix_interrupt: MSI-X 全局 mask 已置位 (msix_mask=1)，中断可能被屏蔽")
        end

        `uvm_info(get_type_name(),
            $sformatf("发送 MSI-X 中断: addr=0x%016h, data=0x%08h", addr, data),
            UVM_MEDIUM)

        // 设置 MSI-X 地址和数据字段，同一拍断言 int 脉冲（PG213 要求同拍有效）
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msix_address <= addr;
        cfg_vif.user_cb.cfg_interrupt_msix_data    <= data;
        cfg_vif.user_cb.cfg_interrupt_msix_int     <= 1'b1;

        // 下一拍撤销请求脉冲（MSI-X int 为单拍脉冲）
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msix_int <= 1'b0;

        `uvm_info(get_type_name(),
            $sformatf("MSI-X 中断脉冲已发送: addr=0x%016h, data=0x%08h", addr, data),
            UVM_MEDIUM)
    endtask : send_msix_interrupt

    //=========================================================================
    // 私有 task：EP 角色上电初始化所有中断输出信号
    //=========================================================================
    protected task _ep_idle_init();
        @(cfg_vif.user_cb);
        // Legacy INTx
        cfg_vif.user_cb.cfg_interrupt_int     <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_pending <= 4'h0;
        // MSI
        cfg_vif.user_cb.cfg_interrupt_msi_int                         <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_data                        <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_select                      <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status              <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status_data_enable  <= 1'b0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status_function_num <= 4'h0;
        // MSI-X
        cfg_vif.user_cb.cfg_interrupt_msix_int     <= 1'b0;
        cfg_vif.user_cb.cfg_interrupt_msix_address <= 64'h0;
        cfg_vif.user_cb.cfg_interrupt_msix_data    <= 32'h0;
        // EP 驱动器进入待机，实际发送由外部调用 task 触发
    endtask : _ep_idle_init

    //=========================================================================
    // 私有 task：RC 角色初始化中断状态输出信号
    // 根据 interrupt_mode 驱动相应的使能信号（模拟 RC 枚举配置 EP 后的状态）
    //=========================================================================
    protected task _rc_init_int_status();
        @(cfg_vif.pcie_ip_cb);

        // 默认先清零所有 RC 侧中断状态信号
        cfg_vif.pcie_ip_cb.cfg_interrupt_sent            <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_enable      <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mmenable    <= 3'h0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mask_update <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent        <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_fail        <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_enable     <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_mask       <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending        <= 2'h0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b0;

        // 等待若干周期模拟枚举完成后再使能
        repeat (10) @(cfg_vif.pcie_ip_cb);

        if (cfg == null) begin
            `uvm_warning(get_type_name(),
                "_rc_init_int_status: cfg 为 null，无法读取 interrupt_mode，使用默认 Legacy 模式")
            return;
        end

        // 根据中断模式配置对应使能信号（模拟 RC 枚举后写入 EP 配置空间完成）
        case (cfg.interrupt_mode)
            XILINX_INT_LEGACY: begin
                // Legacy INTx：无需额外使能信号，保持默认 0
                `uvm_info(get_type_name(), "RC 中断模式: Legacy INTx", UVM_MEDIUM)
            end

            XILINX_INT_MSI: begin
                // MSI：驱动 msi_enable=1，根据 msi_vector_count 设置 mmenable
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_enable <= 1'b1;
                // mmenable 编码：0=1个向量, 1=2个, 2=4个, 3=8个, 4=16个, 5=32个
                begin
                    bit [2:0] mme;
                    case (cfg.msi_vector_count)
                        1:       mme = 3'b000;
                        2:       mme = 3'b001;
                        4:       mme = 3'b010;
                        8:       mme = 3'b011;
                        16:      mme = 3'b100;
                        32:      mme = 3'b101;
                        default: mme = 3'b000;
                    endcase
                    cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mmenable <= mme;
                end
                `uvm_info(get_type_name(),
                    $sformatf("RC 中断模式: MSI, vector_count=%0d", cfg.msi_vector_count),
                    UVM_MEDIUM)
            end

            XILINX_INT_MSIX: begin
                // MSI-X：驱动 msix_enable=1，mask 初始为 0（未屏蔽）
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_enable <= 1'b1;
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_mask   <= 1'b0;
                `uvm_info(get_type_name(),
                    $sformatf("RC 中断模式: MSI-X, table_size=%0d", cfg.msix_table_size),
                    UVM_MEDIUM)
            end

            default: begin
                `uvm_warning(get_type_name(),
                    $sformatf("RC 未知中断模式: %0d，不设置使能信号", cfg.interrupt_mode))
            end
        endcase
    endtask : _rc_init_int_status

    //=========================================================================
    // 私有 task：RC 角色中断响应循环
    // 持续监听 EP 侧的中断请求信号，收到后驱动对应的应答信号
    //
    // Legacy INTx：检测 cfg_interrupt_int 任意 bit 为高 -> 回应 sent 脉冲
    // MSI        ：检测 cfg_interrupt_msi_int 非零   -> 回应 msi_sent 脉冲
    // MSI-X      ：检测 cfg_interrupt_msix_int 为高  -> 更新 vec_pending_status 脉冲
    //=========================================================================
    protected task _rc_int_respond_loop();
        forever begin
            @(cfg_vif.pcie_ip_cb);

            // ----------------------------------------------------------------
            // Legacy INTx 响应
            // ----------------------------------------------------------------
            if (cfg_vif.pcie_ip_cb.cfg_interrupt_int !== 4'h0) begin
                bit [3:0] active_int = cfg_vif.pcie_ip_cb.cfg_interrupt_int;

                `uvm_info(get_type_name(),
                    $sformatf("RC 检测到 Legacy INTx 中断: int_vec=0x%01h", active_int),
                    UVM_MEDIUM)

                // 模拟 PCIe IP 处理 INTx 消息，延迟若干周期后回应 sent
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_sent <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_sent <= 1'b0;
            end

            // ----------------------------------------------------------------
            // MSI 中断响应
            // ----------------------------------------------------------------
            if (cfg_vif.pcie_ip_cb.cfg_interrupt_msi_int !== 32'h0) begin
                bit [31:0] msi_vec = cfg_vif.pcie_ip_cb.cfg_interrupt_msi_int;

                `uvm_info(get_type_name(),
                    $sformatf("RC 检测到 MSI 中断: int_vec=0x%08h", msi_vec),
                    UVM_MEDIUM)

                // 模拟 PCIe IP 发送 MSI 写消息后回应 sent
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent <= 1'b0;
            end

            // ----------------------------------------------------------------
            // MSI-X 中断响应
            // MSI-X 无显式 sent 信号；通过 vec_pending_status 通知 pending bit 已记录
            // ----------------------------------------------------------------
            if (cfg_vif.pcie_ip_cb.cfg_interrupt_msix_int === 1'b1) begin
                bit [63:0] msix_addr = cfg_vif.pcie_ip_cb.cfg_interrupt_msix_address;
                bit [31:0] msix_data = cfg_vif.pcie_ip_cb.cfg_interrupt_msix_data;

                `uvm_info(get_type_name(),
                    $sformatf("RC 检测到 MSI-X 中断: addr=0x%016h, data=0x%08h",
                              msix_addr, msix_data),
                    UVM_MEDIUM)

                // 模拟 PCIe IP 发送 MSI-X 写消息，并更新 vec_pending_status（单拍脉冲）
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b0;
            end
        end
    endtask : _rc_int_respond_loop

endclass : xilinx_pcie_interrupt_driver


//=============================================================================
// xilinx_pcie_interrupt_monitor
// 功能：监控中断信号，将捕获到的中断事件封装为 xilinx_interrupt_item
//       并通过 int_ap analysis port 广播给 scoreboard / coverage
//=============================================================================
class xilinx_pcie_interrupt_monitor extends uvm_monitor;

    `uvm_component_utils(xilinx_pcie_interrupt_monitor)

    //-------------------------------------------------------------------------
    // 虚拟接口
    //-------------------------------------------------------------------------
    virtual xilinx_pcie_cfg_if cfg_vif;

    //-------------------------------------------------------------------------
    // BFM 角色
    //-------------------------------------------------------------------------
    xilinx_pcie_role_e role;

    //-------------------------------------------------------------------------
    // Analysis Port：向外广播捕获到的中断事务
    //-------------------------------------------------------------------------
    uvm_analysis_port #(xilinx_interrupt_item) int_ap;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建 analysis port
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        int_ap = new("int_ap", this);
    endfunction : build_phase

    //=========================================================================
    // run_phase：并行监控三种中断模式
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        wait (cfg_vif.rst_n === 1'b1);

        fork
            _monitor_legacy();
            _monitor_msi();
            _monitor_msix();
        join_none
    endtask : run_phase

    //=========================================================================
    // 私有 task：监控 Legacy INTx 中断（检测上升沿）
    //=========================================================================
    protected task _monitor_legacy();
        bit [3:0] prev_int = 4'h0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit [3:0] curr_int = cfg_vif.cfg_interrupt_int;
                // 检测上升沿（有新的 INTx bit 被断言）
                if ((curr_int & ~prev_int) !== 4'h0) begin
                    for (int i = 0; i < 4; i++) begin
                        if (curr_int[i] && !prev_int[i]) begin
                            xilinx_interrupt_item item;
                            item = xilinx_interrupt_item::type_id::create("int_item");
                            item.mode       = XILINX_INT_LEGACY;
                            item.vector_num = i;
                            item.timestamp  = $realtime;

                            int_ap.write(item);

                            `uvm_info(get_type_name(),
                                $sformatf("[int_monitor] Legacy INTx 上升沿: INT%s (vector=%0d)",
                                          i == 0 ? "A" : i == 1 ? "B" : i == 2 ? "C" : "D", i),
                                UVM_MEDIUM)
                        end
                    end
                end
                prev_int = curr_int;
            end
        end
    endtask : _monitor_legacy

    //=========================================================================
    // 私有 task：监控 MSI 中断（检测新向量位被断言）
    //=========================================================================
    protected task _monitor_msi();
        bit [31:0] prev_msi = 32'h0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit [31:0] curr_msi = cfg_vif.cfg_interrupt_msi_int;
                // 检测新的 MSI 向量位被断言
                if ((curr_msi & ~prev_msi) !== 32'h0) begin
                    for (int i = 0; i < 32; i++) begin
                        if (curr_msi[i] && !prev_msi[i]) begin
                            xilinx_interrupt_item item;
                            item = xilinx_interrupt_item::type_id::create("msi_item");
                            item.mode       = XILINX_INT_MSI;
                            item.vector_num = i;
                            item.msi_data   = cfg_vif.cfg_interrupt_msi_data;
                            item.timestamp  = $realtime;

                            int_ap.write(item);

                            `uvm_info(get_type_name(),
                                $sformatf("[int_monitor] MSI 中断: vector=%0d, data=0x%08h",
                                          i, item.msi_data),
                                UVM_MEDIUM)
                        end
                    end
                end
                prev_msi = curr_msi;
            end
        end
    endtask : _monitor_msi

    //=========================================================================
    // 私有 task：监控 MSI-X 中断（检测 msix_int 上升沿）
    //=========================================================================
    protected task _monitor_msix();
        bit prev_msix = 1'b0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit curr_msix = cfg_vif.cfg_interrupt_msix_int;
                // 检测 msix_int 上升沿
                if (curr_msix && !prev_msix) begin
                    xilinx_interrupt_item item;
                    item = xilinx_interrupt_item::type_id::create("msix_item");
                    item.mode      = XILINX_INT_MSIX;
                    item.msix_addr = cfg_vif.cfg_interrupt_msix_address;
                    item.msix_data = cfg_vif.cfg_interrupt_msix_data;
                    item.timestamp = $realtime;

                    int_ap.write(item);

                    `uvm_info(get_type_name(),
                        $sformatf("[int_monitor] MSI-X 中断: addr=0x%016h, data=0x%08h",
                                  item.msix_addr, item.msix_data),
                        UVM_MEDIUM)
                end
                prev_msix = curr_msix;
            end
        end
    endtask : _monitor_msix

endclass : xilinx_pcie_interrupt_monitor


//=============================================================================
// xilinx_pcie_interrupt_agent
// 功能：将 interrupt_driver 和 interrupt_monitor 组合为标准 UVM Agent
//       - build_phase：创建子组件
//       - connect_phase：从 config_db 获取 cfg_vif 和 env_config，分发给子组件
//=============================================================================
class xilinx_pcie_interrupt_agent extends uvm_agent;

    `uvm_component_utils(xilinx_pcie_interrupt_agent)

    //-------------------------------------------------------------------------
    // 子组件
    //-------------------------------------------------------------------------
    xilinx_pcie_interrupt_driver   driver;
    xilinx_pcie_interrupt_monitor  monitor;

    //-------------------------------------------------------------------------
    // 配置
    //-------------------------------------------------------------------------
    xilinx_pcie_role_e     role = XILINX_PCIE_EP;
    xilinx_pcie_env_config cfg  = null;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建 monitor（始终）和 driver（ACTIVE 模式）
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // monitor 始终创建
        monitor = xilinx_pcie_interrupt_monitor::type_id::create("monitor", this);

        // ACTIVE 模式才创建 driver
        if (get_is_active() == UVM_ACTIVE) begin
            driver = xilinx_pcie_interrupt_driver::type_id::create("driver", this);
        end
    endfunction : build_phase

    //=========================================================================
    // connect_phase：
    //   1. 从 config_db 获取 cfg_vif（必须）
    //   2. 从 config_db 获取 env_config（可选，若获取成功则更新 role 和 cfg）
    //   3. 分发 vif、role、cfg 给 driver/monitor
    //=========================================================================
    virtual function void connect_phase(uvm_phase phase);
        virtual xilinx_pcie_cfg_if vif;
        xilinx_pcie_env_config     env_cfg;

        super.connect_phase(phase);

        // 获取虚拟接口（必须）
        if (!uvm_config_db #(virtual xilinx_pcie_cfg_if)::get(
                this, "", "cfg_vif", vif)) begin
            `uvm_fatal(get_type_name(),
                "connect_phase: 无法从 config_db 获取 cfg_vif，请在 tb_top 中设置")
        end

        // 获取环境配置（可选，获取成功则覆盖 agent 自身的 cfg/role 字段）
        if (uvm_config_db #(xilinx_pcie_env_config)::get(
                this, "", "env_config", env_cfg)) begin
            cfg  = env_cfg;
            role = env_cfg.role;
        end

        // 配置 monitor
        monitor.cfg_vif = vif;
        monitor.role    = role;

        // 配置 driver（仅 ACTIVE 模式）
        if (get_is_active() == UVM_ACTIVE) begin
            driver.cfg_vif = vif;
            driver.role    = role;
            driver.cfg     = cfg;
        end
    endfunction : connect_phase

endclass : xilinx_pcie_interrupt_agent

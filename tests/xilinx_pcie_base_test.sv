//=============================================================================
// 文件名: xilinx_pcie_base_test.sv
// 描述: Xilinx PCIe BFM 基础测试类
//
// 功能：
//   1. 从 plusarg 解析所有可配置参数（DATA_WIDTH、STRADDLE_EN 等）
//   2. 创建并配置 xilinx_pcie_env_config 对象
//   3. 将 config 注册到 UVM config_db，供 env 获取
//   4. 创建 xilinx_pcie_env 顶层环境
//
// 所有具体测试均继承本类，仅需覆盖 build_phase（可选）和 run_phase。
//
// 支持的 plusarg 列表：
//   +DATA_WIDTH=<64|128|256|512>     AXI-Stream 数据位宽（默认 256）
//   +STRADDLE_EN=<0|1>               Straddle 模式使能（默认 0）
//   +ROLE=<RC|EP>                    BFM 角色（回环时 env 内部已区分，默认 EP）
//   +MPS=<128|256|512|1024|2048>     最大 Payload 大小，字节（默认 256）
//   +MRRS=<128|256|512|1024|2048>    最大读请求大小，字节（默认 512）
//   +CFG_EN=<0|1>                    配置空间使能（默认 1）
//   +INT_EN=<0|1>                    中断总使能（默认 1）
//   +INT_MODE=<LEGACY|MSI|MSIX>      中断模式（默认 MSI）
//=============================================================================

class xilinx_pcie_base_test extends uvm_test;

    `uvm_component_utils(xilinx_pcie_base_test)

    //=========================================================================
    // 子组件
    //=========================================================================

    // 顶层验证环境（含 RC/EP agent、virtual sequencer、scoreboard、coverage）
    xilinx_pcie_env         env;

    // 环境配置对象（build_phase 中创建，注册到 config_db）
    xilinx_pcie_env_config  cfg;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：解析 plusarg -> 配置 cfg -> 注册 config_db -> 创建 env
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // -----------------------------------------------------------------
        // 步骤 1：创建环境配置对象（使用工厂，支持 override）
        // -----------------------------------------------------------------
        cfg = xilinx_pcie_env_config::type_id::create("cfg");

        // -----------------------------------------------------------------
        // 步骤 2：解析命令行 plusarg，覆盖配置默认值
        // -----------------------------------------------------------------
        _parse_plusargs();

        // -----------------------------------------------------------------
        // 步骤 3：验证配置合法性（DATA_WIDTH、MPS、MRRS、RCB 等）
        // -----------------------------------------------------------------
        if (!cfg.validate()) begin
            `uvm_fatal(get_type_name(),
                "build_phase: 环境配置验证失败，请检查 plusarg 参数合法性")
        end

        // -----------------------------------------------------------------
        // 步骤 4：将 cfg 注册到 config_db，路径匹配 env 中的 get 调用
        //         env.build_phase 中：uvm_config_db::get(this, "", "cfg", cfg)
        // -----------------------------------------------------------------
        uvm_config_db #(xilinx_pcie_env_config)::set(
            this, "env*", "cfg", cfg);

        // -----------------------------------------------------------------
        // 步骤 5：通过工厂创建顶层环境
        // -----------------------------------------------------------------
        env = xilinx_pcie_env::type_id::create("env", this);

        `uvm_info(get_type_name(),
            $sformatf("build_phase 完成 — DATA_WIDTH=%0d straddle=%0b MPS=%0d MRRS=%0d int_mode=%s",
                      cfg.DATA_WIDTH, cfg.straddle_enable,
                      cfg.max_payload_size, cfg.max_read_request_size,
                      cfg.interrupt_mode.name()),
            UVM_LOW)

    endfunction : build_phase

    //=========================================================================
    // end_of_elaboration_phase：高详细度下打印 UVM 组件拓扑
    //=========================================================================
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if (uvm_report_enabled(UVM_HIGH, UVM_INFO, get_type_name()))
            uvm_top.print_topology();
    endfunction : end_of_elaboration_phase

    //=========================================================================
    // run_phase：基础测试不执行任何序列，子类覆盖此方法实现具体测试逻辑
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "xilinx_pcie_base_test run_phase");
        `uvm_info(get_type_name(), "base_test run_phase：无测试序列，等待 100ns 后结束", UVM_LOW)
        #100ns;
        phase.drop_objection(this, "xilinx_pcie_base_test run_phase");
    endtask : run_phase

    //=========================================================================
    // 私有辅助函数：解析 plusarg 并设置 cfg 字段
    //=========================================================================
    protected virtual function void _parse_plusargs();
        int    int_val;
        string str_val;

        // ------------------------------------------------------------------
        // +DATA_WIDTH：AXI-Stream tdata 位宽
        // 合法值：64 / 128 / 256 / 512，默认 256
        // ------------------------------------------------------------------
        if ($value$plusargs("DATA_WIDTH=%d", int_val)) begin
            cfg.DATA_WIDTH = int_val;
            `uvm_info(get_type_name(),
                $sformatf("plusarg DATA_WIDTH = %0d", cfg.DATA_WIDTH), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +STRADDLE_EN：Straddle 跨 beat 对齐模式使能
        // 合法值：0 / 1，默认 0；仅在 DATA_WIDTH >= 256 时有效
        // ------------------------------------------------------------------
        if ($value$plusargs("STRADDLE_EN=%d", int_val)) begin
            cfg.straddle_enable = int_val[0];
            `uvm_info(get_type_name(),
                $sformatf("plusarg STRADDLE_EN = %0b", cfg.straddle_enable), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +ROLE：BFM 角色（回环仿真时 env 内部会分别克隆 RC/EP 配置，
        //        此字段主要用于单侧仿真或调试）
        // 合法值：RC / EP，默认 EP
        // ------------------------------------------------------------------
        if ($value$plusargs("ROLE=%s", str_val)) begin
            if (str_val.toupper() == "RC")
                cfg.role = XILINX_PCIE_RC;
            else
                cfg.role = XILINX_PCIE_EP;
            `uvm_info(get_type_name(),
                $sformatf("plusarg ROLE = %s", str_val.toupper()), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +MPS：Maximum Payload Size，单位字节
        // 合法值：128 / 256 / 512 / 1024 / 2048 / 4096，默认 256
        // ------------------------------------------------------------------
        if ($value$plusargs("MPS=%d", int_val)) begin
            cfg.max_payload_size = int_val;
            `uvm_info(get_type_name(),
                $sformatf("plusarg MPS = %0d", cfg.max_payload_size), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +MRRS：Maximum Read Request Size，单位字节
        // 合法值：128 / 256 / 512 / 1024 / 2048 / 4096，默认 512
        // ------------------------------------------------------------------
        if ($value$plusargs("MRRS=%d", int_val)) begin
            cfg.max_read_request_size = int_val;
            `uvm_info(get_type_name(),
                $sformatf("plusarg MRRS = %0d", cfg.max_read_request_size), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +CFG_EN：配置空间（CfgRd/CfgWr）使能
        // 合法值：0 / 1，默认 1
        // ------------------------------------------------------------------
        if ($value$plusargs("CFG_EN=%d", int_val)) begin
            cfg.cfg_enable = int_val[0];
            `uvm_info(get_type_name(),
                $sformatf("plusarg CFG_EN = %0b", cfg.cfg_enable), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +INT_EN：中断总使能
        // 合法值：0 / 1，默认 1
        // ------------------------------------------------------------------
        if ($value$plusargs("INT_EN=%d", int_val)) begin
            cfg.interrupt_enable = int_val[0];
            `uvm_info(get_type_name(),
                $sformatf("plusarg INT_EN = %0b", cfg.interrupt_enable), UVM_MEDIUM)
        end

        // ------------------------------------------------------------------
        // +INT_MODE：中断机制模式
        // 合法值：LEGACY / MSI / MSIX，默认 MSI
        // ------------------------------------------------------------------
        if ($value$plusargs("INT_MODE=%s", str_val)) begin
            case (str_val.toupper())
                "LEGACY" : cfg.interrupt_mode = XILINX_INT_LEGACY;
                "MSI"    : cfg.interrupt_mode = XILINX_INT_MSI;
                "MSIX"   : cfg.interrupt_mode = XILINX_INT_MSIX;
                default  : `uvm_warning(get_type_name(),
                               $sformatf("plusarg INT_MODE=%s 未知，保持默认值 MSI", str_val))
            endcase
            `uvm_info(get_type_name(),
                $sformatf("plusarg INT_MODE = %s", str_val.toupper()), UVM_MEDIUM)
        end

    endfunction : _parse_plusargs

endclass : xilinx_pcie_base_test

//=============================================================================
// Xilinx PCIe TL-Layer BFM - 基础序列
// 所有 Xilinx PCIe 序列的公共基类
// 提供 cfg 自动获取逻辑，支持普通 sequencer 和 virtual sequencer
//=============================================================================

class xilinx_pcie_base_seq extends uvm_sequence #(pcie_tl_tlp);

    `uvm_object_utils(xilinx_pcie_base_seq)

    //=========================================================================
    // 环境配置引用（由 pre_body 自动从 config_db 或 virtual sequencer 获取）
    //=========================================================================
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_base_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // pre_body：在 body() 执行前自动获取环境配置
    //
    // 获取策略（按优先级）：
    //   1. 如果 m_sequencer 是 xilinx_pcie_virtual_sequencer，直接读取其 cfg 字段
    //   2. 否则从 m_sequencer 的 config_db 中以 key "cfg" 获取
    //   3. 两种方式都失败时报 uvm_warning（不报 fatal，允许子类手动设置 cfg）
    //=========================================================================
    virtual task pre_body();
        xilinx_pcie_virtual_sequencer v_sqr;

        // 如果 cfg 已经由外部手动设置，跳过自动获取
        if (cfg != null) return;

        // 策略 1：尝试将 m_sequencer 转换为 virtual sequencer
        if ($cast(v_sqr, m_sequencer)) begin
            cfg = v_sqr.cfg;
            if (cfg != null) begin
                `uvm_info(get_type_name(),
                    "pre_body: 从 virtual sequencer 获取 cfg 成功", UVM_HIGH)
                return;
            end
        end

        // 策略 2：从 config_db 获取
        if (uvm_config_db #(xilinx_pcie_env_config)::get(
                m_sequencer, "", "cfg", cfg)) begin
            `uvm_info(get_type_name(),
                "pre_body: 从 config_db 获取 cfg 成功", UVM_HIGH)
            return;
        end

        // 两种方式都失败
        `uvm_warning(get_type_name(),
            "pre_body: 无法获取 xilinx_pcie_env_config，cfg 为 null")
    endtask : pre_body

endclass : xilinx_pcie_base_seq

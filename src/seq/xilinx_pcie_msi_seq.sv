//=============================================================================
// Xilinx PCIe TL-Layer BFM - 中断序列
// 通过 cfg_interrupt 侧带信号发送中断（不走 AXIS 数据通道）
// 支持 Legacy INTx / MSI / MSI-X 三种模式
//=============================================================================

class xilinx_pcie_msi_seq extends xilinx_pcie_base_seq;

    `uvm_object_utils(xilinx_pcie_msi_seq)

    //=========================================================================
    // 随机化字段
    //=========================================================================

    // 中断模式：Legacy / MSI / MSI-X
    rand xilinx_interrupt_mode_e mode;

    // 中断向量编号（Legacy: 0~3, MSI: 0~31, MSI-X: 由表项决定）
    rand int vector_num;

    // MSI-X 专用：目标地址（来自 MSI-X 表项的 Message Address）
    rand bit [63:0] msix_addr;

    // MSI-X 专用：消息数据（来自 MSI-X 表项的 Message Data）
    rand bit [31:0] msix_data;

    //=========================================================================
    // 约束
    //=========================================================================

    // Legacy INTx 向量范围：0~3（INTA~INTD）
    constraint c_legacy_vector {
        (mode == XILINX_INT_LEGACY) -> vector_num inside {[0:3]};
    }

    // MSI 向量范围：0~31
    constraint c_msi_vector {
        (mode == XILINX_INT_MSI) -> vector_num inside {[0:31]};
    }

    // MSI-X 向量编号非负
    constraint c_msix_vector {
        (mode == XILINX_INT_MSIX) -> vector_num >= 0;
    }

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_msi_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：通过 interrupt_agent 的 driver 发送中断
    //
    // 中断不走普通 TLP sequencer，而是通过 config_db 获取
    // xilinx_pcie_interrupt_agent 的引用，调用其 driver 的 task
    //=========================================================================
    virtual task body();
        xilinx_pcie_interrupt_agent int_agent;

        // 步骤 1：从 config_db 获取 interrupt_agent 引用
        if (!uvm_config_db #(xilinx_pcie_interrupt_agent)::get(
                m_sequencer, "", "int_agent", int_agent)) begin
            `uvm_error(get_type_name(),
                "body: 无法从 config_db 获取 xilinx_pcie_interrupt_agent (key='int_agent')")
            return;
        end

        // 步骤 2：检查 driver 是否存在（ACTIVE 模式才有 driver）
        if (int_agent.driver == null) begin
            `uvm_error(get_type_name(),
                "body: interrupt_agent.driver 为 null，可能处于 PASSIVE 模式")
            return;
        end

        // 步骤 3：检查中断是否启用
        if (cfg != null && !cfg.interrupt_enable) begin
            `uvm_warning(get_type_name(),
                "body: interrupt_enable=0，跳过中断发送")
            return;
        end

        // 步骤 4：根据模式调用对应的 driver task
        `uvm_info(get_type_name(),
            $sformatf("发送中断: mode=%s, vector=%0d%s",
                      mode.name(), vector_num,
                      (mode == XILINX_INT_MSIX) ?
                          $sformatf(", msix_addr=0x%016h, msix_data=0x%08h", msix_addr, msix_data) : ""),
            UVM_MEDIUM)

        case (mode)
            XILINX_INT_LEGACY: begin
                // Legacy INTx：调用 send_legacy_interrupt
                int_agent.driver.send_legacy_interrupt(vector_num);
            end

            XILINX_INT_MSI: begin
                // MSI：调用 send_msi_interrupt
                int_agent.driver.send_msi_interrupt(vector_num);
            end

            XILINX_INT_MSIX: begin
                // MSI-X：调用 send_msix_interrupt（传入地址和数据）
                int_agent.driver.send_msix_interrupt(msix_addr, msix_data);
            end

            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("body: 不支持的中断模式 %s", mode.name()))
            end
        endcase

        `uvm_info(get_type_name(),
            $sformatf("中断发送完成: mode=%s, vector=%0d", mode.name(), vector_num),
            UVM_MEDIUM)
    endtask : body

endclass : xilinx_pcie_msi_seq

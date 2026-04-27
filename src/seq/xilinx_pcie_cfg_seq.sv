//=============================================================================
// Xilinx PCIe TL-Layer BFM - Configuration Read/Write 序列
// 单次 Config Type0 或 Type1 的 Read/Write 事务
//=============================================================================

class xilinx_pcie_cfg_seq extends xilinx_pcie_base_seq;

    `uvm_object_utils(xilinx_pcie_cfg_seq)

    //=========================================================================
    // 随机化字段
    //=========================================================================

    // 寄存器 DW 地址（0~1023，对应配置空间偏移 0x000~0xFFC）
    rand bit [9:0]       reg_addr;

    // 方向：1=写（CfgWr），0=读（CfgRd）
    rand bit             is_write;

    // 类型：1=Type1（跨总线），0=Type0（本地总线）
    rand bit             is_type1;

    // 写数据（CfgWr 时有效，1 DW = 32 位）
    rand bit [31:0]      write_data;

    // Byte Enable（指定 DW 内哪些字节有效）
    rand bit [3:0]       first_be;

    // 目标设备的 Bus/Device/Function 编号
    rand bit [15:0]      target_bdf;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_cfg_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：构造并发送单个 Config TLP
    //=========================================================================
    virtual task body();
        pcie_tl_cfg_tlp tlp;

        // 步骤 1：创建 pcie_tl_cfg_tlp 实例
        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_tlp");

        // 步骤 2：设置 kind（根据读/写和 Type0/Type1 的组合）
        if (is_write) begin
            tlp.kind = is_type1 ? TLP_CFG_WR1 : TLP_CFG_WR0;
        end else begin
            tlp.kind = is_type1 ? TLP_CFG_RD1 : TLP_CFG_RD0;
        end

        // 步骤 3：设置 fmt（Config 事务固定 3DW 头部）
        if (is_write) begin
            tlp.fmt = FMT_3DW_WITH_DATA;
        end else begin
            tlp.fmt = FMT_3DW_NO_DATA;
        end

        // 步骤 4：设置 type_f（由 kind 决定 Type0 或 Type1 编码）
        if (is_type1) begin
            tlp.type_f = TLP_TYPE_CFG_RD1;
        end else begin
            tlp.type_f = TLP_TYPE_CFG_RD0;
        end

        // 步骤 5：设置配置空间地址和目标 BDF
        tlp.reg_num      = reg_addr;
        tlp.completer_id = target_bdf;
        tlp.first_be     = first_be;

        // 步骤 6：Config 事务固定 1 DW
        tlp.length = 10'h1;

        // 步骤 7：写事务设置 payload（4 字节 = 1 DW）
        if (is_write) begin
            tlp.payload = new[4];
            tlp.payload[0] = write_data[7:0];
            tlp.payload[1] = write_data[15:8];
            tlp.payload[2] = write_data[23:16];
            tlp.payload[3] = write_data[31:24];
        end else begin
            tlp.payload = new[0];
        end

        // 步骤 8：设置合法约束模式
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;

        // 步骤 9：通过 sequencer 发送 TLP
        `uvm_info(get_type_name(),
            $sformatf("发送 %s%s: reg_addr=0x%03h, target_bdf=0x%04h, first_be=0x%01h%s",
                      is_write ? "CfgWr" : "CfgRd",
                      is_type1 ? "1" : "0",
                      reg_addr, target_bdf, first_be,
                      is_write ? $sformatf(", data=0x%08h", write_data) : ""),
            UVM_MEDIUM)

        start_item(tlp);
        finish_item(tlp);
    endtask : body

endclass : xilinx_pcie_cfg_seq

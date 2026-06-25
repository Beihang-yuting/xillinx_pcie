//=============================================================================
// Xilinx PCIe TL-Layer BFM - Error Item（中央错误聚合的轻量载体）
//
// 由 agent 的 monitor 在本地协议检查（malformed 等）触发 uvm_error 时，
// 同步构造并经 err_ap 发布；err_tap 接收后调用 collector.record_error()。
// err_type 为稳定的字符串分类键（如 "MALFORMED"），collector 据此按 agent 累加。
//=============================================================================

class xilinx_pcie_error_item extends uvm_object;

    // 错误类型分类键（稳定字符串，作为 err_count 的二级 key）
    string err_type;

    `uvm_object_utils_begin(xilinx_pcie_error_item)
        `uvm_field_string(err_type, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "xilinx_pcie_error_item");
        super.new(name);
    endfunction

endclass : xilinx_pcie_error_item

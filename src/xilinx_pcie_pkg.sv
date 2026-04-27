//=============================================================================
// Xilinx PCIe TL-Layer BFM - 顶层 Package 文件
// 依赖：axis_pkg（AXI-Stream VIP）、pcie_tl_pkg（PCIe TL VIP）
//=============================================================================
package xilinx_pcie_pkg;

    // 导入 UVM 基础库
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // 导入 AXI-Stream VIP package（提供 axis_valid_gen_mode_e、axis_ready_gen_mode_e 等枚举）
    import axis_pkg::*;

    // 导入 PCIe TL VIP package（提供 pcie_tl_tlp、pcie_tl_pkg 中所有类型）
    import pcie_tl_pkg::*;

    // 包含本项目类型定义（枚举、结构体、helper 类、函数）
    `include "xilinx_pcie_types.sv"

    // 环境配置对象（14 个参数组，供 env/agent/scb/cov 使用）
    `include "env/xilinx_pcie_env_config.sv"

    // 描述符编解码器：提供 RQ/RC/CQ/CC 四个通道的 TLP <-> 描述符转换静态函数
    `include "codec/xilinx_desc_codec.sv"

    // 后续 Task 中将在此处追加以下 include：
    // `include "cfg/xilinx_pcie_cfg.sv"
    // `include "codec/xilinx_rq_codec.sv"
    // `include "codec/xilinx_rc_codec.sv"
    // `include "codec/xilinx_cq_codec.sv"
    // `include "codec/xilinx_cc_codec.sv"
    // `include "codec/xilinx_tuser_codec.sv"
    // `include "agent/xilinx_pcie_driver.sv"
    // `include "agent/xilinx_pcie_monitor.sv"
    // `include "agent/xilinx_pcie_agent.sv"
    // `include "env/xilinx_pcie_scoreboard.sv"
    // `include "env/xilinx_pcie_coverage.sv"
    // `include "env/xilinx_pcie_env.sv"
    // `include "seq/xilinx_pcie_base_seq.sv"

endpackage : xilinx_pcie_pkg

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

    // tuser 编解码器：提供四个通道的 AXI-Stream tuser 字段编解码（需实例化，DATA_WIDTH 参数化）
    `include "codec/xilinx_tuser_codec.sv"

    // Straddle 引擎：将单个 TLP 的 descriptor + payload 打包/拆包为 AXI-Stream beat 序列
    `include "codec/xilinx_straddle_engine.sv"

    // 通道路由器：根据 BFM 角色和 TLP 类别决定使用哪个 AXI-Stream 通道（TX/RX）
    `include "agent/xilinx_pcie_channel_router.sv"

    // PCIe TLP Driver：将 pcie_tl_tlp 编码为 AXI-Stream beat 序列并发送（11 步流水线）
    `include "agent/xilinx_pcie_driver.sv"

    // PCIe TLP Monitor：监听 4 个 axis_agent 输出，将 AXI-Stream 包解码回 pcie_tl_tlp
    `include "agent/xilinx_pcie_monitor.sv"

    // 基础 Agent：组合 4 个 axis_agent、driver、monitor 及 TL 层共享管理器
    `include "agent/xilinx_pcie_base_agent.sv"

    // RC Agent：Root Complex 特化，支持 Completion 超时追踪和 BAR 地址分配
    `include "agent/xilinx_pcie_rc_agent.sv"

    // EP Agent：Endpoint 特化，支持自动回复、内存模型和 DMA 发起
    `include "agent/xilinx_pcie_ep_agent.sv"

    // cfg_mgmt 边带接口驱动/监控 Agent（EP 提供 cfg_read/write task，RC 自动响应）
    `include "cfg/xilinx_pcie_cfg_agent.sv"

    // 中断边带接口 Agent（支持 Legacy INTx / MSI / MSI-X 三种模式）
    `include "cfg/xilinx_pcie_interrupt_agent.sv"

    // 后续 Task 中将在此处追加以下 include：
    // `include "agent/xilinx_pcie_agent.sv"
    // `include "env/xilinx_pcie_scoreboard.sv"
    // `include "env/xilinx_pcie_coverage.sv"
    // `include "env/xilinx_pcie_env.sv"
    // `include "seq/xilinx_pcie_base_seq.sv"

endpackage : xilinx_pcie_pkg

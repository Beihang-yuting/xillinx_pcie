//=============================================================================
// Xilinx PCIe TL-Layer BFM - Per-agent Error Tap
//
// 轻量 subscriber：监听单个 agent 的 monitor 错误输出（err_ap，携带
// xilinx_pcie_error_item），将 (agent_id, role, err_type) 转发到中央
// collector（xilinx_pcie_scoreboard.record_error）。
// 镜像 xilinx_pcie_collector_tap：每个 RC/EP agent 各一个 error tap。
//=============================================================================

class xilinx_pcie_error_tap extends uvm_subscriber #(xilinx_pcie_error_item);
  `uvm_component_utils(xilinx_pcie_error_tap)

  // 本 tap 绑定的 agent 序号（rc_agents/ep_agents 下标）
  int                    agent_id;

  // 本 tap 绑定的 agent 角色（RC / EP）
  xilinx_pcie_role_e     role;

  // 中央 collector 句柄（由 env 在 build_phase 注入）
  xilinx_pcie_scoreboard collector;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // monitor 每发布一个本地协议错误即回调 write()，转发给 collector.record_error()
  function void write(xilinx_pcie_error_item t);
    if (collector != null && t != null)
      collector.record_error(agent_id, role, t.err_type);
  endfunction

endclass : xilinx_pcie_error_tap

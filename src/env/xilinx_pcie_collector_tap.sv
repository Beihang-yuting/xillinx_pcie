//=============================================================================
// Xilinx PCIe TL-Layer BFM - Per-agent Collector Tap
//
// 轻量 subscriber：监听单个 agent 的 monitor TLP 输出（tlp_rx_ap），
// 将 (agent_id, role, tlp) 转发到中央 collector（xilinx_pcie_scoreboard）。
// 每个 RC/EP agent 对应一个 tap，collector 据此做协议类型 + 错误类型分类统计。
//=============================================================================

class xilinx_pcie_collector_tap extends uvm_subscriber #(pcie_tl_tlp);
  `uvm_component_utils(xilinx_pcie_collector_tap)

  // 本 tap 绑定的 agent 序号（rc_agents/ep_agents 下标）
  int                    agent_id;

  // 本 tap 绑定的 agent 角色（RC / EP）
  xilinx_pcie_role_e     role;

  // 中央 collector 句柄（由 env 在 build_phase 注入）
  xilinx_pcie_scoreboard collector;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // monitor 每解码一个 TLP 即回调 write()，转发给 collector.record()
  function void write(pcie_tl_tlp t);
    if (collector != null) collector.record(agent_id, role, t);
  endfunction

endclass : xilinx_pcie_collector_tap

//=============================================================================
// Xilinx PCIe TL-Layer BFM - Protocol/Error Collector（原 Scoreboard 重构）
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能（多 agent 协议类型 + 错误类型收集器）：
//   env 不再校验 payload/数据正确性（由用户自行检查）。本组件仅：
//     1. 按 agent 对每个观测到的 TLP 做协议类型分类（直方图）
//     2. 按 agent 聚合错误类型（poisoned/EP 位）
//   每个 agent 的 monitor TLP 输出经一个 per-agent tap 转发到本收集器，
//   tap 调用 record(agent_id, role, tlp)。
//
// 注：scb_data_integrity / scb_completion_check 等旧配置字段仍保留在
//     env_config 中，但本组件不再使用（no-op）。
//=============================================================================

class xilinx_pcie_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(xilinx_pcie_scoreboard)

    //=========================================================================
    // 配置
    //=========================================================================

    // 环境配置对象（由 env 直接赋值或 config_db 获取）
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 统计容器
    //   proto_count[agent_key][tlp_type] : 协议类型直方图
    //   err_count  [agent_key][err_type] : 错误类型聚合
    // agent_key 形如 "XILINX_PCIE_RC_0" / "XILINX_PCIE_EP_1"
    //=========================================================================
    protected int unsigned proto_count[string][string];
    protected int unsigned err_count[string][string];

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：获取配置（可选）
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info(get_type_name(),
                "未在 config_db 中找到 cfg，等待 env 直接赋值", UVM_MEDIUM)
        end
    endfunction : build_phase

    //=========================================================================
    // record：tap 转发回调，按 agent 累加协议类型与错误类型
    //   - 协议类型：tlp.kind 枚举名（TLP_MEM_WR / TLP_CPLD / ...）
    //   - 错误类型：tlp.ep_bit（Poisoned/EP 位）——codec 编解码往返保留的
    //     真实片上错误指示位。无 poisoned 时不计入 err_count。
    //=========================================================================
    function void record(int agent_id, xilinx_pcie_role_e role, pcie_tl_tlp t);
        string ak = $sformatf("%s_%0d", role.name(), agent_id);
        if (t == null) return;
        proto_count[ak][t.kind.name()]++;
        if (t.ep_bit) err_count[ak]["POISONED"]++;
    endfunction : record

    //=========================================================================
    // record_error：error tap 转发回调，按 agent 累加本地协议错误类型
    //   由各 agent monitor 的本地协议检查（malformed 等）经 err_ap -> err_tap
    //   触发。与 record() 的 poisoned 路径并存，共同填充 err_count。
    //=========================================================================
    function void record_error(int agent_id, xilinx_pcie_role_e role, string err_type);
        string ak = $sformatf("%s_%0d", role.name(), agent_id);
        err_count[ak][err_type]++;
    endfunction : record_error

    //=========================================================================
    // num_agent_keys：返回已观测到的 agent 数量（proto_count 顶层 key 数）
    //   供测试断言 agent 覆盖（例如 multi-EP 测试期望 4 个 EP 均被观测）。
    //   注：仅统计有协议计数的 agent；纯 error agent 不计入。
    //=========================================================================
    function int unsigned num_agent_keys();
        return proto_count.size();
    endfunction : num_agent_keys

    //=========================================================================
    // has_agent_key：查询某 agent_key（如 "XILINX_PCIE_EP_2"）是否被观测到。
    //=========================================================================
    function bit has_agent_key(string ak);
        return proto_count.exists(ak);
    endfunction : has_agent_key

    //=========================================================================
    // report_phase：输出协议类型直方图；对任何错误类型报 uvm_error
    //=========================================================================
    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        foreach (proto_count[ak])
            foreach (proto_count[ak][ty])
                `uvm_info("PROTO",
                    $sformatf("[%s] %s = %0d", ak, ty, proto_count[ak][ty]), UVM_LOW)

        foreach (err_count[ak])
            foreach (err_count[ak][et])
                `uvm_error("PROTO_ERR",
                    $sformatf("[%s] %s x%0d", ak, et, err_count[ak][et]))
    endfunction : report_phase

endclass : xilinx_pcie_scoreboard

//=============================================================================
// Xilinx PCIe TL-Layer BFM - 虚拟 Sequencer
// 聚合 RC 和 EP 两侧的 sequencer 引用，供顶层虚拟序列使用
//
// 虚拟 Sequencer 本身不参与事务仲裁或路由，仅提供对各子 agent
// sequencer 的集中访问入口，使虚拟序列可以同时协调 RC 和 EP 侧的
// TLP 流量。
//=============================================================================

class xilinx_pcie_virtual_sequencer extends uvm_sequencer;

    `uvm_component_utils(xilinx_pcie_virtual_sequencer)

    //=========================================================================
    // 子 agent sequencer 引用（由 env 的 connect_phase 设置）
    //=========================================================================

    // RC agent 的 TLP sequencer：用于从 RC 侧发送请求 TLP
    uvm_sequencer #(pcie_tl_tlp) rc_sqr;

    // EP agent 的 TLP sequencer：用于从 EP 侧发送请求/响应 TLP
    uvm_sequencer #(pcie_tl_tlp) ep_sqr;

    //=========================================================================
    // 环境配置引用（由 env 的 connect_phase 设置）
    //=========================================================================

    // 环境配置对象：供虚拟序列查询全局参数
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 共享服务引用（由 env 的 connect_phase 设置）
    //=========================================================================

    // Tag 管理器：供虚拟序列分配/释放请求 Tag
    pcie_tl_tag_manager     tag_mgr;

    // 流量控制管理器：供虚拟序列查询 FC credit 状态
    pcie_tl_fc_manager      fc_mgr;

    // 排序引擎：供虚拟序列检查 TLP 排序合规性
    pcie_tl_ordering_engine ord_eng;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

endclass : xilinx_pcie_virtual_sequencer

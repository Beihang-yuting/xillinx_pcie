//=============================================================================
// Xilinx PCIe TL-Layer BFM - 环境配置对象
// 汇聚 BFM 所有可配置参数，供 env、agent、scoreboard、coverage 使用
// 参考：Xilinx PG213 PCIe IP 接口规范
//=============================================================================

// 内存访问模式：PER_BUFFER=序列显式 alloc/free；PREMAP=env 预映射有界窗口
typedef enum bit { XILINX_MEM_PER_BUFFER = 1'b0, XILINX_MEM_PREMAP = 1'b1 } xilinx_mem_access_mode_e;

class xilinx_pcie_env_config extends uvm_object;

    `uvm_object_utils(xilinx_pcie_env_config)

    //-------------------------------------------------------------------------
    // 参数组 1：角色与激活模式
    // 决定 BFM 在系统中扮演 RC（根复合体）还是 EP（端点），以及是否主动驱动
    //-------------------------------------------------------------------------
    // BFM 角色：XILINX_PCIE_RC 或 XILINX_PCIE_EP
    xilinx_pcie_role_e          role        = XILINX_PCIE_EP;
    // UVM 激活/被动模式：UVM_ACTIVE 时 driver 主动驱动，UVM_PASSIVE 时仅监听
    uvm_active_passive_enum     is_active   = UVM_ACTIVE;

    //-------------------------------------------------------------------------
    // 参数组 2：AXI-Stream 数据位宽
    // 支持 64 / 128 / 256 / 512 位，必须与 Xilinx PCIe IP 配置一致
    //-------------------------------------------------------------------------
    // AXI-Stream tdata 数据位宽（单位：bit）
    // 默认继承编译期宏 XILINX_DATA_W (由 +define+DATA_WIDTH=N 驱动)
    int                         DATA_WIDTH  = `XILINX_DATA_W;

    //-------------------------------------------------------------------------
    // 参数组 3：Straddle 模式
    // 使能后允许 TLP 跨 beat 边界对齐，仅在 DATA_WIDTH >= 256 时有效
    //-------------------------------------------------------------------------
    // Straddle 使能：允许 TLP 跨 beat 边界放置以提升带宽利用率
    bit                         straddle_enable = 1'b0;

    //-------------------------------------------------------------------------
    // 参数组 4：PCIe 链路能力参数
    // 与硬件 IP 配置保持一致，用于事务合法性检查和带宽计算
    //-------------------------------------------------------------------------
    // 最大 Payload 大小（MPS），单位：字节，合法值：128/256/512/1024/2048/4096
    int                         max_payload_size        = 256;
    // 最大读请求大小（MRRS），单位：字节，合法值：128/256/512/1024/2048/4096
    int                         max_read_request_size   = 512;
    // 读完成边界（RCB），单位：字节，合法值：64 或 128
    int                         read_completion_boundary = 64;
    // PCIe 链路速度：GEN1/GEN2/GEN3/GEN4
    xilinx_pcie_speed_e         link_speed              = XILINX_PCIE_GEN3;
    // PCIe 链路宽度（Lane 数）：1/2/4/8/16
    int                         link_width              = 8;

    //-------------------------------------------------------------------------
    // 参数组 5：Tag 管理参数
    // 控制 PCIe 请求 Tag 的分配范围和并发深度
    //-------------------------------------------------------------------------
    // 扩展 Tag 使能：使能后 Tag 空间从 32 扩展到 256（PCIe 2.1+）
    bit                         extended_tag_enable     = 1'b1;
    // 最大未完成请求数（outstanding），对应 Tag 池大小
    int                         max_outstanding         = 256;

    //-------------------------------------------------------------------------
    // 参数组 6：流量控制（Flow Control）参数
    // 初始 Credit 值需与对端硬件 IP 实际配置一致
    //-------------------------------------------------------------------------
    // 流量控制使能：关闭后跳过 FC credit 检查
    bit                         fc_enable           = 1'b1;
    // 无限 Credit 模式：仿真加速用，跳过 credit 耗尽等待
    // 默认无限 credit，避免回环 BFM 因缺少 credit 回收机制而阻塞
    bit                         infinite_credit     = 1'b1;
    // Posted Header Credit 初始值
    int                         init_ph_credit      = 32;
    // Posted Data Credit 初始值（单位：4B）
    int                         init_pd_credit      = 256;
    // Non-Posted Header Credit 初始值
    int                         init_nph_credit     = 32;
    // Non-Posted Data Credit 初始值（单位：4B）
    int                         init_npd_credit     = 256;
    // Completion Header Credit 初始值
    int                         init_cplh_credit    = 32;
    // Completion Data Credit 初始值（单位：4B）
    int                         init_cpld_credit    = 256;

    //-------------------------------------------------------------------------
    // 参数组 7：排序（Ordering）参数
    // 控制 TLP 排序规则的宽松程度，影响吞吐量与正确性的取舍
    //-------------------------------------------------------------------------
    // 宽松排序使能（Relaxed Ordering）：允许 Posted 超越 Posted
    bit                         relaxed_ordering_enable     = 1'b1;
    // ID Based Ordering（IDO）使能：同 Function ID 内保序
    bit                         id_based_ordering_enable    = 1'b1;
    // 旁路排序检查：仿真加速用，完全跳过排序规则验证
    bit                         bypass_ordering             = 1'b0;

    //-------------------------------------------------------------------------
    // 参数组 8：配置空间参数
    // 模拟 EP 的 PCI 配置空间，用于 RC 侧的枚举和配置事务响应
    //-------------------------------------------------------------------------
    // 配置空间使能：关闭后忽略 CfgRd/CfgWr 事务
    bit                         cfg_enable          = 1'b1;
    // PCI Vendor ID（Xilinx 官方 ID：0x10EE）
    bit [15:0]                  vendor_id           = 16'h10EE;
    // PCI Device ID（Xilinx UltraScale+ PCIe：0x9038）
    bit [15:0]                  device_id           = 16'h9038;
    // PCI Class Code（Network Controller：0x02_00_00）
    bit [23:0]                  class_code          = 24'h02_00_00;
    // PCI Subsystem Vendor ID
    bit [15:0]                  subsys_vendor_id    = 16'h10EE;
    // PCI Subsystem Device ID
    bit [15:0]                  subsys_device_id    = 16'h0000;
    // BAR 配置数组：共 6 个 BAR（BAR0~BAR5）
    // 默认 BAR0 使能为 64KB 内存空间，其余禁用
    xilinx_bar_config_t         bar_cfg[6];

    //-------------------------------------------------------------------------
    // 参数组 9：中断参数
    // 配置中断机制类型及 MSI/MSI-X 向量数量
    //-------------------------------------------------------------------------
    // 中断总使能：关闭后不处理任何中断事务
    bit                         interrupt_enable    = 1'b1;
    // 中断模式：LEGACY / MSI / MSIX
    xilinx_interrupt_mode_e     interrupt_mode      = XILINX_INT_MSI;
    // MSI 向量数量（1/2/4/8/16/32）
    int                         msi_vector_count    = 1;
    // MSI-X 表项数量（0 表示不使用 MSI-X）
    int                         msix_table_size     = 0;
    // MSI-X 表所在 BAR 编号
    int                         msix_table_bar      = 0;
    // MSI-X 表在 BAR 内的偏移量（字节）
    bit [31:0]                  msix_table_offset   = 32'h0;
    // MSI-X PBA（Pending Bit Array）所在 BAR 编号
    int                         msix_pba_bar        = 0;
    // MSI-X PBA 在 BAR 内的偏移量（字节）
    bit [31:0]                  msix_pba_offset     = 32'h0;

    //-------------------------------------------------------------------------
    // 参数组 10：AXI-Stream 带宽控制参数
    // 控制 TX（发送）通道 valid 和 RX（接收）通道 ready 的时序模式
    //-------------------------------------------------------------------------
    // TX valid 生成模式：控制 RQ/CC 通道驱动侧的 valid 节拍行为
    axis_valid_gen_mode_e       tx_valid_mode       = VALID_ZERO_IDLE;
    // RX ready 生成模式：控制 RC/CQ 通道接收侧的 ready 节拍行为
    axis_ready_gen_mode_e       rx_ready_mode       = READY_ALWAYS;
    // TX 空闲周期数（VALID_FIXED_IDLE 模式下生效）
    int                         tx_idle_cycles      = 0;
    // TX valid 权重（VALID_WEIGHTED 模式，0-100 表示占空比百分比）
    int                         tx_valid_weight     = 100;
    // RX ready 权重（READY_WEIGHTED 模式，0-100 表示占空比百分比）
    int                         rx_ready_weight     = 100;
    // 是否启用通道独立带宽配置：1 时使用 channel_bw_cfg[]，0 时使用全局参数
    bit                         per_channel_bw_config = 1'b0;
    // 各通道独立带宽配置数组：[0]=RQ, [1]=RC, [2]=CQ, [3]=CC
    xilinx_channel_bw_config_t  channel_bw_cfg[4];

    //-------------------------------------------------------------------------
    // 参数组 11：EP 自动响应参数
    // 仿真 EP 自动响应读请求，减少测试序列复杂度
    //-------------------------------------------------------------------------
    // EP 自动响应使能：1 时 BFM 自动对 MRd 生成 CplD 响应
    bit                         ep_auto_response    = 1'b1;
    // 自动响应延迟最小值（单位：时钟周期）
    int                         response_delay_min  = 0;
    // 自动响应延迟最大值（单位：时钟周期），实际延迟在 [min, max] 均匀分布
    int                         response_delay_max  = 10;
    // EP 模拟内存大小（字节），决定地址合法范围
    bit [63:0]                  mem_size            = 64'h1_0000_0000;

    //-------------------------------------------------------------------------
    // 参数组 12：超时参数
    // 防止仿真因等待 completion 而无限挂起
    //-------------------------------------------------------------------------
    // Completion 超时门限（单位：ns），超过后报 uvm_error 并放弃等待
    int                         cpl_timeout_ns      = 50000;

    //-------------------------------------------------------------------------
    // 参数组 13：Scoreboard 与功能覆盖率开关
    // 细粒度控制各检查维度的使能，以便在调试时选择性关闭
    //-------------------------------------------------------------------------
    // Scoreboard 总使能
    bit                         scb_enable              = 1'b1;
    // Completion 配对检查：验证每个 MRd 都收到对应的 CplD
    bit                         scb_completion_check    = 1'b1;
    // 数据完整性检查：比较发送与接收 payload 的一致性
    bit                         scb_data_integrity      = 1'b1;
    // 排序规则检查：验证 TLP 到达顺序符合 PCIe 规范
    bit                         scb_ordering_check      = 1'b1;
    // 描述符格式检查：核实描述符字段编码的合法性
    bit                         scb_descriptor_check    = 1'b1;
    // 功能覆盖率总使能
    bit                         cov_enable              = 1'b0;
    // TLP 类型覆盖率：统计各 TLP 类型（MRd/MWr/Cpl 等）的覆盖情况
    bit                         cov_tlp_type            = 1'b0;
    // 描述符字段覆盖率：统计描述符各关键字段的取值分布
    bit                         cov_descriptor          = 1'b0;
    // tuser 字段覆盖率：统计 tuser sideband 信号的取值组合
    bit                         cov_tuser               = 1'b0;
    // Straddle 模式覆盖率：统计跨 beat 边界的 TLP 分布
    bit                         cov_straddle            = 1'b0;
    // 通道覆盖率：统计四个 AXI-Stream 通道的事务分布
    bit                         cov_channel             = 1'b0;
    // 流量控制覆盖率：统计 FC credit 接近耗尽等边界条件
    bit                         cov_fc                  = 1'b0;

    //-------------------------------------------------------------------------
    // 参数组 14：协议检查开关
    // 细粒度控制各通道和各维度的协议合规性检查
    //-------------------------------------------------------------------------
    // RQ 通道协议检查使能
    bit                         rq_protocol_check_enable        = 1'b1;
    // RC 通道协议检查使能
    bit                         rc_protocol_check_enable        = 1'b1;
    // CQ 通道协议检查使能
    bit                         cq_protocol_check_enable        = 1'b1;
    // CC 通道协议检查使能
    bit                         cc_protocol_check_enable        = 1'b1;
    // 描述符格式合规检查使能：验证描述符保留字段为零等规范要求
    bit                         desc_format_check_enable        = 1'b1;
    // tuser 一致性检查使能：验证 tuser 与描述符字段之间的对应关系
    bit                         tuser_consistency_check         = 1'b1;
    // Payload 对齐检查使能：验证写请求 payload 的 DW 对齐
    bit                         payload_alignment_check         = 1'b1;
    // Straddle 边界检查使能：验证 Straddle TLP 的 beat 边界对齐规则
    bit                         straddle_boundary_check         = 1'b1;

    //-------------------------------------------------------------------------
    // 参数组 15：统一内存接入（默认关，关时走原 sparse mem_space）
    //-------------------------------------------------------------------------
    // 统一内存总使能：0=沿用原 sparse mem_space；1=使用 host_mem_pkg 管理器
    bit                          use_unified_mem  = 1'b0;
    // 内存访问模式：PER_BUFFER=序列显式 alloc/free；PREMAP=env 预映射有界窗口
    xilinx_mem_access_mode_e     mem_access_mode  = XILINX_MEM_PER_BUFFER;
    // PREMAP 模式下预映射窗口的基地址
    bit [63:0]                   premap_base      = 64'h0;
    // PREMAP 模式下预映射窗口大小（字节），默认 16MB
    int unsigned                 premap_size      = 32'h0100_0000; // 16MB（有界）
    // 透传 host_mem：分配器算法（如 MODE_BUDDY）
    alloc_mode_e                 mem_alloc_mode   = MODE_BUDDY;     // 透传 host_mem
    // 透传 host_mem：最小分配粒度（字节）
    int unsigned                 mem_granule      = 16;             // 透传 host_mem

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_env_config");
        super.new(name);
        _init_bar_cfg();
        _init_channel_bw_cfg();
    endfunction

    //=========================================================================
    // 私有初始化函数
    //=========================================================================

    // 初始化 BAR 配置：BAR0 默认为 64KB 内存空间，其余 BAR 全部禁用
    local function void _init_bar_cfg();
        // BAR0：64KB 内存空间，32 位非可预取
        bar_cfg[0].enable       = 1'b1;
        bar_cfg[0].is_64bit     = 1'b0;
        bar_cfg[0].is_prefetch  = 1'b0;
        bar_cfg[0].is_io        = 1'b0;
        bar_cfg[0].size         = 64'h0001_0000;   // 64KB
        bar_cfg[0].base_addr    = 64'h0;

        // BAR1~BAR5：默认全部禁用
        for (int i = 1; i < 6; i++) begin
            bar_cfg[i].enable       = 1'b0;
            bar_cfg[i].is_64bit     = 1'b0;
            bar_cfg[i].is_prefetch  = 1'b0;
            bar_cfg[i].is_io        = 1'b0;
            bar_cfg[i].size         = 64'h0;
            bar_cfg[i].base_addr    = 64'h0;
        end
    endfunction : _init_bar_cfg

    // 初始化各通道独立带宽配置：默认全部使用全局参数兼容默认值
    local function void _init_channel_bw_cfg();
        for (int i = 0; i < 4; i++) begin
            // 默认 valid 模式：无空闲（与全局 tx_valid_mode 初始值一致）
            channel_bw_cfg[i].valid_mode    = VALID_ZERO_IDLE;
            // 默认 ready 模式：始终拉高（与全局 rx_ready_mode 初始值一致）
            channel_bw_cfg[i].ready_mode    = READY_ALWAYS;
            channel_bw_cfg[i].idle_cycles   = 0;
            channel_bw_cfg[i].valid_weight  = 100;
            channel_bw_cfg[i].ready_weight  = 100;
            channel_bw_cfg[i].burst_len     = 0;
            channel_bw_cfg[i].pause_len     = 0;
        end
    endfunction : _init_channel_bw_cfg

    //=========================================================================
    // tuser 宽度查询方法（委托给 types 文件中的全局函数）
    //=========================================================================

    // 返回 RQ 通道的 tuser 位宽
    function int get_rq_tuser_width();
        return xilinx_get_rq_tuser_width(DATA_WIDTH);
    endfunction : get_rq_tuser_width

    // 返回 RC 通道的 tuser 位宽
    function int get_rc_tuser_width();
        return xilinx_get_rc_tuser_width(DATA_WIDTH);
    endfunction : get_rc_tuser_width

    // 返回 CQ 通道的 tuser 位宽
    function int get_cq_tuser_width();
        return xilinx_get_cq_tuser_width(DATA_WIDTH);
    endfunction : get_cq_tuser_width

    // 返回 CC 通道的 tuser 位宽
    function int get_cc_tuser_width();
        return xilinx_get_cc_tuser_width(DATA_WIDTH);
    endfunction : get_cc_tuser_width

    //=========================================================================
    // do_copy：深拷贝全部字段，修正 clone() 丢字段问题
    // env 用 cfg.clone() 分别构造 rc_cfg / ep_cfg，必须复制所有字段，
    // 否则 test 设置的值（如 use_unified_mem、per_channel_bw_config 等）
    // 在 agent 端会回退成默认值。
    //=========================================================================
    virtual function void do_copy(uvm_object rhs);
        xilinx_pcie_env_config o;
        super.do_copy(rhs);
        if (!$cast(o, rhs)) return;

        // 参数组 1：角色与激活模式
        this.role                       = o.role;
        this.is_active                  = o.is_active;

        // 参数组 2：AXI-Stream 数据位宽
        this.DATA_WIDTH                 = o.DATA_WIDTH;

        // 参数组 3：Straddle 模式
        this.straddle_enable            = o.straddle_enable;

        // 参数组 4：PCIe 链路能力参数
        this.max_payload_size           = o.max_payload_size;
        this.max_read_request_size      = o.max_read_request_size;
        this.read_completion_boundary   = o.read_completion_boundary;
        this.link_speed                 = o.link_speed;
        this.link_width                 = o.link_width;

        // 参数组 5：Tag 管理参数
        this.extended_tag_enable        = o.extended_tag_enable;
        this.max_outstanding            = o.max_outstanding;

        // 参数组 6：流量控制参数
        this.fc_enable                  = o.fc_enable;
        this.infinite_credit            = o.infinite_credit;
        this.init_ph_credit             = o.init_ph_credit;
        this.init_pd_credit             = o.init_pd_credit;
        this.init_nph_credit            = o.init_nph_credit;
        this.init_npd_credit            = o.init_npd_credit;
        this.init_cplh_credit           = o.init_cplh_credit;
        this.init_cpld_credit           = o.init_cpld_credit;

        // 参数组 7：排序参数
        this.relaxed_ordering_enable    = o.relaxed_ordering_enable;
        this.id_based_ordering_enable   = o.id_based_ordering_enable;
        this.bypass_ordering            = o.bypass_ordering;

        // 参数组 8：配置空间参数
        this.cfg_enable                 = o.cfg_enable;
        this.vendor_id                  = o.vendor_id;
        this.device_id                  = o.device_id;
        this.class_code                 = o.class_code;
        this.subsys_vendor_id           = o.subsys_vendor_id;
        this.subsys_device_id           = o.subsys_device_id;
        foreach (o.bar_cfg[i]) this.bar_cfg[i] = o.bar_cfg[i];

        // 参数组 9：中断参数
        this.interrupt_enable           = o.interrupt_enable;
        this.interrupt_mode             = o.interrupt_mode;
        this.msi_vector_count           = o.msi_vector_count;
        this.msix_table_size            = o.msix_table_size;
        this.msix_table_bar             = o.msix_table_bar;
        this.msix_table_offset          = o.msix_table_offset;
        this.msix_pba_bar               = o.msix_pba_bar;
        this.msix_pba_offset            = o.msix_pba_offset;

        // 参数组 10：AXI-Stream 带宽控制参数
        this.tx_valid_mode              = o.tx_valid_mode;
        this.rx_ready_mode              = o.rx_ready_mode;
        this.tx_idle_cycles             = o.tx_idle_cycles;
        this.tx_valid_weight            = o.tx_valid_weight;
        this.rx_ready_weight            = o.rx_ready_weight;
        this.per_channel_bw_config      = o.per_channel_bw_config;
        foreach (o.channel_bw_cfg[i]) this.channel_bw_cfg[i] = o.channel_bw_cfg[i];

        // 参数组 11：EP 自动响应参数
        this.ep_auto_response           = o.ep_auto_response;
        this.response_delay_min         = o.response_delay_min;
        this.response_delay_max         = o.response_delay_max;
        this.mem_size                   = o.mem_size;

        // 参数组 12：超时参数
        this.cpl_timeout_ns             = o.cpl_timeout_ns;

        // 参数组 13：Scoreboard 与功能覆盖率开关
        this.scb_enable                 = o.scb_enable;
        this.scb_completion_check       = o.scb_completion_check;
        this.scb_data_integrity         = o.scb_data_integrity;
        this.scb_ordering_check         = o.scb_ordering_check;
        this.scb_descriptor_check       = o.scb_descriptor_check;
        this.cov_enable                 = o.cov_enable;
        this.cov_tlp_type               = o.cov_tlp_type;
        this.cov_descriptor             = o.cov_descriptor;
        this.cov_tuser                  = o.cov_tuser;
        this.cov_straddle               = o.cov_straddle;
        this.cov_channel                = o.cov_channel;
        this.cov_fc                     = o.cov_fc;

        // 参数组 14：协议检查开关
        this.rq_protocol_check_enable   = o.rq_protocol_check_enable;
        this.rc_protocol_check_enable   = o.rc_protocol_check_enable;
        this.cq_protocol_check_enable   = o.cq_protocol_check_enable;
        this.cc_protocol_check_enable   = o.cc_protocol_check_enable;
        this.desc_format_check_enable   = o.desc_format_check_enable;
        this.tuser_consistency_check    = o.tuser_consistency_check;
        this.payload_alignment_check    = o.payload_alignment_check;
        this.straddle_boundary_check    = o.straddle_boundary_check;

        // 参数组 15：统一内存接入
        this.use_unified_mem            = o.use_unified_mem;
        this.mem_access_mode            = o.mem_access_mode;
        this.premap_base                = o.premap_base;
        this.premap_size                = o.premap_size;
        this.mem_alloc_mode             = o.mem_alloc_mode;
        this.mem_granule                = o.mem_granule;
    endfunction : do_copy

    //=========================================================================
    // 参数合法性验证
    // 返回 1 表示全部合法，返回 0 表示存在非法配置（同时打印 uvm_error）
    //=========================================================================
    function bit validate();
        bit ok = 1'b1;

        // 检查数据位宽必须是 64/128/256/512 之一
        if (DATA_WIDTH != 64 && DATA_WIDTH != 128 &&
            DATA_WIDTH != 256 && DATA_WIDTH != 512) begin
            `uvm_error("XILINX_PCIE_CFG",
                $sformatf("[validate] DATA_WIDTH=%0d 非法，必须为 64/128/256/512", DATA_WIDTH))
            ok = 1'b0;
        end

        // Straddle 需要数据位宽 >= 256
        if (straddle_enable && DATA_WIDTH < 256) begin
            `uvm_error("XILINX_PCIE_CFG",
                $sformatf("[validate] straddle_enable=1 时 DATA_WIDTH 必须 >= 256，当前 DATA_WIDTH=%0d",
                          DATA_WIDTH))
            ok = 1'b0;
        end

        // MPS 必须是 2 的幂次且在 [128, 4096] 范围内
        if (max_payload_size < 128 || max_payload_size > 4096 ||
            (max_payload_size & (max_payload_size - 1)) != 0) begin
            `uvm_error("XILINX_PCIE_CFG",
                $sformatf("[validate] max_payload_size=%0d 非法，必须为 128~4096 的 2 的幂次",
                          max_payload_size))
            ok = 1'b0;
        end

        // MRRS 必须是 2 的幂次且在 [128, 4096] 范围内
        if (max_read_request_size < 128 || max_read_request_size > 4096 ||
            (max_read_request_size & (max_read_request_size - 1)) != 0) begin
            `uvm_error("XILINX_PCIE_CFG",
                $sformatf("[validate] max_read_request_size=%0d 非法，必须为 128~4096 的 2 的幂次",
                          max_read_request_size))
            ok = 1'b0;
        end

        // RCB 只能是 64 或 128
        if (read_completion_boundary != 64 && read_completion_boundary != 128) begin
            `uvm_error("XILINX_PCIE_CFG",
                $sformatf("[validate] read_completion_boundary=%0d 非法，必须为 64 或 128",
                          read_completion_boundary))
            ok = 1'b0;
        end

        return ok;
    endfunction : validate

    //=========================================================================
    // 创建指定通道的 axis_config 对象
    // 根据 role、channel 及带宽配置正确设置 axis_config 各字段
    // 返回配置好的 axis_config 实例，供 agent 传入 axis VIP
    //=========================================================================
    function axis_config create_axis_config(xilinx_channel_e ch);
        axis_config cfg;

        // 步骤 1：通过工厂创建 axis_config 实例
        cfg = axis_config::type_id::create("axis_cfg");

        // 步骤 2：设置数据/控制宽度参数
        cfg.TDATA_WIDTH = DATA_WIDTH;   // tdata 位宽与 PCIe 数据位宽对应
        cfg.TID_WIDTH   = 1;            // TID 不使用，设为最小值 1
        cfg.TDEST_WIDTH = 1;            // TDEST 不使用，设为最小值 1
        cfg.HAS_TSTRB   = 0;            // PCIe AXI-Stream 不使用 tstrb
        cfg.HAS_TKEEP   = 1;            // PCIe AXI-Stream 使用 tkeep 指示有效字节
        cfg.HAS_TLAST   = 1;            // PCIe AXI-Stream 使用 tlast 标记 TLP 结束

        // 步骤 3：根据通道设置 tuser 位宽
        case (ch)
            XILINX_CH_RQ: cfg.TUSER_WIDTH = get_rq_tuser_width();
            XILINX_CH_RC: cfg.TUSER_WIDTH = get_rc_tuser_width();
            XILINX_CH_CQ: cfg.TUSER_WIDTH = get_cq_tuser_width();
            XILINX_CH_CC: cfg.TUSER_WIDTH = get_cc_tuser_width();
            default: begin
                `uvm_fatal("XILINX_PCIE_CFG",
                    $sformatf("[create_axis_config] 未知通道 %s", ch.name()))
            end
        endcase

        // 步骤 4：设置包边界模式为 TLAST 触发
        cfg.pkt_boundary_mode = PKT_BOUNDARY_TLAST;

        // 步骤 5：根据 role + channel 设置 agent_mode
        // 在回环 BFM 中，RC agent 模拟链路侧（IP 侧），EP agent 模拟用户侧。
        // RC 角色（模拟链路侧，向 EP 驱动 CQ/RC，从 EP 接收 RQ/CC）：
        //   RQ -> AXIS_SLAVE （接收 EP 发来的 DMA 请求）
        //   RC -> AXIS_MASTER（向 EP 驱动完成数据）
        //   CQ -> AXIS_MASTER（向 EP 驱动请求）
        //   CC -> AXIS_SLAVE （接收 EP 发来的完成数据）
        // EP 角色（标准用户侧视角）：
        //   RQ -> AXIS_MASTER（EP 发送 DMA 请求）
        //   RC -> AXIS_SLAVE （EP 接收完成数据）
        //   CQ -> AXIS_SLAVE （EP 接收来自 RC 的请求）
        //   CC -> AXIS_MASTER（EP 发送完成数据）
        if (role == XILINX_PCIE_RC) begin
            case (ch)
                XILINX_CH_RQ: cfg.agent_mode = AXIS_SLAVE;
                XILINX_CH_RC: cfg.agent_mode = AXIS_MASTER;
                XILINX_CH_CQ: cfg.agent_mode = AXIS_MASTER;
                XILINX_CH_CC: cfg.agent_mode = AXIS_SLAVE;
                default: cfg.agent_mode = AXIS_MASTER;
            endcase
        end else begin  // XILINX_PCIE_EP
            case (ch)
                XILINX_CH_RQ: cfg.agent_mode = AXIS_MASTER;
                XILINX_CH_RC: cfg.agent_mode = AXIS_SLAVE;
                XILINX_CH_CQ: cfg.agent_mode = AXIS_SLAVE;
                XILINX_CH_CC: cfg.agent_mode = AXIS_MASTER;
                default: cfg.agent_mode = AXIS_MASTER;
            endcase
        end

        // 步骤 6：传递激活/被动模式
        cfg.is_active = this.is_active;

        // 步骤 7：应用带宽配置
        // 若启用通道独立带宽配置，则从 channel_bw_cfg[] 读取；否则使用全局参数
        if (per_channel_bw_config) begin
            // 通道索引：RQ=0, RC=1, CQ=2, CC=3（与 xilinx_channel_e 编码一致）
            int idx = int'(ch);
            cfg.valid_gen_mode  = channel_bw_cfg[idx].valid_mode;
            cfg.ready_gen_mode  = channel_bw_cfg[idx].ready_mode;
            cfg.idle_cycles     = channel_bw_cfg[idx].idle_cycles;
            cfg.valid_weight    = channel_bw_cfg[idx].valid_weight;
            cfg.ready_weight    = channel_bw_cfg[idx].ready_weight;
            cfg.burst_len       = channel_bw_cfg[idx].burst_len;
            cfg.pause_len       = channel_bw_cfg[idx].pause_len;
        end else begin
            // 使用全局带宽参数：TX 通道（MASTER）用 tx_*，RX 通道（SLAVE）用 rx_*
            if (cfg.agent_mode == AXIS_MASTER) begin
                cfg.valid_gen_mode  = tx_valid_mode;
                cfg.idle_cycles     = tx_idle_cycles;
                cfg.valid_weight    = tx_valid_weight;
                // MASTER 侧不控制 ready，但仍设置默认值
                cfg.ready_gen_mode  = READY_ALWAYS;
                cfg.ready_weight    = 100;
            end else begin
                cfg.ready_gen_mode  = rx_ready_mode;
                cfg.ready_weight    = rx_ready_weight;
                // SLAVE 侧不控制 valid，但仍设置默认值
                cfg.valid_gen_mode  = VALID_ZERO_IDLE;
                cfg.idle_cycles     = 0;
                cfg.valid_weight    = 100;
            end
        end

        return cfg;
    endfunction : create_axis_config

endclass : xilinx_pcie_env_config

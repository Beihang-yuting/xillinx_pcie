//=============================================================================
// Xilinx PCIe TL-Layer BFM - 功能覆盖率收集器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：通过 uvm_subscriber 的 write() 回调接收 TLP，采样 6 个 covergroup：
//   1. cg_tlp_type     : TLP 类型分布
//   2. cg_descriptor   : 描述符关键字段取值分布
//   3. cg_tuser        : tuser sideband 字段分布
//   4. cg_straddle     : Straddle 模式覆盖
//   5. cg_channel      : AXI-Stream 通道事务分布
//   6. cg_fc           : 流量控制 credit 水位分布
//
// 各 covergroup 均有独立使能开关，由 xilinx_pcie_env_config 控制。
//=============================================================================

class xilinx_pcie_coverage extends uvm_subscriber #(pcie_tl_tlp);

    `uvm_component_utils(xilinx_pcie_coverage)

    //=========================================================================
    // 配置
    //=========================================================================

    // 环境配置对象：提供各 covergroup 的使能开关
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 采样变量（从 write() 回调中提取，供 covergroup 引用）
    //=========================================================================

    // TLP 类型采样变量
    tlp_kind_e          sampled_kind;
    tlp_category_e      sampled_category;
    xilinx_channel_e    sampled_channel;

    // 描述符字段采样变量
    xilinx_req_type_e   sampled_req_type;
    xilinx_addr_type_e  sampled_addr_type;
    bit [9:0]           sampled_dw_count;
    bit [3:0]           sampled_first_be;
    bit [3:0]           sampled_last_be;
    xilinx_cpl_status_e sampled_cpl_status;
    bit [9:0]           sampled_tag;
    bit                 sampled_poisoned;

    // tuser 字段采样变量
    bit                 sampled_tph_present;
    bit [1:0]           sampled_tph_type;
    bit                 sampled_discontinue;
    bit [3:0]           sampled_addr_offset;

    // Straddle 采样变量
    bit                 sampled_straddle_occurred;
    bit [1:0]           sampled_sop_pattern;    // {sop1, sop0}
    bit [1:0]           sampled_eof_pattern;    // {eof1, eof0}

    // 通道状态采样变量
    bit                 sampled_ch_valid;
    bit                 sampled_ch_ready;

    // FC credit 水位采样变量（分类别）
    int                 sampled_fc_credit;
    tlp_category_e      sampled_fc_category;

    //=========================================================================
    // Covergroup 1：TLP 类型覆盖率
    //=========================================================================
    covergroup cg_tlp_type;
        option.per_instance = 1;
        option.name         = "cg_tlp_type";

        // TLP 种类 bins
        cp_kind: coverpoint sampled_kind {
            bins mem_rd     = {TLP_MEM_RD};
            bins mem_rd_lk  = {TLP_MEM_RD_LK};
            bins mem_wr     = {TLP_MEM_WR};
            bins io_rd      = {TLP_IO_RD};
            bins io_wr      = {TLP_IO_WR};
            bins cfg_rd0    = {TLP_CFG_RD0};
            bins cfg_wr0    = {TLP_CFG_WR0};
            bins cfg_rd1    = {TLP_CFG_RD1};
            bins cfg_wr1    = {TLP_CFG_WR1};
            bins cpl        = {TLP_CPL};
            bins cpld       = {TLP_CPLD};
            bins cpl_lk     = {TLP_CPL_LK};
            bins cpld_lk    = {TLP_CPLD_LK};
            bins msg        = {TLP_MSG};
            bins msgd       = {TLP_MSGD};
            bins atomic_fa  = {TLP_ATOMIC_FETCHADD};
            bins atomic_sw  = {TLP_ATOMIC_SWAP};
            bins atomic_cas = {TLP_ATOMIC_CAS};
        }

        // TLP 类别 bins
        cp_category: coverpoint sampled_category {
            bins posted     = {TLP_CAT_POSTED};
            bins non_posted = {TLP_CAT_NON_POSTED};
            bins completion = {TLP_CAT_COMPLETION};
        }

        // 通道 bins
        cp_channel: coverpoint sampled_channel {
            bins rq = {XILINX_CH_RQ};
            bins rc = {XILINX_CH_RC};
            bins cq = {XILINX_CH_CQ};
            bins cc = {XILINX_CH_CC};
        }

        // kind x channel 交叉覆盖
        cx_kind_channel: cross cp_kind, cp_channel;
    endgroup : cg_tlp_type

    //=========================================================================
    // Covergroup 2：描述符字段覆盖率
    //=========================================================================
    covergroup cg_descriptor;
        option.per_instance = 1;
        option.name         = "cg_descriptor";

        // 请求类型
        cp_req_type: coverpoint sampled_req_type {
            bins mrd        = {XILINX_REQ_MRD};
            bins mwr        = {XILINX_REQ_MWR};
            bins iord       = {XILINX_REQ_IORD};
            bins iowr       = {XILINX_REQ_IOWR};
            bins mrd_lk     = {XILINX_REQ_MRD_LK};
            bins fetch_add  = {XILINX_REQ_FETCH_ADD};
            bins swap       = {XILINX_REQ_SWAP};
            bins cas        = {XILINX_REQ_CAS};
        }

        // 地址类型
        cp_addr_type: coverpoint sampled_addr_type {
            bins untranslated = {XILINX_ADDR_UNTRANSLATED};
            bins trans_req    = {XILINX_ADDR_TRANS_REQ};
            bins translated   = {XILINX_ADDR_TRANSLATED};
        }

        // DW 计数分段
        cp_dw_count: coverpoint sampled_dw_count {
            bins dw_single  = {1};
            bins dw_small   = {[2:16]};
            bins dw_medium  = {[17:128]};
            bins dw_large   = {[129:512]};
            bins max_range  = {[513:1023]};
            bins max_1024   = {0};          // 0 表示 1024 DW
        }

        // First BE
        cp_first_be: coverpoint sampled_first_be {
            bins all_enabled  = {4'hF};
            bins partial[]    = {4'h1, 4'h3, 4'h7, 4'hE, 4'hC, 4'h8};
            bins zero         = {4'h0};
        }

        // Last BE
        cp_last_be: coverpoint sampled_last_be {
            bins all_enabled  = {4'hF};
            bins partial[]    = {4'h1, 4'h3, 4'h7, 4'hE, 4'hC, 4'h8};
            bins zero         = {4'h0};
        }

        // First BE x Last BE 交叉
        cx_be: cross cp_first_be, cp_last_be;

        // Completion 状态
        cp_cpl_status: coverpoint sampled_cpl_status {
            bins sc  = {XILINX_CPL_SC};
            bins ur  = {XILINX_CPL_UR};
            bins crs = {XILINX_CPL_CRS};
            bins ca  = {XILINX_CPL_CA};
        }

        // Tag 范围
        cp_tag: coverpoint sampled_tag {
            bins low      = {[0:31]};
            bins mid      = {[32:255]};
            bins extended = {[256:1023]};
        }

        // Poisoned 标志
        cp_poisoned: coverpoint sampled_poisoned {
            bins clean    = {1'b0};
            bins poisoned = {1'b1};
        }
    endgroup : cg_descriptor

    //=========================================================================
    // Covergroup 3：tuser 字段覆盖率
    //=========================================================================
    covergroup cg_tuser;
        option.per_instance = 1;
        option.name         = "cg_tuser";

        // TPH 存在标志
        cp_tph_present: coverpoint sampled_tph_present {
            bins no_tph  = {1'b0};
            bins has_tph = {1'b1};
        }

        // TPH 类型
        cp_tph_type: coverpoint sampled_tph_type {
            bins type_0 = {2'b00};
            bins type_1 = {2'b01};
            bins type_2 = {2'b10};
            bins type_3 = {2'b11};
        }

        // Discontinue 标志
        cp_discontinue: coverpoint sampled_discontinue {
            bins normal      = {1'b0};
            bins discontinue = {1'b1};
        }

        // 地址偏移（对齐模式）
        cp_addr_offset: coverpoint sampled_addr_offset {
            bins aligned   = {4'h0};
            bins offset_4  = {4'h4};
            bins offset_8  = {4'h8};
            bins offset_c  = {4'hC};
            bins others    = default;
        }
    endgroup : cg_tuser

    //=========================================================================
    // Covergroup 4：Straddle 模式覆盖率
    //=========================================================================
    covergroup cg_straddle;
        option.per_instance = 1;
        option.name         = "cg_straddle";

        // Straddle 发生标志
        cp_straddle: coverpoint sampled_straddle_occurred {
            bins no_straddle = {1'b0};
            bins straddle    = {1'b1};
        }

        // SOP 模式组合
        cp_sop: coverpoint sampled_sop_pattern {
            bins none    = {2'b00};
            bins sop0    = {2'b01};
            bins sop1    = {2'b10};
            bins both    = {2'b11};
        }

        // EOF 模式组合
        cp_eof: coverpoint sampled_eof_pattern {
            bins none    = {2'b00};
            bins eof0    = {2'b01};
            bins eof1    = {2'b10};
            bins both    = {2'b11};
        }

        // SOP x EOF 交叉
        cx_sop_eof: cross cp_sop, cp_eof;
    endgroup : cg_straddle

    //=========================================================================
    // Covergroup 5：AXI-Stream 通道覆盖率
    //=========================================================================
    covergroup cg_channel;
        option.per_instance = 1;
        option.name         = "cg_channel";

        // 通道选择
        cp_channel: coverpoint sampled_channel {
            bins rq = {XILINX_CH_RQ};
            bins rc = {XILINX_CH_RC};
            bins cq = {XILINX_CH_CQ};
            bins cc = {XILINX_CH_CC};
        }

        // valid 状态
        cp_valid: coverpoint sampled_ch_valid {
            bins inactive = {1'b0};
            bins active   = {1'b1};
        }

        // ready 状态
        cp_ready: coverpoint sampled_ch_ready {
            bins inactive = {1'b0};
            bins active   = {1'b1};
        }

        // {valid, ready} 状态组合
        cx_handshake: cross cp_channel, cp_valid, cp_ready;
    endgroup : cg_channel

    //=========================================================================
    // Covergroup 6：流量控制 credit 水位覆盖率
    //=========================================================================
    covergroup cg_fc;
        option.per_instance = 1;
        option.name         = "cg_fc";

        // FC 类别
        cp_fc_category: coverpoint sampled_fc_category {
            bins posted     = {TLP_CAT_POSTED};
            bins non_posted = {TLP_CAT_NON_POSTED};
            bins completion = {TLP_CAT_COMPLETION};
        }

        // Credit 水位分段
        cp_fc_level: coverpoint sampled_fc_credit {
            bins empty      = {0};
            bins low        = {[1:4]};
            bins normal     = {[5:32]};
            bins high       = {[33:$]};
        }

        // 类别 x 水位交叉
        cx_fc: cross cp_fc_category, cp_fc_level;
    endgroup : cg_fc

    //=========================================================================
    // 构造函数：创建所有 covergroup
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);

        // 创建 6 个 covergroup
        cg_tlp_type   = new();
        cg_descriptor = new();
        cg_tuser      = new();
        cg_straddle   = new();
        cg_channel    = new();
        cg_fc         = new();
    endfunction : new

    //=========================================================================
    // build_phase：获取配置
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // 从 config_db 获取配置（可选，也可由 env 直接设置）
        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info(get_type_name(),
                "未在 config_db 中找到 cfg，等待 env 直接赋值", UVM_MEDIUM)
        end
    endfunction : build_phase

    //=========================================================================
    // write()：uvm_subscriber 回调，接收 TLP 并采样对应 covergroup
    //=========================================================================
    virtual function void write(pcie_tl_tlp t);
        pcie_tl_mem_tlp    mem_tlp;
        pcie_tl_cpl_tlp    cpl_tlp;

        if (cfg == null) return;

        // -----------------------------------------------------------------
        // 提取通用采样变量
        // -----------------------------------------------------------------
        sampled_kind     = t.kind;
        sampled_category = t.get_category();
        sampled_tag      = t.tag;
        sampled_poisoned = t.ep_bit;

        // 推断通道：根据 TLP 类别推断所属 AXI-Stream 通道
        // RC 侧：Non-Posted/Posted -> RQ，Completion -> RC
        // EP 侧：Non-Posted/Posted -> CQ，Completion -> CC
        // 此处简化为 RC 视角
        case (sampled_category)
            TLP_CAT_POSTED:     sampled_channel = XILINX_CH_RQ;
            TLP_CAT_NON_POSTED: sampled_channel = XILINX_CH_RQ;
            TLP_CAT_COMPLETION: sampled_channel = XILINX_CH_RC;
            default:            sampled_channel = XILINX_CH_RQ;
        endcase

        // -----------------------------------------------------------------
        // 提取描述符字段采样变量
        // -----------------------------------------------------------------
        sampled_dw_count = t.length;
        sampled_first_be = 4'hF;   // 默认值
        sampled_last_be  = 4'h0;   // 默认值

        // 尝试提取 mem_tlp 特有字段
        if ($cast(mem_tlp, t)) begin
            sampled_first_be  = mem_tlp.first_be;
            sampled_last_be   = mem_tlp.last_be;
            sampled_addr_type = XILINX_ADDR_UNTRANSLATED;

            // 推断请求类型
            case (t.kind)
                TLP_MEM_RD:    sampled_req_type = XILINX_REQ_MRD;
                TLP_MEM_RD_LK: sampled_req_type = XILINX_REQ_MRD_LK;
                TLP_MEM_WR:    sampled_req_type = XILINX_REQ_MWR;
                default:       sampled_req_type = XILINX_REQ_MRD;
            endcase
        end else begin
            // IO 类型
            case (t.kind)
                TLP_IO_RD:  sampled_req_type = XILINX_REQ_IORD;
                TLP_IO_WR:  sampled_req_type = XILINX_REQ_IOWR;
                default:    sampled_req_type = XILINX_REQ_MRD;
            endcase
            sampled_addr_type = XILINX_ADDR_UNTRANSLATED;
        end

        // 提取 Completion 状态
        if ($cast(cpl_tlp, t)) begin
            case (cpl_tlp.cpl_status)
                CPL_STATUS_SC:  sampled_cpl_status = XILINX_CPL_SC;
                CPL_STATUS_UR:  sampled_cpl_status = XILINX_CPL_UR;
                CPL_STATUS_CRS: sampled_cpl_status = XILINX_CPL_CRS;
                CPL_STATUS_CA:  sampled_cpl_status = XILINX_CPL_CA;
                default:        sampled_cpl_status = XILINX_CPL_SC;
            endcase
        end else begin
            sampled_cpl_status = XILINX_CPL_SC;
        end

        // -----------------------------------------------------------------
        // tuser 采样变量（简化：从 TLP 字段推断）
        // -----------------------------------------------------------------
        sampled_tph_present = t.th;
        sampled_tph_type    = 2'b00;
        sampled_discontinue = 1'b0;
        sampled_addr_offset = 4'h0;

        // -----------------------------------------------------------------
        // Straddle 采样变量（简化：默认无 straddle）
        // -----------------------------------------------------------------
        sampled_straddle_occurred = 1'b0;
        sampled_sop_pattern       = 2'b01;  // 单 TLP，SOP0 有效
        sampled_eof_pattern       = 2'b01;  // 单 TLP，EOF0 有效

        // -----------------------------------------------------------------
        // 通道状态采样变量（简化：收到 TLP 即 valid=1, ready=1）
        // -----------------------------------------------------------------
        sampled_ch_valid = 1'b1;
        sampled_ch_ready = 1'b1;

        // -----------------------------------------------------------------
        // FC credit 采样变量（简化：使用固定默认值）
        // -----------------------------------------------------------------
        sampled_fc_category = sampled_category;
        sampled_fc_credit   = 16;  // 默认 normal 水位

        // -----------------------------------------------------------------
        // 根据使能开关采样对应的 covergroup
        // -----------------------------------------------------------------
        if (cfg.cov_tlp_type) begin
            cg_tlp_type.sample();
        end

        if (cfg.cov_descriptor) begin
            cg_descriptor.sample();
        end

        if (cfg.cov_tuser) begin
            cg_tuser.sample();
        end

        if (cfg.cov_straddle) begin
            cg_straddle.sample();
        end

        if (cfg.cov_channel) begin
            cg_channel.sample();
        end

        if (cfg.cov_fc) begin
            cg_fc.sample();
        end
    endfunction : write

endclass : xilinx_pcie_coverage

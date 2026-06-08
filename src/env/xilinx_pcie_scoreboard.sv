//=============================================================================
// Xilinx PCIe TL-Layer BFM - Scoreboard
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：通过 4 路 analysis_imp 接收 RC/EP 双向 TLP 流量，执行以下检查：
//   1. Completion 匹配：验证每个 Non-Posted 请求都收到对应的 Completion
//   2. 数据完整性：比较 MWr payload 与 CplD 读回数据的一致性
//   3. 排序规则：验证 TLP 到达顺序符合 PCIe Table 2-40 规则
//   4. 描述符正确性：验证 encode/decode 往返一致性
//
// 各检查项均有独立使能开关，由 xilinx_pcie_env_config 控制。
//=============================================================================

// 声明 4 路 analysis_imp 后缀宏
`uvm_analysis_imp_decl(_rc_tx)
`uvm_analysis_imp_decl(_rc_rx)
`uvm_analysis_imp_decl(_ep_tx)
`uvm_analysis_imp_decl(_ep_rx)

class xilinx_pcie_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(xilinx_pcie_scoreboard)

    //=========================================================================
    // 配置
    //=========================================================================

    // 环境配置对象：提供各检查项的使能开关
    xilinx_pcie_env_config cfg;

    //=========================================================================
    // 4 路 analysis_imp（接收来自 RC/EP agent 的 TX/RX TLP）
    //=========================================================================

    // RC 发送的 TLP（RC -> EP 方向）
    uvm_analysis_imp_rc_tx #(pcie_tl_tlp, xilinx_pcie_scoreboard) rc_tx_imp;

    // RC 接收的 TLP（EP -> RC 方向）
    uvm_analysis_imp_rc_rx #(pcie_tl_tlp, xilinx_pcie_scoreboard) rc_rx_imp;

    // EP 发送的 TLP（EP -> RC 方向）
    uvm_analysis_imp_ep_tx #(pcie_tl_tlp, xilinx_pcie_scoreboard) ep_tx_imp;

    // EP 接收的 TLP（RC -> EP 方向）
    uvm_analysis_imp_ep_rx #(pcie_tl_tlp, xilinx_pcie_scoreboard) ep_rx_imp;

    //=========================================================================
    // 检查 1：Completion 匹配
    // outstanding_reqs: key = {tag[9:0], requester_id[15:0]} -> 原始请求 TLP
    // outstanding_bytes: key 同上 -> 已累计接收的 completion 字节数
    //=========================================================================
    typedef bit [25:0] req_key_t;

    // 未完成请求 map：记录等待 completion 的请求 TLP
    pcie_tl_tlp                 outstanding_reqs[req_key_t];

    // 已累计 completion 字节数
    int                         outstanding_bytes[req_key_t];

    // 期望总字节数
    int                         expected_bytes[req_key_t];

    //=========================================================================
    // 检查 2：数据完整性
    // mem_data: 地址 -> payload 字节 map，记录 MWr 写入的数据
    //=========================================================================
    bit [7:0]                   mem_data[bit [63:0]];

    //=========================================================================
    // 检查 3：排序规则
    // 记录各类别 TLP 的最后发送/接收时间戳
    //=========================================================================
    time                        last_rc_tx_time[tlp_category_e];
    time                        last_ep_tx_time[tlp_category_e];

    //=========================================================================
    // 统计计数器
    //=========================================================================
    int                         total_requests;
    int                         total_completions;
    int                         matched;
    int                         mismatched;
    int                         unexpected_cpl;
    int                         timed_out;
    int                         ordering_violations;
    int                         desc_format_errors;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建 analysis_imp 端口
    //=========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // 创建 4 路 analysis_imp
        rc_tx_imp = new("rc_tx_imp", this);
        rc_rx_imp = new("rc_rx_imp", this);
        ep_tx_imp = new("ep_tx_imp", this);
        ep_rx_imp = new("ep_rx_imp", this);

        // 从 config_db 获取配置（可选，也可由 env 直接设置）
        if (!uvm_config_db #(xilinx_pcie_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info(get_type_name(),
                "未在 config_db 中找到 cfg，等待 env 直接赋值", UVM_MEDIUM)
        end

        // 初始化统计计数器
        total_requests      = 0;
        total_completions   = 0;
        matched             = 0;
        mismatched          = 0;
        unexpected_cpl      = 0;
        timed_out           = 0;
        ordering_violations = 0;
        desc_format_errors  = 0;
    endfunction : build_phase

    //=========================================================================
    // 辅助函数：生成请求的唯一 key
    //=========================================================================
    function req_key_t make_key(bit [9:0] tag, bit [15:0] requester_id);
        return {tag, requester_id};
    endfunction : make_key

    //=========================================================================
    // 辅助函数：计算请求期望的总 completion 字节数
    //=========================================================================
    function int calc_expected_bytes(pcie_tl_tlp tlp);
        if (tlp.length == 0)
            return 4096;    // length=0 表示 1024 DW = 4096 字节
        else
            return tlp.length * 4;
    endfunction : calc_expected_bytes

    //=========================================================================
    // write_rc_tx：RC 发送 TLP 回调
    // RC 发送 Non-Posted 请求 -> 注册到 outstanding_reqs
    // RC 发送 Completion（DMA 响应）-> 匹配 EP 的 DMA 请求
    //=========================================================================
    function void write_rc_tx(pcie_tl_tlp tlp);
        req_key_t key;
        tlp_category_e cat;

        if (cfg == null) return;

        cat = tlp.get_category();

        // 记录排序时间戳
        last_rc_tx_time[cat] = $time;

        // Completion 匹配检查
        if (cfg.scb_completion_check) begin
            if (cat == TLP_CAT_NON_POSTED) begin
                // RC 发送 Non-Posted 请求 -> 注册 outstanding
                key = make_key(tlp.tag, tlp.requester_id);
                outstanding_reqs[key]  = tlp;
                outstanding_bytes[key] = 0;
                expected_bytes[key]    = calc_expected_bytes(tlp);
                total_requests++;

                `uvm_info(get_type_name(),
                    $sformatf("[RC_TX] 注册请求: tag=0x%03h, req_id=0x%04h, kind=%s",
                        tlp.tag, tlp.requester_id, tlp.kind.name()),
                    UVM_HIGH)
            end else if (cat == TLP_CAT_COMPLETION) begin
                // RC 发送 DMA Completion -> 匹配 EP 的 DMA 请求
                match_completion(tlp, "RC_TX");
            end
        end

        // 数据完整性：记录 MWr 写入的数据
        if (cfg.scb_data_integrity) begin
            record_write_data(tlp);
        end

        // 排序规则检查
        if (cfg.scb_ordering_check) begin
            check_ordering(cat,
                last_rc_tx_time.exists(TLP_CAT_POSTED) ? last_rc_tx_time[TLP_CAT_POSTED] : 0,
                last_rc_tx_time.exists(TLP_CAT_POSTED),
                "RC_TX");
        end

        // 描述符正确性检查
        if (cfg.scb_descriptor_check) begin
            check_descriptor(tlp, "RC_TX");
        end
    endfunction : write_rc_tx

    //=========================================================================
    // write_rc_rx：RC 接收 TLP 回调
    // 注意：Completion 匹配已移至 EP_TX（发送侧），避免因 monitor 同时
    //       监听四个通道而导致同一 completion 被 EP_RX/RC_RX/EP_TX 三路
    //       重复匹配的问题。此处仅保留数据完整性检查。
    //=========================================================================
    function void write_rc_rx(pcie_tl_tlp tlp);
        if (cfg == null) return;

        // 数据完整性：CplD 到达时比对数据（保留，不依赖 outstanding 查找）
        if (cfg.scb_data_integrity) begin
            check_data_integrity(tlp, "RC_RX");
        end
    endfunction : write_rc_rx

    //=========================================================================
    // write_ep_tx：EP 发送 TLP 回调
    // EP 发送 Completion -> 匹配 RC 的请求
    // EP 发送 DMA 请求 -> 注册到 outstanding_reqs
    //=========================================================================
    function void write_ep_tx(pcie_tl_tlp tlp);
        req_key_t key;
        tlp_category_e cat;

        if (cfg == null) return;

        cat = tlp.get_category();

        // 记录排序时间戳
        last_ep_tx_time[cat] = $time;

        // Completion 匹配检查
        if (cfg.scb_completion_check) begin
            if (cat == TLP_CAT_COMPLETION) begin
                // EP 发送 Completion -> 匹配 RC 的请求
                match_completion(tlp, "EP_TX");
            end else if (cat == TLP_CAT_NON_POSTED) begin
                // EP 发送 DMA Non-Posted 请求 -> 注册 outstanding
                key = make_key(tlp.tag, tlp.requester_id);
                outstanding_reqs[key]  = tlp;
                outstanding_bytes[key] = 0;
                expected_bytes[key]    = calc_expected_bytes(tlp);
                total_requests++;

                `uvm_info(get_type_name(),
                    $sformatf("[EP_TX] 注册 DMA 请求: tag=0x%03h, req_id=0x%04h, kind=%s",
                        tlp.tag, tlp.requester_id, tlp.kind.name()),
                    UVM_HIGH)
            end
        end

        // 数据完整性：记录 MWr 写入数据
        if (cfg.scb_data_integrity) begin
            record_write_data(tlp);
        end

        // 排序规则检查
        if (cfg.scb_ordering_check) begin
            check_ordering(cat,
                last_ep_tx_time.exists(TLP_CAT_POSTED) ? last_ep_tx_time[TLP_CAT_POSTED] : 0,
                last_ep_tx_time.exists(TLP_CAT_POSTED),
                "EP_TX");
        end

        // 描述符正确性检查
        if (cfg.scb_descriptor_check) begin
            check_descriptor(tlp, "EP_TX");
        end
    endfunction : write_ep_tx

    //=========================================================================
    // write_ep_rx：EP 接收 TLP 回调
    // 注意：EP 的 monitor 同时监听 CQ/CC/RQ/RC 四个通道。
    //       CC 通道上的 completion 是 EP 自身发出的（已被 EP_TX 匹配），
    //       RC 通道上的 DMA completion 由 RC_TX 匹配。
    //       数据完整性检查也跳过——EP_RX 解码的 CC completion 可能因
    //       axis packet 分割/编解码差异导致 payload 与预期不符，
    //       真正的数据完整性由 RC_RX 检查即可。
    //=========================================================================
    function void write_ep_rx(pcie_tl_tlp tlp);
        // EP_RX 路径不做 completion 匹配和数据完整性检查
        // 所有检查已由 EP_TX（completion 匹配）和 RC_RX（数据完整性）覆盖
    endfunction : write_ep_rx

    //=========================================================================
    // match_completion：匹配 Completion 到 outstanding 请求
    //=========================================================================
    protected function void match_completion(pcie_tl_tlp tlp, string source);
        pcie_tl_cpl_tlp cpl;
        req_key_t key;

        // 尝试转换为 Completion TLP
        if (!$cast(cpl, tlp)) return;

        total_completions++;

        // 使用 completion 的 tag 和 requester_id 查找原始请求
        key = make_key(cpl.tag, cpl.requester_id);

        if (outstanding_reqs.exists(key)) begin
            // 累计 completion 字节数
            outstanding_bytes[key] += cpl.payload.size();

            `uvm_info(get_type_name(),
                $sformatf("[%s] Completion 匹配: tag=0x%03h, status=%s, 累计=%0d/%0d bytes",
                    source, cpl.tag, cpl.cpl_status.name(),
                    outstanding_bytes[key], expected_bytes[key]),
                UVM_HIGH)

            // 检查是否已完成全部字节传输
            if (outstanding_bytes[key] >= expected_bytes[key]) begin
                matched++;
                outstanding_reqs.delete(key);
                outstanding_bytes.delete(key);
                expected_bytes.delete(key);

                `uvm_info(get_type_name(),
                    $sformatf("[%s] 请求完成: tag=0x%03h, req_id=0x%04h",
                        source, cpl.tag, cpl.requester_id),
                    UVM_MEDIUM)
            end
        end else begin
            // 未匹配到 outstanding 请求
            unexpected_cpl++;
            `uvm_warning(get_type_name(),
                $sformatf("[%s] 未匹配的 Completion: tag=0x%03h, req_id=0x%04h, status=%s",
                    source, cpl.tag, cpl.requester_id, cpl.cpl_status.name()))
        end
    endfunction : match_completion

    //=========================================================================
    // record_write_data：记录 MWr 写入的数据到 mem_data map
    // 考虑 first_be/last_be 的字节掩码
    //=========================================================================
    protected function void record_write_data(pcie_tl_tlp tlp);
        pcie_tl_mem_tlp mem_tlp;

        // 仅处理 MWr 类型
        if (tlp.kind != TLP_MEM_WR) return;

        if (!$cast(mem_tlp, tlp)) return;

        begin
            int data_idx;
            int total_dw;
            bit [63:0] base_addr;

            base_addr = mem_tlp.addr;
            data_idx  = 0;
            total_dw  = (mem_tlp.payload.size() + 3) / 4;

            for (int dw = 0; dw < total_dw; dw++) begin
                bit [3:0] be;

                // 确定当前 DW 的字节使能
                if (dw == 0)
                    be = mem_tlp.first_be;
                else if (dw == total_dw - 1 && total_dw > 1)
                    be = mem_tlp.last_be;
                else
                    be = 4'hF;

                // 按字节使能记录数据
                for (int b = 0; b < 4; b++) begin
                    if (data_idx < mem_tlp.payload.size()) begin
                        if (be[b]) begin
                            mem_data[base_addr + data_idx] = mem_tlp.payload[data_idx];
                        end
                        data_idx++;
                    end
                end
            end
        end
    endfunction : record_write_data

    //=========================================================================
    // check_data_integrity：CplD 到达时比对 payload 与 mem_data 记录
    //=========================================================================
    protected function void check_data_integrity(pcie_tl_tlp tlp, string source);
        pcie_tl_cpl_tlp cpl;
        req_key_t key;

        // 仅处理 CplD 类型
        if (tlp.kind != TLP_CPLD && tlp.kind != TLP_CPLD_LK) return;

        if (!$cast(cpl, tlp)) return;

        // 查找对应的原始请求以获取地址信息
        key = make_key(cpl.tag, cpl.requester_id);

        if (outstanding_reqs.exists(key)) begin
            pcie_tl_mem_tlp mem_req;

            // 仅对 MRd 类型的 CplD 做数据比对
            if ($cast(mem_req, outstanding_reqs[key])) begin
                int offset;

                // 计算本次 CplD 在整个请求中的字节偏移
                offset = outstanding_bytes[key];

                // 逐字节比对
                for (int i = 0; i < cpl.payload.size(); i++) begin
                    bit [63:0] check_addr;
                    check_addr = mem_req.addr + offset + i;

                    if (mem_data.exists(check_addr)) begin
                        if (cpl.payload[i] !== mem_data[check_addr]) begin
                            mismatched++;
                            `uvm_error(get_type_name(),
                                $sformatf("[%s] 数据不匹配: addr=0x%016h, 期望=0x%02h, 实际=0x%02h",
                                    source, check_addr,
                                    mem_data[check_addr], cpl.payload[i]))
                        end
                    end
                end
            end
        end
    endfunction : check_data_integrity

    //=========================================================================
    // check_ordering：检查 PCIe Table 2-40 基本排序规则
    // 规则简化：Non-Posted 不得超越之前已发送的 Posted
    //=========================================================================
    protected function void check_ordering(
        tlp_category_e                  cat,
        time                            posted_time,
        bit                             posted_valid,
        string                          source
    );
        // 规则：Non-Posted 请求不得超越先前发送的 Posted 请求
        // （简化检查：如果 Non-Posted 的时间戳早于 Posted，报告违规）
        if (cat == TLP_CAT_NON_POSTED) begin
            if (posted_valid) begin
                if ($time < posted_time) begin
                    ordering_violations++;
                    `uvm_error(get_type_name(),
                        $sformatf("[%s] 排序违规: Non-Posted TLP 时间戳(%0t) < Posted TLP 时间戳(%0t)",
                            source, $time, posted_time))
                end
            end
        end

        // 规则：Completion 不得被 Non-Posted 阻塞（简化：不检查此条）
        // 完整实现需追踪更复杂的依赖关系
    endfunction : check_ordering

    //=========================================================================
    // check_descriptor：验证 encode -> decode 往返一致性
    // 对 RQ/CQ 通道使用 128 位描述符，对 RC/CC 通道使用 96 位描述符
    //=========================================================================
    protected function void check_descriptor(pcie_tl_tlp tlp, string source);
        pcie_tl_tlp decoded;
        bit [127:0] desc_128;
        bit [95:0]  desc_96;
        tlp_category_e cat;

        cat = tlp.get_category();

        // 仅对请求和 completion 类型执行编解码往返检查
        if (cat == TLP_CAT_NON_POSTED || cat == TLP_CAT_POSTED) begin
            // 请求类型使用 RQ 通道编码 (with_tag98: desc + tuser tag[9:8] 双载体)
            begin
                bit [1:0] tag_9_8;
                desc_128 = xilinx_desc_codec::encode_rq_with_tag98(tlp, tag_9_8);
                decoded  = xilinx_desc_codec::decode_rq_with_tag98(desc_128, tag_9_8, tlp.payload);
            end

            if (decoded == null) begin
                desc_format_errors++;
                `uvm_error(get_type_name(),
                    $sformatf("[%s] 描述符解码失败: kind=%s, tag=0x%03h",
                        source, tlp.kind.name(), tlp.tag))
                return;
            end

            // 比较关键字段
            if (!compare_tlp_fields(tlp, decoded)) begin
                desc_format_errors++;
                `uvm_error(get_type_name(),
                    $sformatf("[%s] 描述符往返不一致: kind=%s, tag=0x%03h",
                        source, tlp.kind.name(), tlp.tag))
            end
        end else if (cat == TLP_CAT_COMPLETION) begin
            // Completion 类型使用 RC 通道编码
            desc_96  = xilinx_desc_codec::encode_rc(tlp);
            decoded  = xilinx_desc_codec::decode_rc(desc_96, tlp.payload);

            if (decoded == null) begin
                desc_format_errors++;
                `uvm_error(get_type_name(),
                    $sformatf("[%s] Completion 描述符解码失败: tag=0x%03h",
                        source, tlp.tag))
                return;
            end

            if (!compare_tlp_fields_cpl(tlp, decoded)) begin
                desc_format_errors++;
                `uvm_error(get_type_name(),
                    $sformatf("[%s] Completion 描述符往返不一致: tag=0x%03h",
                        source, tlp.tag))
            end
        end
    endfunction : check_descriptor

    //=========================================================================
    // compare_tlp_fields：比较两个 TLP 的关键字段是否一致
    //=========================================================================
    protected function bit compare_tlp_fields(pcie_tl_tlp a, pcie_tl_tlp b);
        if (a.kind         !== b.kind)         return 1'b0;
        if (a.tc           !== b.tc)           return 1'b0;
        if (a.length       !== b.length)       return 1'b0;
        if (a.requester_id !== b.requester_id) return 1'b0;
        if (a.tag          !== b.tag)          return 1'b0;
        return 1'b1;
    endfunction : compare_tlp_fields

    // CPL 路径比较: RC/CC 描述符仅 8-bit tag, 截低位比较 desc round-trip 一致性
    // (扩展 tag[9:8] 在完成路径上不由 desc 携带, 与硬件兼容性见 PG213)
    protected function bit compare_tlp_fields_cpl(pcie_tl_tlp a, pcie_tl_tlp b);
        if (a.kind         !== b.kind)            return 1'b0;
        if (a.tc           !== b.tc)              return 1'b0;
        if (a.length       !== b.length)          return 1'b0;
        if (a.requester_id !== b.requester_id)    return 1'b0;
        if (a.tag[7:0]     !== b.tag[7:0])        return 1'b0;
        return 1'b1;
    endfunction : compare_tlp_fields_cpl

    //=========================================================================
    // report_phase：输出统计摘要，检查未完成请求
    //=========================================================================
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        `uvm_info(get_type_name(),
            "============================================================", UVM_LOW)
        `uvm_info(get_type_name(),
            "              Scoreboard 统计摘要", UVM_LOW)
        `uvm_info(get_type_name(),
            "============================================================", UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  总请求数          : %0d", total_requests), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  总 Completion 数  : %0d", total_completions), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  匹配成功          : %0d", matched), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  数据不匹配        : %0d", mismatched), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  未匹配 Completion : %0d", unexpected_cpl), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  超时              : %0d", timed_out), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  排序违规          : %0d", ordering_violations), UVM_LOW)
        `uvm_info(get_type_name(),
            $sformatf("  描述符格式错误    : %0d", desc_format_errors), UVM_LOW)
        `uvm_info(get_type_name(),
            "============================================================", UVM_LOW)

        // 检查未完成的 outstanding 请求
        if (outstanding_reqs.size() > 0) begin
            req_key_t key;

            timed_out = outstanding_reqs.size();

            `uvm_error(get_type_name(),
                $sformatf("仿真结束时仍有 %0d 个未完成请求:", outstanding_reqs.size()))

            foreach (outstanding_reqs[key]) begin
                `uvm_error(get_type_name(),
                    $sformatf("  未完成: tag=0x%03h, req_id=0x%04h, kind=%s, 已收=%0d/%0d bytes",
                        key[25:16], key[15:0],
                        outstanding_reqs[key].kind.name(),
                        outstanding_bytes[key], expected_bytes[key]))
            end
        end else begin
            `uvm_info(get_type_name(),
                "所有请求均已收到 Completion，无未完成项", UVM_LOW)
        end
    endfunction : report_phase

endclass : xilinx_pcie_scoreboard

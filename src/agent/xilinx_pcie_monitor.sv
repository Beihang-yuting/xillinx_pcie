//=============================================================================
// Xilinx PCIe TL-Layer BFM - PCIe TLP Monitor
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：监听 4 个 axis_agent 的 monitor 输出（axis_packet），
//       将 AXI-Stream 包解码回 pcie_tl_tlp 对象，并发布到分析端口。
//
// 使用 UVM analysis_imp 宏实现多端口接收：
//   - write_rq: 接收 RQ 通道的 axis_packet
//   - write_rc: 接收 RC 通道的 axis_packet
//   - write_cq: 接收 CQ 通道的 axis_packet
//   - write_cc: 接收 CC 通道的 axis_packet
//
// 每个回调的解码流程：
//   1. 从 axis_packet.beats 收集 tdata, tkeep, tuser
//   2. tkeep 从 per-byte 压缩回 per-DW
//   3. 调用 straddle_eng.unpack_single_tlp() 提取 descriptor + payload
//   4. 调用 tuser_codec.decode_XX_tuser() 提取 tag[9:8] 等
//   5. 调用 xilinx_desc_codec.decode_XX() 创建 pcie_tl_tlp
//   6. 合并 tag[9:8] 到 tlp.tag
//   7. 发布到 tlp_rx_ap
//
// axis_transfer.tuser 容器已加宽到 512 位，各通道 PG213 tuser 字段完整可见。
//=============================================================================

// analysis_imp 宏声明（必须在 class 定义之前）
`uvm_analysis_imp_decl(_rq)
`uvm_analysis_imp_decl(_rc)
`uvm_analysis_imp_decl(_cq)
`uvm_analysis_imp_decl(_cc)

class xilinx_pcie_monitor extends uvm_component;

    `uvm_component_utils(xilinx_pcie_monitor)

    //=========================================================================
    // 分析端口
    //=========================================================================

    // 四个 analysis import：接收来自 axis_monitor 的 axis_packet
    uvm_analysis_imp_rq #(axis_packet, xilinx_pcie_monitor) rq_imp;
    uvm_analysis_imp_rc #(axis_packet, xilinx_pcie_monitor) rc_imp;
    uvm_analysis_imp_cq #(axis_packet, xilinx_pcie_monitor) cq_imp;
    uvm_analysis_imp_cc #(axis_packet, xilinx_pcie_monitor) cc_imp;

    // TLP 接收分析端口：每解码一个 TLP 后广播
    uvm_analysis_port #(pcie_tl_tlp) tlp_rx_ap;

    // 错误侧信道：每触发一次本地协议检查（malformed 等）即广播一个
    // xilinx_pcie_error_item，经 env 的 per-agent error tap 转发到中央 collector。
    uvm_analysis_port #(xilinx_pcie_error_item) err_ap;

    //=========================================================================
    // 成员变量（由父 agent 在 connect_phase 中设置）
    //=========================================================================

    // tuser 编解码器实例
    xilinx_tuser_codec          tuser_codec;

    // Straddle 拆包引擎实例
    xilinx_straddle_engine      straddle_eng;

    // 环境配置对象
    xilinx_pcie_env_config      cfg;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建分析端口和 import
    //=========================================================================
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // 创建四个 analysis import
        rq_imp = new("rq_imp", this);
        rc_imp = new("rc_imp", this);
        cq_imp = new("cq_imp", this);
        cc_imp = new("cc_imp", this);

        // 创建 TLP 接收分析端口
        tlp_rx_ap = new("tlp_rx_ap", this);

        // 创建错误侧信道端口
        err_ap = new("err_ap", this);
    endfunction : build_phase

    //=========================================================================
    // publish_error：构造 error_item 并经 err_ap 发布到中央 collector
    // 在每个本地协议检查 uvm_error 现场调用（与该处 uvm_error 并存，不替代）
    //=========================================================================
    protected function void publish_error(string err_type);
        xilinx_pcie_error_item it;
        it = xilinx_pcie_error_item::type_id::create("err_item");
        it.err_type = err_type;
        err_ap.write(it);
    endfunction : publish_error

    //=========================================================================
    // inject_check_tlp：定向注入钩子（仅供 err_inject 测试使用）
    // 直接以调用方构造的 TLP + 通道运行真实的 run_protocol_checks，
    // 用于逐条触发各协议检查 TYPE，验证 publish_error -> tap -> collector 路由。
    // 不影响正常 write_* 解码路径。
    //=========================================================================
    function void inject_check_tlp(pcie_tl_tlp tlp, xilinx_channel_e channel);
        if (tlp != null)
            run_protocol_checks(tlp, channel);
    endfunction : inject_check_tlp

    //=========================================================================
    // write_rq：RQ 通道回调 - 解码 RQ axis_packet 为 pcie_tl_tlp
    //=========================================================================
    function void write_rq(axis_packet pkt);
        pcie_tl_tlp tlp;
        `uvm_info(get_type_name(),
            $sformatf("RQ 通道收到 axis_packet, beats=%0d", pkt.beats.size()),
            UVM_HIGH)
        tlp = decode_packet(pkt, XILINX_CH_RQ);
        if (tlp != null)
            tlp_rx_ap.write(tlp);
    endfunction : write_rq

    //=========================================================================
    // write_rc：RC 通道回调 - 解码 RC axis_packet 为 pcie_tl_tlp
    //=========================================================================
    function void write_rc(axis_packet pkt);
        pcie_tl_tlp tlp;
        `uvm_info(get_type_name(),
            $sformatf("RC 通道收到 axis_packet, beats=%0d", pkt.beats.size()),
            UVM_HIGH)
        tlp = decode_packet(pkt, XILINX_CH_RC);
        if (tlp != null)
            tlp_rx_ap.write(tlp);
    endfunction : write_rc

    //=========================================================================
    // write_cq：CQ 通道回调 - 解码 CQ axis_packet 为 pcie_tl_tlp
    //=========================================================================
    function void write_cq(axis_packet pkt);
        pcie_tl_tlp tlp;
        `uvm_info(get_type_name(),
            $sformatf("CQ 通道收到 axis_packet, beats=%0d", pkt.beats.size()),
            UVM_HIGH)
        tlp = decode_packet(pkt, XILINX_CH_CQ);
        if (tlp != null)
            tlp_rx_ap.write(tlp);
    endfunction : write_cq

    //=========================================================================
    // write_cc：CC 通道回调 - 解码 CC axis_packet 为 pcie_tl_tlp
    //=========================================================================
    function void write_cc(axis_packet pkt);
        pcie_tl_tlp tlp;
        `uvm_info(get_type_name(),
            $sformatf("CC 通道收到 axis_packet, beats=%0d", pkt.beats.size()),
            UVM_HIGH)
        tlp = decode_packet(pkt, XILINX_CH_CC);
        if (tlp != null)
            tlp_rx_ap.write(tlp);
    endfunction : write_cc

    //=========================================================================
    // decode_packet：通用解码流程
    // 从 axis_packet 的 beat 序列中提取 descriptor + payload，
    // 再调用对应通道的 desc_codec.decode 创建 pcie_tl_tlp
    //=========================================================================
    protected function pcie_tl_tlp decode_packet(
        axis_packet      pkt,
        xilinx_channel_e channel
    );
        // 中间变量
        bit [511:0]  beats[$];       // tdata 队列
        bit [15:0]   keeps[$];       // per-DW tkeep 队列
        bit [127:0]  descriptor;     // 解码后的描述符
        bit [7:0]    payload[$];     // 解码后的 payload 字节队列
        bit [7:0]    payload_arr[];  // 转为动态数组供 codec 使用
        bit [511:0]  first_tuser;    // 首 beat 的 tuser（用于提取 tag[9:8]）
        bit [1:0]    tag_9_8;        // Tag 高 2 位
        pcie_tl_tlp  tlp;

        // -----------------------------------------------------------------
        // 步骤 1：从 axis_packet.beats 收集 tdata, tkeep, tuser
        // -----------------------------------------------------------------
        if (pkt.beats.size() == 0) begin
            // 本地协议检查：空 axis_packet 属 malformed（axis_monitor 正常流量
            // 始终至少含 1 个 beat，故 clean run 永不触发；仅注入时出现）。
            `uvm_error(get_type_name(), "decode_packet: 收到空的 axis_packet（malformed）")
            publish_error("MALFORMED");
            return null;
        end

        // 记录首 beat 的 tuser（用于后续提取 tag_9_8）
        first_tuser = pkt.beats[0].tuser;

        foreach (pkt.beats[i]) begin
            beats.push_back(pkt.beats[i].tdata);

            // -----------------------------------------------------------------
            // 步骤 2：tkeep 从 per-byte（64 位）压缩为 per-DW（16 位）
            // 调用 driver 的静态方法进行转换
            // -----------------------------------------------------------------
            keeps.push_back(
                xilinx_pcie_driver::compress_byte_keep_to_dw(pkt.beats[i].tkeep));
        end

        // -----------------------------------------------------------------
        // 步骤 3：调用 straddle_eng.unpack_single_tlp() 提取 descriptor + payload
        // -----------------------------------------------------------------
        straddle_eng.unpack_single_tlp(beats, keeps, channel, descriptor, payload);

        // 将 payload 队列转为动态数组（codec 接口要求动态数组）
        payload_arr = new[payload.size()];
        foreach (payload[i])
            payload_arr[i] = payload[i];

        // -----------------------------------------------------------------
        // 步骤 4：调用 tuser_codec.decode_XX_tuser() 提取 tag[9:8] 等扩展字段
        // -----------------------------------------------------------------
        tag_9_8 = extract_tag_9_8(first_tuser, channel);

        // -----------------------------------------------------------------
        // 步骤 5：调用 xilinx_desc_codec.decode_XX() 创建 pcie_tl_tlp
        // -----------------------------------------------------------------
        case (channel)
            XILINX_CH_RQ: begin
                tlp = xilinx_desc_codec::decode_rq(descriptor, payload_arr);
            end

            XILINX_CH_RC: begin
                // RC 描述符仅 96 位，取 descriptor 低 96 位
                tlp = xilinx_desc_codec::decode_rc(descriptor[95:0], payload_arr);
            end

            XILINX_CH_CQ: begin
                tlp = xilinx_desc_codec::decode_cq(descriptor, payload_arr);
            end

            XILINX_CH_CC: begin
                // CC 描述符仅 96 位
                tlp = xilinx_desc_codec::decode_cc(descriptor[95:0], payload_arr);
            end

            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("decode_packet: 未知通道 %s", channel.name()))
                publish_error("MALFORMED");
                return null;
            end
        endcase

        // -----------------------------------------------------------------
        // 步骤 6：合并 tag[9:8] 到 tlp.tag（codec 仅设置了低 8 位）
        //         同时从 tuser 提取 first_be/last_be 回写到 TLP（CQ/RQ 通道）
        //         CQ/RQ 描述符中不含 byte enable，需从 tuser 补充
        // -----------------------------------------------------------------
        if (tlp != null) begin
            tlp.tag[9:8] = tag_9_8;

            // 从 tuser 提取 first_be/last_be 并回写到解码后的 TLP
            apply_tuser_be(tlp, first_tuser, channel);

            `uvm_info(get_type_name(),
                $sformatf("解码 %s 通道 TLP: %s, tag=0x%03h, payload=%0d bytes",
                    channel.name(), tlp.kind.name(), tlp.tag, tlp.payload.size()),
                UVM_MEDIUM)

            // 步骤 7：在已解码 TLP 上运行协议检查（按 env_config 开关分别门控）
            run_protocol_checks(tlp, channel);
        end

        return tlp;
    endfunction : decode_packet

    //=========================================================================
    // run_protocol_checks：在已解码 pcie_tl_tlp 上运行 PG213 协议合规检查
    //
    // 仅使用 decode 路径实际可得的字段（kind/fmt/length/tag/payload，以及
    // mem_tlp 的 addr/first_be/last_be）。每项检查由 env_config 对应开关门控，
    // 违规时 uvm_error + publish_error("<TYPE>")，经 err_ap -> error tap ->
    // collector 进入中央 PROTO_ERR 统计。
    //
    // 设计原则（防误报）：所有不变式对合法流量恒成立——
    //   * payload 字节数恒为整 DW（unpack 按 tkeep 逐 DW 收集），故
    //     WITH_DATA 时 payload.size()==length*4（length==0 视作 1024DW=4096B）；
    //     NO_DATA 时 payload.size()==0（由 c_no_data_no_payload + unpack 保证）。
    //   * RQ/CQ 解码恒产出请求类 TLP，RC/CC 解码恒产出完成类 TLP。
    //   * 合法写请求 first_be 恒非零（c_legal_be）。
    //   * 分配 tag 恒 < max_outstanding（tag pool 上界）。
    //=========================================================================
    protected function void run_protocol_checks(
        pcie_tl_tlp      tlp,
        xilinx_channel_e channel
    );
        pcie_tl_mem_tlp  mem_tlp;
        tlp_category_e   cat;
        int              exp_bytes;
        bit              is_data;
        bit              ch_proto_en;
        int              tag_space;

        if (cfg == null) return;  // 无配置时不检查（被动/单元场景安全退化）

        cat     = tlp.get_category();
        is_data = tlp.has_data();

        //---------------------------------------------------------------------
        // 检查 1：每通道协议方向合法性
        // <ch>_protocol_check_enable -> TYPE: RQ_PROTO/RC_PROTO/CQ_PROTO/CC_PROTO
        // RQ/CQ 承载请求（非完成）；RC/CC 承载完成
        //---------------------------------------------------------------------
        case (channel)
            XILINX_CH_RQ: ch_proto_en = cfg.rq_protocol_check_enable;
            XILINX_CH_RC: ch_proto_en = cfg.rc_protocol_check_enable;
            XILINX_CH_CQ: ch_proto_en = cfg.cq_protocol_check_enable;
            XILINX_CH_CC: ch_proto_en = cfg.cc_protocol_check_enable;
            default:      ch_proto_en = 1'b0;
        endcase

        if (ch_proto_en) begin
            case (channel)
                XILINX_CH_RQ, XILINX_CH_CQ: begin
                    // 请求通道：到达的 TLP 不得为完成类
                    if (cat == TLP_CAT_COMPLETION) begin
                        string ty = (channel == XILINX_CH_RQ) ? "RQ_PROTO" : "CQ_PROTO";
                        `uvm_error(get_type_name(),
                            $sformatf("%s 通道收到完成类 TLP（kind=%s），请求通道不应承载完成",
                                channel.name(), tlp.kind.name()))
                        publish_error(ty);
                    end
                end
                XILINX_CH_RC, XILINX_CH_CC: begin
                    // 完成通道：到达的 TLP 必须为完成类
                    if (cat != TLP_CAT_COMPLETION) begin
                        string ty = (channel == XILINX_CH_RC) ? "RC_PROTO" : "CC_PROTO";
                        `uvm_error(get_type_name(),
                            $sformatf("%s 通道收到非完成类 TLP（kind=%s），完成通道只应承载完成",
                                channel.name(), tlp.kind.name()))
                        publish_error(ty);
                    end
                end
                default: ;
            endcase
        end

        //---------------------------------------------------------------------
        // 检查 2：描述符格式 - tag 落在配置的 tag 空间内
        // desc_format_check_enable -> TYPE: DESC_FORMAT
        // tag pool 上界 = min(max_outstanding, extended?1024:256)；分配 tag 恒 < 该界
        //---------------------------------------------------------------------
        if (cfg.desc_format_check_enable) begin
            int hw_max = cfg.extended_tag_enable ? 1024 : 256;
            tag_space  = (cfg.max_outstanding < hw_max) ? cfg.max_outstanding : hw_max;
            if (int'(tlp.tag) >= tag_space) begin
                `uvm_error(get_type_name(),
                    $sformatf("%s DESC_FORMAT: tag=0x%03h 超出配置 tag 空间 [0,%0d)",
                        channel.name(), tlp.tag, tag_space))
                publish_error("DESC_FORMAT");
            end
        end

        //---------------------------------------------------------------------
        // 检查 3：tuser 一致性 - 写请求 first_be 必须非零
        // tuser_consistency_check -> TYPE: TUSER
        // 仅对 RQ/CQ 携带数据的请求（length>=1）检查；first_be 来自 tuser
        // （由 apply_tuser_be 回写到 mem_tlp）。PG213：数据传输首 DW BE 不应全零。
        //---------------------------------------------------------------------
        if (cfg.tuser_consistency_check &&
            (channel == XILINX_CH_RQ || channel == XILINX_CH_CQ) &&
            is_data) begin
            if ($cast(mem_tlp, tlp)) begin
                if (mem_tlp.first_be == 4'h0) begin
                    `uvm_error(get_type_name(),
                        $sformatf("%s TUSER: 写请求 first_be=0（length=%0d, payload=%0d B），首 DW BE 不应全零",
                            channel.name(), tlp.length, tlp.payload.size()))
                    publish_error("TUSER");
                end
            end
        end

        //---------------------------------------------------------------------
        // 检查 4：payload 对齐 - payload 字节数与 length 字段一致
        // payload_alignment_check -> TYPE: PAYLOAD_ALIGN
        // WITH_DATA: payload.size()==length*4（length==0 -> 4096B=1024DW）
        // NO_DATA  : payload.size()==0
        //---------------------------------------------------------------------
        if (cfg.payload_alignment_check) begin
            if (is_data) begin
                exp_bytes = (tlp.length == 10'h0) ? 4096 : (int'(tlp.length) * 4);
                if (tlp.payload.size() != exp_bytes) begin
                    `uvm_error(get_type_name(),
                        $sformatf("%s PAYLOAD_ALIGN: payload=%0d B 与 length=%0d DW（期望 %0d B）不符",
                            channel.name(), tlp.payload.size(), tlp.length, exp_bytes))
                    publish_error("PAYLOAD_ALIGN");
                end
            end else begin
                if (tlp.payload.size() != 0) begin
                    `uvm_error(get_type_name(),
                        $sformatf("%s PAYLOAD_ALIGN: 无数据 TLP（fmt=%s）却带 %0d B payload",
                            channel.name(), tlp.fmt.name(), tlp.payload.size()))
                    publish_error("PAYLOAD_ALIGN");
                end
            end
        end
    endfunction : run_protocol_checks

    //=========================================================================
    // extract_tag_9_8：从首 beat 的 tuser 中提取 Tag 高 2 位
    // 根据通道类型选择正确的 decode 方法
    //=========================================================================
    protected function bit [1:0] extract_tag_9_8(
        bit [511:0]      tuser,
        xilinx_channel_e channel
    );
        bit [1:0] tag_9_8;
        tag_9_8 = 2'b00;

        case (channel)
            XILINX_CH_RQ: begin
                // RQ tuser 解码：提取 tag_9_8
                bit [3:0]   first_be;
                bit [3:0]   last_be;
                bit [2:0]   addr_offset;
                bit         discontinue;
                bit         tph_present;
                bit [1:0]   tph_type;
                bit [7:0]   tph_st_tag;
                bit [5:0]   seq_num_0;
                bit [5:0]   seq_num_1;

                tuser_codec.decode_rq_tuser(
                    .tuser       (tuser[284:0]),
                    .first_be    (first_be),
                    .last_be     (last_be),
                    .addr_offset (addr_offset),
                    .discontinue (discontinue),
                    .tph_present (tph_present),
                    .tph_type    (tph_type),
                    .tph_st_tag  (tph_st_tag),
                    .seq_num_0   (seq_num_0),
                    .seq_num_1   (seq_num_1),
                    .tag_9_8     (tag_9_8)
                );
            end

            XILINX_CH_CQ: begin
                // CQ tuser 解码：提取 tag_9_8
                bit [3:0]   first_be;
                bit [3:0]   last_be;
                bit [63:0]  byte_en;
                bit         sop;
                bit         sop_1;
                bit         discontinue;
                bit         tph_present;
                bit [1:0]   tph_type;
                bit [7:0]   tph_st_tag;
                bit         is_eop;
                bit [2:0]   eop_offset;
                bit         is_eop_1;
                bit [2:0]   eop_offset_1;

                tuser_codec.decode_cq_tuser(
                    .tuser        (tuser[374:0]),
                    .first_be     (first_be),
                    .last_be      (last_be),
                    .byte_en      (byte_en),
                    .sop          (sop),
                    .sop_1        (sop_1),
                    .discontinue  (discontinue),
                    .tph_present  (tph_present),
                    .tph_type     (tph_type),
                    .tph_st_tag   (tph_st_tag),
                    .is_eop       (is_eop),
                    .eop_offset   (eop_offset),
                    .is_eop_1     (is_eop_1),
                    .eop_offset_1 (eop_offset_1),
                    .tag_9_8      (tag_9_8)
                );
            end

            XILINX_CH_RC: begin
                // RC tuser 无 tag_9_8 字段，保持默认值 0
                tag_9_8 = 2'b00;
            end

            XILINX_CH_CC: begin
                // CC tuser 无 tag_9_8 字段，保持默认值 0
                tag_9_8 = 2'b00;
            end

            default: begin
                tag_9_8 = 2'b00;
            end
        endcase

        return tag_9_8;
    endfunction : extract_tag_9_8

    //=========================================================================
    // apply_tuser_be：从首 beat tuser 中提取 first_be/last_be 并回写到 TLP
    // CQ/RQ 描述符不含 byte enable 字段，必须从 tuser 补充
    // 否则 EP auto-response 的 mem_write 会因 first_be=0 跳过首尾 DW 写入
    //=========================================================================
    protected function void apply_tuser_be(
        pcie_tl_tlp      tlp,
        bit [511:0]      tuser,
        xilinx_channel_e channel
    );
        pcie_tl_mem_tlp mem_tlp;
        pcie_tl_io_tlp  io_tlp;

        case (channel)
            XILINX_CH_RQ: begin
                // RQ tuser 包含 first_be/last_be，提取后回写到 mem_tlp
                bit [3:0]   first_be;
                bit [3:0]   last_be;
                bit [2:0]   addr_offset;
                bit         discontinue;
                bit         tph_present;
                bit [1:0]   tph_type;
                bit [7:0]   tph_st_tag;
                bit [5:0]   seq_num_0;
                bit [5:0]   seq_num_1;
                bit [1:0]   tag_9_8;

                tuser_codec.decode_rq_tuser(
                    .tuser       (tuser[284:0]),
                    .first_be    (first_be),
                    .last_be     (last_be),
                    .addr_offset (addr_offset),
                    .discontinue (discontinue),
                    .tph_present (tph_present),
                    .tph_type    (tph_type),
                    .tph_st_tag  (tph_st_tag),
                    .seq_num_0   (seq_num_0),
                    .seq_num_1   (seq_num_1),
                    .tag_9_8     (tag_9_8)
                );

                if ($cast(mem_tlp, tlp)) begin
                    mem_tlp.first_be = first_be;
                    mem_tlp.last_be  = last_be;
                end else if ($cast(io_tlp, tlp)) begin
                    io_tlp.first_be = first_be;
                end
            end

            XILINX_CH_CQ: begin
                // CQ tuser 包含 first_be/last_be，提取后回写到 mem_tlp
                bit [3:0]   first_be;
                bit [3:0]   last_be;
                bit [63:0]  byte_en;
                bit         sop;
                bit         sop_1;
                bit         discontinue;
                bit         tph_present;
                bit [1:0]   tph_type;
                bit [7:0]   tph_st_tag;
                bit         is_eop;
                bit [2:0]   eop_offset;
                bit         is_eop_1;
                bit [2:0]   eop_offset_1;
                bit [1:0]   tag_9_8;

                tuser_codec.decode_cq_tuser(
                    .tuser        (tuser[374:0]),
                    .first_be     (first_be),
                    .last_be      (last_be),
                    .byte_en      (byte_en),
                    .sop          (sop),
                    .sop_1        (sop_1),
                    .discontinue  (discontinue),
                    .tph_present  (tph_present),
                    .tph_type     (tph_type),
                    .tph_st_tag   (tph_st_tag),
                    .is_eop       (is_eop),
                    .eop_offset   (eop_offset),
                    .is_eop_1     (is_eop_1),
                    .eop_offset_1 (eop_offset_1),
                    .tag_9_8      (tag_9_8)
                );

                if ($cast(mem_tlp, tlp)) begin
                    mem_tlp.first_be = first_be;
                    mem_tlp.last_be  = last_be;
                end else if ($cast(io_tlp, tlp)) begin
                    io_tlp.first_be = first_be;
                end
            end

            // RC/CC 通道为 completion，无 first_be/last_be，跳过
            default: begin
            end
        endcase
    endfunction : apply_tuser_be

endclass : xilinx_pcie_monitor

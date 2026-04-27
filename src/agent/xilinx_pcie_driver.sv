//=============================================================================
// Xilinx PCIe TL-Layer BFM - PCIe TLP Driver
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：将上层序列产生的 pcie_tl_tlp 事务转换为 AXI-Stream beat 序列，
//       经由对应通道的 axis_sequencer 发送到 AXI-Stream 总线。
//
// 发送流水线（11 步）：
//   1. 从 seq_item_port 获取 TLP
//   2. 可选 Tag 分配（Non-Posted 请求）
//   3. 可选 FC credit 检查
//   4. 确定目标通道
//   5. 编码 descriptor
//   6. 组装 AXIS beats（straddle 引擎）
//   7. 编码 tuser（每个 beat）
//   8. 创建 axis_transfer 并发送
//   9. 消耗 FC credit
//   10. 发布到分析端口
//   11. item_done
//
// 注意：axis_transfer.tuser 仅 128 位宽，而 PG213 tuser 最大可达 375 位。
//       当 DATA_WIDTH >= 256 时，高位 tuser 字段会被截断。
//       若需完整 tuser 支持，须扩展 axis_transfer.tuser 宽度。
//=============================================================================

// 内部辅助 sequence：用于在指定 axis_sequencer 上发送单个 axis_transfer
// uvm_driver 不能直接调用 start_item/finish_item，必须通过 sequence 发送
class axis_oneshot_seq extends uvm_sequence #(axis_transfer);

    `uvm_object_utils(axis_oneshot_seq)

    // 待发送的 axis_transfer 事务
    axis_transfer xfer;

    function new(string name = "axis_oneshot_seq");
        super.new(name);
    endfunction : new

    virtual task body();
        // 通过 sequence 的 start_item/finish_item 将 xfer 发送到 sequencer
        start_item(xfer);
        finish_item(xfer);
    endtask : body

endclass : axis_oneshot_seq

class xilinx_pcie_driver extends uvm_driver #(pcie_tl_tlp);

    `uvm_component_utils(xilinx_pcie_driver)

    //=========================================================================
    // 成员变量（由父 agent 在 connect_phase 中设置）
    //=========================================================================

    // tuser 编解码器实例（需实例化，DATA_WIDTH 参数化）
    xilinx_tuser_codec          tuser_codec;

    // Straddle 组包引擎实例
    xilinx_straddle_engine      straddle_eng;

    // 通道路由器实例
    xilinx_pcie_channel_router  router;

    // Tag 管理器（可为 null，null 时跳过自动 Tag 分配）
    pcie_tl_tag_manager         tag_mgr;

    // 流量控制管理器（可为 null，null 时跳过 FC credit 检查）
    pcie_tl_fc_manager          fc_mgr;

    // 环境配置对象
    xilinx_pcie_env_config      cfg;

    // 四个 AXI-Stream 通道的 sequencer 引用（由父 agent 连接）
    axis_sequencer              rq_sqr;
    axis_sequencer              rc_sqr;
    axis_sequencer              cq_sqr;
    axis_sequencer              cc_sqr;

    // TLP 发送分析端口：每成功发送一个 TLP 后广播
    uvm_analysis_port #(pcie_tl_tlp) tlp_tx_ap;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // build_phase：创建分析端口
    //=========================================================================
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        tlp_tx_ap = new("tlp_tx_ap", this);
    endfunction : build_phase

    //=========================================================================
    // run_phase：TLP 发送流水线主循环
    //=========================================================================
    task run_phase(uvm_phase phase);
        pcie_tl_tlp tlp;

        forever begin
            // -----------------------------------------------------------------
            // 步骤 1：从 sequencer 获取下一个 TLP 事务
            // -----------------------------------------------------------------
            seq_item_port.get_next_item(tlp);

            // -----------------------------------------------------------------
            // 步骤 2：可选 Tag 分配（仅 Non-Posted 请求需要）
            // 如果 TLP 需要完成包响应且 tag_mgr 已配置，则分配唯一 Tag
            // -----------------------------------------------------------------
            if (tlp.requires_completion() && tag_mgr != null) begin
                tlp.tag = tag_mgr.alloc_tag(0);
                `uvm_info(get_type_name(),
                    $sformatf("分配 Tag=0x%03h 给 %s TLP", tlp.tag, tlp.kind.name()),
                    UVM_HIGH)
            end

            // -----------------------------------------------------------------
            // 步骤 3：可选 FC credit 检查
            // 若 fc_mgr 已配置且 FC 使能，等待直到有足够 credit
            // -----------------------------------------------------------------
            if (fc_mgr != null && fc_mgr.fc_enable) begin
                while (!fc_mgr.check_credit(tlp)) begin
                    `uvm_info(get_type_name(),
                        "等待 FC credit...", UVM_HIGH)
                    // 等待一个时钟周期后重试（避免忙等）
                    #1;
                end
            end

            // -----------------------------------------------------------------
            // 步骤 4-8：编码并发送
            // -----------------------------------------------------------------
            encode_and_send(tlp);

            // -----------------------------------------------------------------
            // 步骤 9：消耗 FC credit
            // -----------------------------------------------------------------
            if (fc_mgr != null) begin
                fc_mgr.consume_credit(tlp);
            end

            // -----------------------------------------------------------------
            // 步骤 10：发布到 TLP 发送分析端口
            // -----------------------------------------------------------------
            tlp_tx_ap.write(tlp);

            // -----------------------------------------------------------------
            // 步骤 11：通知 sequencer 事务已完成
            // -----------------------------------------------------------------
            seq_item_port.item_done();
        end
    endtask : run_phase

    //=========================================================================
    // encode_and_send：编码描述符、组装 beat、发送到 axis_sequencer
    // 涵盖步骤 4-8
    //=========================================================================
    protected task encode_and_send(pcie_tl_tlp tlp);
        xilinx_channel_e    channel;
        bit [127:0]         desc;
        bit [511:0]         beats[$];
        bit [15:0]          keeps[$];
        bit                 lasts[$];
        axis_sequencer      target_sqr;

        // -----------------------------------------------------------------
        // 步骤 4：确定目标 AXI-Stream 通道
        // -----------------------------------------------------------------
        channel = router.get_tx_channel(tlp);
        `uvm_info(get_type_name(),
            $sformatf("TLP %s -> 通道 %s", tlp.kind.name(), channel.name()),
            UVM_HIGH)

        // -----------------------------------------------------------------
        // 步骤 5：编码 descriptor
        // 根据通道类型调用对应的静态编码方法
        // -----------------------------------------------------------------
        desc = encode_descriptor(tlp, channel);

        // -----------------------------------------------------------------
        // 步骤 6：组装 AXIS beats（调用 straddle 引擎）
        // 将 descriptor + payload 打包为 beat 序列
        // -----------------------------------------------------------------
        straddle_eng.pack_single_tlp(desc, tlp.payload, channel, beats, keeps, lasts);

        // -----------------------------------------------------------------
        // 步骤 7-8：编码 tuser 并创建 axis_transfer 发送
        // -----------------------------------------------------------------
        target_sqr = get_target_sequencer(channel);
        send_beats(tlp, channel, beats, keeps, lasts, target_sqr);

    endtask : encode_and_send

    //=========================================================================
    // encode_descriptor：根据通道类型编码描述符
    //=========================================================================
    protected function bit [127:0] encode_descriptor(
        pcie_tl_tlp      tlp,
        xilinx_channel_e channel
    );
        bit [127:0] desc;

        case (channel)
            XILINX_CH_RQ: begin
                // RQ 通道：编码请求描述符（128 位）
                desc = xilinx_desc_codec::encode_rq(tlp);
            end

            XILINX_CH_RC: begin
                // RC 通道：编码完成描述符（96 位，高 32 位补零）
                bit [95:0] desc96;
                desc96 = xilinx_desc_codec::encode_rc(tlp);
                desc = {32'h0, desc96};
            end

            XILINX_CH_CQ: begin
                // CQ 通道：编码请求描述符（128 位），需要额外 BAR 参数
                // 默认使用 BAR0，bar_aperture 和 target_func 为 0
                desc = xilinx_desc_codec::encode_cq(tlp, 3'h0, 6'h0, 8'h0);
            end

            XILINX_CH_CC: begin
                // CC 通道：编码完成描述符（96 位，高 32 位补零）
                bit [95:0] desc96;
                desc96 = xilinx_desc_codec::encode_cc(tlp);
                desc = {32'h0, desc96};
            end

            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("encode_descriptor: 未知通道 %s", channel.name()))
                desc = '0;
            end
        endcase

        return desc;
    endfunction : encode_descriptor

    //=========================================================================
    // get_target_sequencer：根据通道类型返回对应的 axis_sequencer
    //=========================================================================
    protected function axis_sequencer get_target_sequencer(xilinx_channel_e channel);
        case (channel)
            XILINX_CH_RQ: return rq_sqr;
            XILINX_CH_RC: return rc_sqr;
            XILINX_CH_CQ: return cq_sqr;
            XILINX_CH_CC: return cc_sqr;
            default: begin
                `uvm_fatal(get_type_name(),
                    $sformatf("get_target_sequencer: 未知通道 %s", channel.name()))
                return null;
            end
        endcase
    endfunction : get_target_sequencer

    //=========================================================================
    // send_beats：将 beat 序列转为 axis_transfer 并通过 sequencer 发送
    //=========================================================================
    protected task send_beats(
        pcie_tl_tlp         tlp,
        xilinx_channel_e    channel,
        ref bit [511:0]     beats[$],
        ref bit [15:0]      keeps[$],
        ref bit             lasts[$],
        axis_sequencer      sqr
    );
        int num_beats;
        num_beats = beats.size();

        for (int i = 0; i < num_beats; i++) begin
            axis_transfer xfer;
            bit [127:0]   tuser_val;

            // 创建 axis_transfer 序列项
            xfer = axis_transfer::type_id::create(
                $sformatf("xfer_%s_%0d", channel.name(), i));

            // -----------------------------------------------------------------
            // 步骤 7：编码 tuser（每个 beat 独立编码）
            // -----------------------------------------------------------------
            tuser_val = encode_tuser_for_beat(tlp, channel, beats[i], i, num_beats, lasts[i], keeps[i]);

            // 设置 axis_transfer 字段
            xfer.tdata = beats[i];

            // tkeep 扩展：straddle 引擎输出的是 per-DW（16 位），
            // axis_transfer 的 tkeep 是 per-byte（64 位）。
            // 每个 DW keep bit 展开为 4 个 byte keep bits。
            xfer.tkeep = expand_dw_keep_to_byte(keeps[i]);

            xfer.tlast = lasts[i];
            xfer.tuser = tuser_val;

            // 首 beat 插入 1 周期空闲，保证 tlast=1 后 tvalid 至少低 1 拍
            // 防止 axis_monitor 将前一 TLP 的 tlast 与后一 TLP 的首 beat 合并
            xfer.delay = (i == 0) ? 1 : 0;

            // -----------------------------------------------------------------
            // 步骤 8：通过 axis_sequencer 发送
            // 使用内部 one-shot sequence 将 xfer 发送到目标 sequencer
            // （uvm_driver 不能直接调用 start_item/finish_item）
            // -----------------------------------------------------------------
            begin
                axis_oneshot_seq oneshot;
                oneshot = axis_oneshot_seq::type_id::create(
                    $sformatf("oneshot_%s_%0d", channel.name(), i));
                oneshot.xfer = xfer;
                `uvm_info(get_type_name(),
                    $sformatf("DEBUG: oneshot.start on sqr=%s, beat[%0d]",
                        sqr.get_full_name(), i), UVM_LOW)
                oneshot.start(sqr);
                `uvm_info(get_type_name(),
                    $sformatf("DEBUG: oneshot done, beat[%0d]", i), UVM_LOW)
            end

            // Straddle 模式下输出 sop/eop 诊断信息
            if (straddle_eng.straddle_enable) begin
                `uvm_info(get_type_name(),
                    $sformatf("Straddle beat[%0d/%0d] 到 %s 通道, tlast=%0b, sop=%0b, eop=%0b, keep=0x%04h",
                        i, num_beats, channel.name(), lasts[i],
                        (i == 0), lasts[i], keeps[i]),
                    UVM_HIGH)
            end else begin
                `uvm_info(get_type_name(),
                    $sformatf("发送 beat[%0d/%0d] 到 %s 通道, tlast=%0b",
                        i, num_beats, channel.name(), lasts[i]),
                    UVM_FULL)
            end
        end
    endtask : send_beats

    //=========================================================================
    // expand_dw_keep_to_byte：将 per-DW tkeep 扩展为 per-byte tkeep
    // 每个 DW（32 位）对应 4 个字节，一个 DW keep bit 展开为 4 个 byte keep bits
    //=========================================================================
    protected function bit [63:0] expand_dw_keep_to_byte(bit [15:0] dw_keep);
        bit [63:0] byte_keep;
        byte_keep = '0;
        for (int dw = 0; dw < 16; dw++) begin
            if (dw_keep[dw]) begin
                // 每个有效 DW 对应 4 个连续字节使能位
                byte_keep[dw*4 +: 4] = 4'hF;
            end
        end
        return byte_keep;
    endfunction : expand_dw_keep_to_byte

    //=========================================================================
    // compress_byte_keep_to_dw：将 per-byte tkeep 压缩为 per-DW tkeep
    // 只要 4 个字节中有任一有效，该 DW 即标记为有效（静态方法，monitor 也可调用）
    //=========================================================================
    static function bit [15:0] compress_byte_keep_to_dw(bit [63:0] byte_keep);
        bit [15:0] dw_keep;
        dw_keep = '0;
        for (int dw = 0; dw < 16; dw++) begin
            if (byte_keep[dw*4 +: 4] != 4'h0) begin
                dw_keep[dw] = 1'b1;
            end
        end
        return dw_keep;
    endfunction : compress_byte_keep_to_dw

    //=========================================================================
    // encode_tuser_for_beat：为单个 beat 编码 tuser
    // 注意：axis_transfer.tuser 仅 128 位，此处截断高位
    //=========================================================================
    protected function bit [127:0] encode_tuser_for_beat(
        pcie_tl_tlp      tlp,
        xilinx_channel_e channel,
        bit [511:0]      tdata,
        int              beat_idx,
        int              num_beats,
        bit              is_last,
        bit [15:0]       dw_keep = 16'hFFFF
    );
        bit [127:0] tuser_truncated;

        case (channel)
            XILINX_CH_RQ: begin
                // RQ tuser 编码：first_be/last_be 从 TLP 提取
                bit [3:0] first_be, last_be;
                bit [1:0] tag_9_8;
                bit [284:0] tuser_full;

                // 从 TLP 提取字节使能（仅首 beat 携带）
                extract_be_from_tlp(tlp, first_be, last_be);
                tag_9_8 = tlp.tag[9:8];

                tuser_full = tuser_codec.encode_rq_tuser(
                    .first_be    (beat_idx == 0 ? first_be : 4'h0),
                    .last_be     (beat_idx == 0 ? last_be  : 4'h0),
                    .addr_offset (3'h0),
                    .discontinue (1'b0),
                    .tph_present (1'b0),
                    .tph_type    (2'h0),
                    .tph_st_tag  (8'h0),
                    .seq_num_0   (6'h0),
                    .seq_num_1   (6'h0),
                    .tag_9_8     (beat_idx == 0 ? tag_9_8 : 2'h0),
                    .tdata       (tdata)
                );
                tuser_truncated = tuser_full[127:0];
            end

            XILINX_CH_RC: begin
                // RC tuser 编码：byte_en 从 tkeep 派生，SOF/EOF 标记
                bit [63:0] byte_en;
                bit [320:0] tuser_full;
                int byte_lanes;

                byte_lanes = cfg.DATA_WIDTH / 8;
                // 所有字节默认有效（简化处理）
                byte_en = '0;
                for (int b = 0; b < byte_lanes; b++)
                    byte_en[b] = 1'b1;

                // straddle_enable=1 时计算正确的 eof_offset_0
                // eof_offset_0 指示 TLP 在最后一个 beat 中结束于哪个 DW
                begin
                    bit [2:0] eof_off;
                    eof_off = (is_last && straddle_eng.straddle_enable) ?
                              straddle_eng.calc_eop_offset(dw_keep) : 3'h0;

                    tuser_full = tuser_codec.encode_rc_tuser(
                        .byte_en      (byte_en),
                        .is_sof_0     (beat_idx == 0),
                        .is_sof_1     (1'b0),
                        .is_eof_0     (is_last),
                        .eof_offset_0 (eof_off),
                        .is_eof_1     (1'b0),
                        .eof_offset_1 (3'h0),
                        .discontinue  (1'b0),
                        .tdata        (tdata)
                    );
                end
                tuser_truncated = tuser_full[127:0];
            end

            XILINX_CH_CQ: begin
                // CQ tuser 编码：first_be/last_be + byte_en + SOP/EOP
                bit [3:0] first_be, last_be;
                bit [63:0] byte_en;
                bit [1:0] tag_9_8;
                bit [374:0] tuser_full;
                int byte_lanes;

                extract_be_from_tlp(tlp, first_be, last_be);
                tag_9_8 = tlp.tag[9:8];

                byte_lanes = cfg.DATA_WIDTH / 8;
                byte_en = '0;
                for (int b = 0; b < byte_lanes; b++)
                    byte_en[b] = 1'b1;

                // straddle_enable=1 时计算正确的 eop_offset
                // eop_offset 指示 TLP 在最后一个 beat 中结束于哪个 DW
                begin
                    bit [2:0] eop_off;
                    eop_off = (is_last && straddle_eng.straddle_enable) ?
                              straddle_eng.calc_eop_offset(dw_keep) : 3'h0;

                    tuser_full = tuser_codec.encode_cq_tuser(
                        .first_be     (beat_idx == 0 ? first_be : 4'h0),
                        .last_be      (beat_idx == 0 ? last_be  : 4'h0),
                        .byte_en      (byte_en),
                        .sop          (beat_idx == 0),
                        .sop_1        (1'b0),
                        .discontinue  (1'b0),
                        .tph_present  (1'b0),
                        .tph_type     (2'h0),
                        .tph_st_tag   (8'h0),
                        .is_eop       (is_last),
                        .eop_offset   (eop_off),
                        .is_eop_1     (1'b0),
                        .eop_offset_1 (3'h0),
                        .tag_9_8      (beat_idx == 0 ? tag_9_8 : 2'h0),
                        .tdata        (tdata)
                    );
                end
                tuser_truncated = tuser_full[127:0];
            end

            XILINX_CH_CC: begin
                // CC tuser 编码：仅包含 discontinue 和 parity
                bit [160:0] tuser_full;

                tuser_full = tuser_codec.encode_cc_tuser(
                    .discontinue (1'b0),
                    .tdata       (tdata)
                );
                tuser_truncated = tuser_full[127:0];
            end

            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("encode_tuser_for_beat: 未知通道 %s", channel.name()))
                tuser_truncated = '0;
            end
        endcase

        return tuser_truncated;
    endfunction : encode_tuser_for_beat

    //=========================================================================
    // extract_be_from_tlp：从 TLP 对象中提取 first_be 和 last_be
    // 需要根据子类类型进行 $cast
    //=========================================================================
    protected function void extract_be_from_tlp(
        pcie_tl_tlp     tlp,
        output bit [3:0] first_be,
        output bit [3:0] last_be
    );
        pcie_tl_mem_tlp    mem_tlp;
        pcie_tl_io_tlp     io_tlp;

        // 默认值
        first_be = 4'hF;
        last_be  = 4'h0;

        if ($cast(mem_tlp, tlp)) begin
            // 内存请求 TLP：直接提取 first_be 和 last_be
            first_be = mem_tlp.first_be;
            last_be  = mem_tlp.last_be;
        end else if ($cast(io_tlp, tlp)) begin
            // IO 请求 TLP：仅有 first_be，last_be 固定为 0
            first_be = io_tlp.first_be;
            last_be  = 4'h0;
        end
        // 其他类型（Completion、Message 等）：使用默认值
    endfunction : extract_be_from_tlp

endclass : xilinx_pcie_driver

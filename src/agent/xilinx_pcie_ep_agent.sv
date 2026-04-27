//=============================================================================
// Xilinx PCIe TL-Layer BFM - EP Agent（Endpoint 特化）
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 功能：继承 xilinx_pcie_base_agent，添加 EP 特有功能：
//   1. 自动回复模式：订阅 monitor 的 tlp_rx_ap，自动处理 MRd/MWr/IO/Cfg 请求
//   2. 内存模型：稀疏关联数组模拟 EP 本地内存
//   3. DMA 发起：通过 sequencer 主动发送 MRd/MWr TLP
//   4. Completion 生成：根据请求自动构建 CplD/Cpl 响应
//=============================================================================

// 内部辅助 sequence：用于在 TLP sequencer 上发送单个 pcie_tl_tlp
// agent 不能直接调用 sequencer.wait_for_grant()/send_request()，
// 必须通过 sequence 的 start_item/finish_item 协议发送
class tlp_oneshot_seq extends uvm_sequence #(pcie_tl_tlp);

    `uvm_object_utils(tlp_oneshot_seq)

    // 待发送的 TLP 事务
    pcie_tl_tlp tlp_item;

    function new(string name = "tlp_oneshot_seq");
        super.new(name);
    endfunction : new

    virtual task body();
        // 通过 sequence 的 start_item/finish_item 将 TLP 发送到 sequencer
        start_item(tlp_item);
        finish_item(tlp_item);
    endtask : body

endclass : tlp_oneshot_seq

class xilinx_pcie_ep_agent extends xilinx_pcie_base_agent;

    `uvm_component_utils(xilinx_pcie_ep_agent)

    //=========================================================================
    // EP 特有成员
    //=========================================================================

    // 稀疏内存模型：地址 -> 字节数据
    bit [7:0]                       mem_space[bit [63:0]];

    // EP 自身的 completer_id（Bus/Dev/Func），由上层配置
    bit [15:0]                      completer_id = 16'h0100;

    // Completion 发送队列（function 上下文中排入，run_phase 后台任务发送）
    pcie_tl_cpl_tlp                 cpl_send_queue[$];

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    //=========================================================================
    // run_phase：若启用自动响应，fork 后台 completion 发送任务
    //=========================================================================
    virtual task run_phase(uvm_phase phase);
        if (is_active == UVM_ACTIVE && cfg.ep_auto_response) begin
            fork
                process_cpl_send_queue();
            join_none
        end
    endtask : run_phase

    //=========================================================================
    // handle_rx_tlp：处理接收到的 TLP（由上层连接 monitor.tlp_rx_ap 后回调）
    // 仅当 cfg.ep_auto_response == 1 时启用自动响应
    //=========================================================================
    function void handle_rx_tlp(pcie_tl_tlp tlp);
        if (!cfg.ep_auto_response) return;

        case (tlp.kind)
            // -----------------------------------------------------------------
            // MWr：内存写请求 -> 写入 mem_space，无回复
            // -----------------------------------------------------------------
            TLP_MEM_WR: begin
                pcie_tl_mem_tlp mem_tlp;
                if ($cast(mem_tlp, tlp)) begin
                    mem_write(mem_tlp.addr, mem_tlp.payload,
                              mem_tlp.first_be, mem_tlp.last_be);
                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 MWr: addr=0x%016h, len=%0d bytes",
                            mem_tlp.addr, mem_tlp.payload.size()),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // MRd：内存读请求 -> 从 mem_space 读取，生成 CplD
            // -----------------------------------------------------------------
            TLP_MEM_RD, TLP_MEM_RD_LK: begin
                pcie_tl_mem_tlp mem_tlp;
                if ($cast(mem_tlp, tlp)) begin
                    bit [7:0] data[];
                    int byte_count;
                    pcie_tl_cpl_tlp cpl;

                    // 计算读取字节数：length 字段以 DW 为单位，0 表示 1024 DW
                    byte_count = (tlp.length == 0) ? 4096 : tlp.length * 4;
                    mem_read(mem_tlp.addr, byte_count, data);

                    // 生成 CplD 响应
                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 MRd: addr=0x%016h, len=%0d bytes -> CplD",
                            mem_tlp.addr, byte_count),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // IORd：IO 读请求 -> 从 mem_space 读取，生成 CplD（单 DW）
            // -----------------------------------------------------------------
            TLP_IO_RD: begin
                pcie_tl_io_tlp io_tlp;
                if ($cast(io_tlp, tlp)) begin
                    bit [7:0] data[];
                    pcie_tl_cpl_tlp cpl;

                    mem_read({32'h0, io_tlp.addr}, 4, data);
                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 IORd: addr=0x%08h -> CplD",
                            io_tlp.addr),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // IOWr：IO 写请求 -> 写入 mem_space，生成 Cpl（无数据）
            // -----------------------------------------------------------------
            TLP_IO_WR: begin
                pcie_tl_io_tlp io_tlp;
                if ($cast(io_tlp, tlp)) begin
                    bit [7:0] empty_data[];
                    pcie_tl_cpl_tlp cpl;

                    mem_write({32'h0, io_tlp.addr}, io_tlp.payload,
                              io_tlp.first_be, 4'h0);

                    // IO 写回 Cpl（无数据）
                    empty_data = new[0];
                    cpl = generate_completion(tlp, empty_data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 IOWr: addr=0x%08h -> Cpl",
                            io_tlp.addr),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // CfgRd：配置读请求 -> 读 cfg_space_manager，生成 CplD
            // -----------------------------------------------------------------
            TLP_CFG_RD0, TLP_CFG_RD1: begin
                pcie_tl_cfg_tlp cfg_tlp;
                if ($cast(cfg_tlp, tlp)) begin
                    bit [31:0] cfg_data;
                    bit [7:0] data[];
                    pcie_tl_cpl_tlp cpl;

                    // 从配置空间读取一个 DW
                    cfg_data = cfg_space.read({cfg_tlp.reg_num, 2'b00});

                    // 转为字节数组
                    data = new[4];
                    data[0] = cfg_data[7:0];
                    data[1] = cfg_data[15:8];
                    data[2] = cfg_data[23:16];
                    data[3] = cfg_data[31:24];

                    cpl = generate_completion(tlp, data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 CfgRd: reg=0x%03h -> CplD, data=0x%08h",
                            cfg_tlp.reg_num, cfg_data),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // CfgWr：配置写请求 -> 写 cfg_space_manager，生成 Cpl
            // -----------------------------------------------------------------
            TLP_CFG_WR0, TLP_CFG_WR1: begin
                pcie_tl_cfg_tlp cfg_tlp;
                if ($cast(cfg_tlp, tlp)) begin
                    bit [31:0] wr_data;
                    bit [7:0] empty_data[];
                    pcie_tl_cpl_tlp cpl;

                    // 从 payload 提取写入数据（最多 1 DW = 4 bytes）
                    wr_data = 32'h0;
                    if (tlp.payload.size() >= 1) wr_data[7:0]   = tlp.payload[0];
                    if (tlp.payload.size() >= 2) wr_data[15:8]  = tlp.payload[1];
                    if (tlp.payload.size() >= 3) wr_data[23:16] = tlp.payload[2];
                    if (tlp.payload.size() >= 4) wr_data[31:24] = tlp.payload[3];

                    // 写入配置空间
                    cfg_space.write({cfg_tlp.reg_num, 2'b00}, wr_data, cfg_tlp.first_be);

                    // Cfg 写回 Cpl（无数据）
                    empty_data = new[0];
                    cpl = generate_completion(tlp, empty_data, CPL_STATUS_SC);
                    send_completion(cpl);

                    `uvm_info(get_type_name(),
                        $sformatf("自动处理 CfgWr: reg=0x%03h, data=0x%08h -> Cpl",
                            cfg_tlp.reg_num, wr_data),
                        UVM_HIGH)
                end
            end

            // -----------------------------------------------------------------
            // Completion 类型：EP 收到的 completion 不需要自动回复
            // -----------------------------------------------------------------
            TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
                // 不做处理，由上层序列或 scoreboard 消费
            end

            default: begin
                `uvm_info(get_type_name(),
                    $sformatf("自动响应：忽略未处理的 TLP 类型 %s",
                        tlp.kind.name()),
                    UVM_HIGH)
            end
        endcase
    endfunction : handle_rx_tlp

    //=========================================================================
    // mem_write：写入稀疏内存模型
    // 根据 first_be 和 last_be 控制有效字节
    //=========================================================================
    function void mem_write(
        bit [63:0]  addr,
        bit [7:0]   data[],
        bit [3:0]   first_be,
        bit [3:0]   last_be
    );
        int data_idx;
        int total_dw;

        if (data.size() == 0) return;

        data_idx = 0;
        total_dw = (data.size() + 3) / 4;

        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be;

            // 确定当前 DW 的字节使能
            if (dw == 0)
                be = first_be;
            else if (dw == total_dw - 1 && total_dw > 1)
                be = last_be;
            else
                be = 4'hF;

            // 按字节使能写入内存
            for (int b = 0; b < 4; b++) begin
                if (data_idx < data.size()) begin
                    if (be[b]) begin
                        mem_space[addr + data_idx] = data[data_idx];
                    end
                    data_idx++;
                end
            end
        end
    endfunction : mem_write

    //=========================================================================
    // mem_read：从稀疏内存模型读取
    // 返回指定长度的字节数组，未初始化地址返回 0
    //=========================================================================
    function void mem_read(
        bit [63:0]  addr,
        int         length,
        output bit [7:0] data[]
    );
        data = new[length];
        for (int i = 0; i < length; i++) begin
            if (mem_space.exists(addr + i))
                data[i] = mem_space[addr + i];
            else
                data[i] = 8'h00;
        end
    endfunction : mem_read

    //=========================================================================
    // generate_completion：根据请求生成 Completion TLP
    // 填充 completer_id、requester_id、tag、lower_addr、byte_count 等
    //=========================================================================
    function pcie_tl_cpl_tlp generate_completion(
        pcie_tl_tlp     req,
        bit [7:0]       data[],
        cpl_status_e    status
    );
        pcie_tl_cpl_tlp cpl;
        cpl = pcie_tl_cpl_tlp::type_id::create("cpl");

        // 设置 Completion 类型：有数据为 CplD，无数据为 Cpl
        if (data.size() > 0) begin
            cpl.kind   = TLP_CPLD;
            cpl.fmt    = FMT_3DW_WITH_DATA;
            cpl.type_f = TLP_TYPE_CPL;
        end else begin
            cpl.kind   = TLP_CPL;
            cpl.fmt    = FMT_3DW_NO_DATA;
            cpl.type_f = TLP_TYPE_CPL;
        end

        // 填充 ID 字段
        cpl.completer_id = this.completer_id;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;

        // 填充 Completion 状态
        cpl.cpl_status = status;
        cpl.bcm        = 1'b0;

        // 计算 byte_count（响应数据总字节数）
        cpl.byte_count = data.size();

        // 计算 lower_addr（基于请求地址低 7 位）
        begin
            pcie_tl_mem_tlp mem_req;
            pcie_tl_io_tlp  io_req;
            pcie_tl_cfg_tlp cfg_req;

            if ($cast(mem_req, req))
                cpl.lower_addr = mem_req.addr[6:0];
            else if ($cast(io_req, req))
                cpl.lower_addr = io_req.addr[6:0];
            else if ($cast(cfg_req, req))
                cpl.lower_addr = {cfg_req.reg_num[4:0], 2'b00};
            else
                cpl.lower_addr = 7'h0;
        end

        // 填充 TLP 通用字段
        cpl.tc        = req.tc;
        cpl.attr      = req.attr;
        cpl.td        = 1'b0;
        cpl.ep_bit    = 1'b0;
        cpl.th        = 1'b0;

        // 计算 length（以 DW 为单位）
        if (data.size() > 0)
            cpl.length = (data.size() + 3) / 4;
        else
            cpl.length = 10'h0;

        // 复制 payload
        cpl.payload = data;

        return cpl;
    endfunction : generate_completion

    //=========================================================================
    // send_completion：将 Completion 排入发送队列
    // 由于 function 上下文中无法调用 task（sequencer 交互），
    // 实际发送由 run_phase 中的 process_cpl_send_queue 后台任务处理
    //=========================================================================
    function void send_completion(pcie_tl_cpl_tlp cpl);
        if (is_active == UVM_ACTIVE) begin
            cpl_send_queue.push_back(cpl);
        end else begin
            `uvm_warning(get_type_name(),
                "EP agent 处于 PASSIVE 模式，无法发送 Completion")
        end
    endfunction : send_completion

    //=========================================================================
    // process_cpl_send_queue：后台任务，从队列中取出 Completion 并发送
    //=========================================================================
    protected task process_cpl_send_queue();
        forever begin
            pcie_tl_cpl_tlp cpl;

            // 等待队列非空
            wait (cpl_send_queue.size() > 0);

            cpl = cpl_send_queue.pop_front();

            // 可选延迟（模拟 EP 处理时间）
            if (cfg.response_delay_max > 0) begin
                int delay;
                delay = $urandom_range(cfg.response_delay_min, cfg.response_delay_max);
                if (delay > 0) begin
                    // 使用 #delay 简化，避免依赖 tb_top 时钟
                    #(delay * 1ns);
                end
            end

            // 通过 one-shot sequence 在 sequencer 上发送 Completion
            // （不能直接调用 sequencer 的低级 API）
            begin
                pcie_tl_cpl_tlp cpl_clone;
                tlp_oneshot_seq oneshot;
                $cast(cpl_clone, cpl.clone());
                oneshot = tlp_oneshot_seq::type_id::create("cpl_oneshot");
                oneshot.tlp_item = cpl_clone;
                oneshot.start(sequencer);
            end

            `uvm_info(get_type_name(),
                $sformatf("已发送 Completion: tag=0x%03h, kind=%s, payload=%0d bytes",
                    cpl.tag, cpl.kind.name(), cpl.payload.size()),
                UVM_MEDIUM)
        end
    endtask : process_cpl_send_queue

    //=========================================================================
    // initiate_dma：发起 DMA 请求（通过 sequencer 发送 MRd/MWr TLP）
    //=========================================================================
    task initiate_dma(bit [63:0] addr, int size, bit is_read);
        pcie_tl_mem_tlp dma_tlp;

        if (is_active != UVM_ACTIVE) begin
            `uvm_error(get_type_name(),
                "initiate_dma: EP agent 处于 PASSIVE 模式，无法发起 DMA")
            return;
        end

        dma_tlp = pcie_tl_mem_tlp::type_id::create("dma_tlp");

        // 设置 TLP 基本字段
        if (is_read) begin
            dma_tlp.kind     = TLP_MEM_RD;
            dma_tlp.fmt      = (addr > 64'hFFFF_FFFF) ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
            dma_tlp.payload  = new[0];
        end else begin
            dma_tlp.kind     = TLP_MEM_WR;
            dma_tlp.fmt      = (addr > 64'hFFFF_FFFF) ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
            // 填充 payload（用递增模式）
            dma_tlp.payload = new[size];
            for (int i = 0; i < size; i++)
                dma_tlp.payload[i] = i[7:0];
        end

        dma_tlp.type_f       = TLP_TYPE_MEM_RD;
        dma_tlp.addr         = addr;
        dma_tlp.is_64bit     = (addr > 64'hFFFF_FFFF);
        dma_tlp.requester_id = this.completer_id;
        dma_tlp.length       = (size + 3) / 4;  // DW 为单位
        dma_tlp.first_be     = 4'hF;
        dma_tlp.last_be      = (dma_tlp.length > 1) ? 4'hF : 4'h0;
        dma_tlp.tc           = 3'h0;
        dma_tlp.attr         = 3'h0;
        dma_tlp.td           = 1'b0;
        dma_tlp.ep_bit       = 1'b0;
        dma_tlp.tag          = 10'h0;  // 由 driver 的 tag_mgr 自动分配

        // 通过 one-shot sequence 在 sequencer 上发送 DMA TLP
        // （不能直接调用 sequencer 的低级 API）
        begin
            tlp_oneshot_seq oneshot;
            oneshot = tlp_oneshot_seq::type_id::create("dma_oneshot");
            oneshot.tlp_item = dma_tlp;
            oneshot.start(sequencer);
        end

        `uvm_info(get_type_name(),
            $sformatf("DMA %s 已发起: addr=0x%016h, size=%0d bytes",
                is_read ? "读" : "写", addr, size),
            UVM_MEDIUM)
    endtask : initiate_dma

endclass : xilinx_pcie_ep_agent

//=============================================================================
// Xilinx PCIe TL-Layer BFM - Atomic Operation 序列
// 单次 AtomicOp 请求（FetchAdd / Swap / CAS）
//
// 使用方式：
//   创建实例，设置 addr / atomic_kind / is_64bit / operand / compare / swap_val，
//   然后 start(sqr)。body() 构造 pcie_tl_atomic_tlp 并发送。
//
// 注意：
//   - fmt 根据 is_64bit 自动选为 FMT_4DW_WITH_DATA 或 FMT_3DW_WITH_DATA
//   - payload 按小端序填充操作数（FetchAdd/Swap：operand；CAS：compare||swap_val）
//   - length（DW）由 is_64bit 和 atomic_kind 自动计算
//=============================================================================

class xilinx_pcie_atomic_seq extends xilinx_pcie_base_seq;

    `uvm_object_utils(xilinx_pcie_atomic_seq)

    //=========================================================================
    // 公开字段
    //=========================================================================

    // 目标地址（64 位）
    bit [63:0]       addr;

    // 操作数（FetchAdd/Swap 的操作值；CAS 的比较值）
    rand bit [63:0]  operand;

    // CAS 专用：比较值（compare operand）
    rand bit [63:0]  compare;

    // CAS 专用：交换值（swap operand）
    rand bit [63:0]  swap_val;

    // 0=32 位操作（4 字节），1=64 位操作（8 字节）
    bit              is_64bit;

    // 原子操作类型
    tlp_kind_e       atomic_kind = TLP_ATOMIC_FETCHADD;

    //=========================================================================
    // 构造函数
    //=========================================================================
    function new(string name = "xilinx_pcie_atomic_seq");
        super.new(name);
    endfunction : new

    //=========================================================================
    // body：构造并发送单个 Atomic TLP
    //=========================================================================
    virtual task body();
        pcie_tl_atomic_tlp tlp;
        int unsigned       sz;       // 操作大小（字节）
        int unsigned       dw_len;   // DW count（length 字段）
        tlp_fmt_e          fmt_val;
        atomic_op_size_e   op_sz;

        // 确定操作大小
        sz     = is_64bit ? 32'd8 : 32'd4;
        op_sz  = is_64bit ? ATOMIC_SIZE_64 : ATOMIC_SIZE_32;

        // FetchAdd/Swap：payload = sz 字节 operand
        // CAS            ：payload = sz 字节 compare + sz 字节 swap_val
        if (atomic_kind == TLP_ATOMIC_CAS)
            dw_len = is_64bit ? 32'd4 : 32'd2;   // 2*sz / 4
        else
            dw_len = is_64bit ? 32'd2 : 32'd1;   // sz / 4

        // fmt：64 位地址 → 4DW，32 位地址 → 3DW；总是 WITH_DATA
        fmt_val = is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;

        // 创建 TLP 对象
        tlp = pcie_tl_atomic_tlp::type_id::create("atomic_tlp");
        tlp.kind     = atomic_kind;
        tlp.fmt      = fmt_val;
        tlp.addr     = addr;
        tlp.is_64bit = is_64bit;
        tlp.op_size  = op_sz;
        tlp.length   = dw_len[9:0];

        // type_f：由 kind 决定
        case (atomic_kind)
            TLP_ATOMIC_FETCHADD: tlp.type_f = TLP_TYPE_ATOMIC_FETCHADD;
            TLP_ATOMIC_SWAP:     tlp.type_f = TLP_TYPE_ATOMIC_SWAP;
            TLP_ATOMIC_CAS:      tlp.type_f = TLP_TYPE_ATOMIC_CAS;
            default:             tlp.type_f = TLP_TYPE_ATOMIC_FETCHADD;
        endcase

        // 构造 payload（小端序）
        if (atomic_kind == TLP_ATOMIC_CAS) begin
            // CAS：compare (sz bytes) 后接 swap_val (sz bytes)
            tlp.payload = new[2 * sz];
            for (int i = 0; i < int'(sz); i++) begin
                tlp.payload[i]      = byte'((compare  >> (8 * i)) & 64'hFF);
                tlp.payload[sz + i] = byte'((swap_val >> (8 * i)) & 64'hFF);
            end
        end else begin
            // FetchAdd / Swap：operand (sz bytes)
            tlp.payload = new[sz];
            for (int i = 0; i < int'(sz); i++)
                tlp.payload[i] = byte'((operand >> (8 * i)) & 64'hFF);
        end

        `uvm_info(get_type_name(),
            $sformatf("发送 %s: addr=0x%016h, is_64bit=%0b, length=%0d DW, payload=%0d bytes",
                atomic_kind.name(), addr, is_64bit, dw_len, tlp.payload.size()),
            UVM_MEDIUM)

        start_item(tlp);
        finish_item(tlp);

    endtask : body

endclass : xilinx_pcie_atomic_seq

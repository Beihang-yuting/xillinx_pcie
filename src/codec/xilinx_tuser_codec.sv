//=============================================================================
// Xilinx PCIe TL-Layer BFM - AXI-Stream tuser 编解码器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件提供四个通道的 tuser 字段编解码：
//   RQ (Requester Request)  : 62/62/137/285 位
//   RC (Requester Completion): 75/75/161/321 位
//   CQ (Completer Request)  : 88/88/183/375 位
//   CC (Completer Completion): 33/33/81/161 位
//
// 每个通道的 tuser 位宽随 DATA_WIDTH 变化（64/128/256/512 bit）。
// 本类通过构造函数接收 DATA_WIDTH，实例方法根据宽度自动选择正确布局。
//
// 注意：本类为普通 class，不继承 UVM 基类，需要实例化后使用。
//=============================================================================

class xilinx_tuser_codec;

    //=========================================================================
    // 成员变量
    //=========================================================================

    // AXI-Stream 数据总线宽度（bits），支持 64/128/256/512
    int DATA_WIDTH;

    //=========================================================================
    // 构造函数
    //=========================================================================

    // new: 创建编解码器实例，绑定数据总线宽度
    // 参数 data_width 必须为 64/128/256/512 之一，否则运行时报错
    function new(int data_width = 256);
        if (data_width != 64 && data_width != 128 &&
            data_width != 256 && data_width != 512) begin
            $fatal(1, "[xilinx_tuser_codec] new: 不支持的数据宽度 %0d，必须为 64/128/256/512",
                data_width);
        end
        this.DATA_WIDTH = data_width;
    endfunction : new

    //=========================================================================
    // Parity 计算辅助函数
    //=========================================================================

    // calc_byte_parity: 计算单字节的奇偶校验位
    // 对字节内所有位执行 XOR，结果为 1 表示奇数个 1（奇校验）
    static function bit calc_byte_parity(bit [7:0] b);
        // 将 8 位全部 XOR 折叠，得到单 bit 校验值
        return ^b;
    endfunction : calc_byte_parity

    // calc_parity: 计算 tdata 中有效字节的逐字节奇偶校验
    // 根据 DATA_WIDTH 决定需要计算的字节数（DATA_WIDTH/8）
    // 返回 64 位向量，每 bit 对应一个字节的校验结果
    // 超出有效范围的高位补零
    function bit [63:0] calc_parity(bit [511:0] tdata);
        int num_bytes;            // 有效字节数 = DATA_WIDTH / 8
        bit [63:0] parity_result; // 校验结果向量

        num_bytes     = DATA_WIDTH / 8;   // 例如 256-bit -> 32 字节
        parity_result = '0;

        // 对每个有效字节独立计算 parity
        for (int i = 0; i < num_bytes; i++) begin
            // 从 tdata 中提取第 i 个字节（小端，字节 0 在低位）
            parity_result[i] = calc_byte_parity(tdata[i*8 +: 8]);
        end

        return parity_result;
    endfunction : calc_parity

    //=========================================================================
    // -------------------------------------------------------------------------
    // RQ 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-8）：
    //   DATA_WIDTH=64/128  -> 62-bit tuser（无 seq_num 高位、无 tag_9_8）
    //   DATA_WIDTH=256     -> 137-bit tuser
    //   DATA_WIDTH=512     -> 285-bit tuser
    // -------------------------------------------------------------------------

    // encode_rq_tuser: 将各字段打包成 RQ tuser 向量
    // 返回类型为最大宽度 bit[284:0]，调用方根据实际宽度截取低位
    //
    // 参数说明：
    //   first_be    [3:0]   首 DW 字节使能
    //   last_be     [3:0]   末 DW 字节使能
    //   addr_offset [2:0]   地址偏移（用于非 DW 对齐传输）
    //   discontinue         不连续位（强制 flush 当前传输）
    //   tph_present         TPH（TLP Processing Hints）存在标志
    //   tph_type    [1:0]   TPH 类型
    //   tph_st_tag  [7:0]   TPH Steering Tag
    //   seq_num_0   [5:0]   序列号 0（256/512-bit 模式有效）
    //   seq_num_1   [5:0]   序列号 1（512-bit 模式有效）
    //   tag_9_8     [1:0]   Tag 高 2 位（10-bit Tag 扩展，256/512-bit 有效）
    //   tdata       [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [284:0] encode_rq_tuser(
        bit [3:0]   first_be,
        bit [3:0]   last_be,
        bit [2:0]   addr_offset,
        bit         discontinue,
        bit         tph_present,
        bit [1:0]   tph_type,
        bit [7:0]   tph_st_tag,
        bit [5:0]   seq_num_0,
        bit [5:0]   seq_num_1,
        bit [1:0]   tag_9_8,
        bit [511:0] tdata
    );
        bit [284:0] tuser;           // 最大宽度返回值，未使用位填零
        int         parity_bits;     // 本实例需要的 parity 位数 = DATA_WIDTH/8
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser       = '0;
        parity_bits = DATA_WIDTH / 8;   // 256-bit -> 32，512-bit -> 64
        parity      = calc_parity(tdata);

        // ---------------------------------------------------------------
        // 共同字段：所有数据宽度均相同的基础字段
        // 参考 PG213 Table 2-8 (RQ tuser)
        // ---------------------------------------------------------------

        // [3:0]   first_be：首 DW 字节使能
        tuser[3:0]   = first_be;

        // [7:4]   last_be：末 DW 字节使能
        tuser[7:4]   = last_be;

        // [10:8]  addr_offset：地址字节偏移（仅低 3 位）
        tuser[10:8]  = addr_offset;

        // [11]    discontinue：传输不连续标志
        tuser[11]    = discontinue;

        // [12]    tph_present：TPH 存在标志
        tuser[12]    = tph_present;

        // [14:13] tph_type：TPH 类型
        tuser[14:13] = tph_type;

        // [22:15] tph_st_tag：TPH Steering Tag（8 位）
        tuser[22:15] = tph_st_tag;

        if (DATA_WIDTH == 64 || DATA_WIDTH == 128) begin
            // ---------------------------------------------------------------
            // 64/128-bit 模式：62-bit tuser
            // 无 seq_num 高位扩展和 tag_9_8
            // ---------------------------------------------------------------
            // [26:23] seq_num_0[3:0]：序列号 0 低 4 位
            tuser[26:23] = seq_num_0[3:0];

            // [30:27] seq_num_1[3:0]：序列号 1 低 4 位
            tuser[30:27] = seq_num_1[3:0];

            // [62:31] parity：DATA_WIDTH/8 个字节校验位（填入低位，高位补零）
            tuser[62:31] = parity[parity_bits-1:0];

        end else if (DATA_WIDTH == 256) begin
            // ---------------------------------------------------------------
            // 256-bit 模式：137-bit tuser
            // parity 字段为 32 bits（256/8=32 字节）
            // 参考 PG213 Table 2-8（256-bit variant）
            // ---------------------------------------------------------------
            // [26:23] seq_num_0[3:0]：序列号 0 低 4 位
            tuser[26:23] = seq_num_0[3:0];

            // [30:27] seq_num_1[3:0]：序列号 1 低 4 位
            tuser[30:27] = seq_num_1[3:0];

            // [62:31] parity[31:0]：32 字节奇偶校验（共 32 bits）
            tuser[62:31] = parity[31:0];

            // [68:63] seq_num_0[5:0]：序列号 0 全 6 位（高位扩展段）
            // 注意：PG213 在 256-bit 模式下将 seq_num_0 完整 6 位置于此段
            tuser[68:63] = seq_num_0[5:0];

            // [74:69] seq_num_1[5:0]：序列号 1 全 6 位
            tuser[74:69] = seq_num_1[5:0];

            // [76:75] tag_9_8：Tag 高 2 位（10-bit Tag 扩展）
            tuser[76:75] = tag_9_8;

            // [136:77] 保留（Reserved），保持 0（共 60 位）

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：285-bit tuser
            // parity 字段扩展为 64 bits（512/8=64 字节）
            // 参考 PG213 Table 2-8（512-bit variant）
            // ---------------------------------------------------------------
            // [26:23] seq_num_0[3:0]：序列号 0 低 4 位
            tuser[26:23] = seq_num_0[3:0];

            // [30:27] seq_num_1[3:0]：序列号 1 低 4 位
            tuser[30:27] = seq_num_1[3:0];

            // [94:31] parity[63:0]：64 字节奇偶校验（共 64 bits）
            tuser[94:31] = parity[63:0];

            // [100:95] seq_num_0[5:0]：序列号 0 全 6 位（高位扩展段）
            tuser[100:95] = seq_num_0[5:0];

            // [106:101] seq_num_1[5:0]：序列号 1 全 6 位
            tuser[106:101] = seq_num_1[5:0];

            // [108:107] tag_9_8：Tag 高 2 位
            tuser[108:107] = tag_9_8;

            // [284:109] 保留（Reserved），保持 0

        end

        return tuser;
    endfunction : encode_rq_tuser

    // decode_rq_tuser: 从 RQ tuser 向量中提取各字段
    // 输入为最大宽度向量，根据 DATA_WIDTH 选择正确的字段位置
    //
    // 输出参数均为 output，通过引用返回各字段值
    function void decode_rq_tuser(
        input  bit [284:0] tuser,
        output bit [3:0]   first_be,
        output bit [3:0]   last_be,
        output bit [2:0]   addr_offset,
        output bit         discontinue,
        output bit         tph_present,
        output bit [1:0]   tph_type,
        output bit [7:0]   tph_st_tag,
        output bit [5:0]   seq_num_0,
        output bit [5:0]   seq_num_1,
        output bit [1:0]   tag_9_8
    );
        // ---------------------------------------------------------------
        // 共同字段提取（所有数据宽度均使用相同位置）
        // ---------------------------------------------------------------

        // [3:0]   first_be：首 DW 字节使能
        first_be    = tuser[3:0];

        // [7:4]   last_be：末 DW 字节使能
        last_be     = tuser[7:4];

        // [10:8]  addr_offset：地址字节偏移
        addr_offset = tuser[10:8];

        // [11]    discontinue：传输不连续标志
        discontinue = tuser[11];

        // [12]    tph_present：TPH 存在标志
        tph_present = tuser[12];

        // [14:13] tph_type：TPH 类型
        tph_type    = tuser[14:13];

        // [22:15] tph_st_tag：TPH Steering Tag
        tph_st_tag  = tuser[22:15];

        // 初始化扩展字段为默认值（64/128-bit 模式无这些字段）
        seq_num_0 = '0;
        seq_num_1 = '0;
        tag_9_8   = '0;

        if (DATA_WIDTH == 64 || DATA_WIDTH == 128) begin
            // ---------------------------------------------------------------
            // 64/128-bit 模式：seq_num 仅有低 4 位，无高位扩展
            // ---------------------------------------------------------------
            // [26:23] seq_num_0[3:0]：序列号 0 低 4 位，高位补零
            seq_num_0 = {2'b00, tuser[26:23]};

            // [30:27] seq_num_1[3:0]：序列号 1 低 4 位，高位补零
            seq_num_1 = {2'b00, tuser[30:27]};

            // tag_9_8：62-bit tuser 不携带，保持 0

        end else if (DATA_WIDTH == 256) begin
            // ---------------------------------------------------------------
            // 256-bit 模式：提取完整 seq_num 和 tag_9_8
            // ---------------------------------------------------------------
            // [68:63] seq_num_0[5:0]：高位扩展段存放完整 6 位序列号
            seq_num_0 = tuser[68:63];

            // [74:69] seq_num_1[5:0]：序列号 1 完整 6 位
            seq_num_1 = tuser[74:69];

            // [76:75] tag_9_8：Tag 高 2 位
            tag_9_8   = tuser[76:75];

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：提取扩展字段
            // ---------------------------------------------------------------
            // [100:95] seq_num_0[5:0]：序列号 0 完整 6 位
            seq_num_0 = tuser[100:95];

            // [106:101] seq_num_1[5:0]：序列号 1 完整 6 位
            seq_num_1 = tuser[106:101];

            // [108:107] tag_9_8：Tag 高 2 位
            tag_9_8   = tuser[108:107];

        end
    endfunction : decode_rq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // RC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-10）：
    //   DATA_WIDTH=64/128  -> 75-bit tuser（byte_en 宽度为 DATA_WIDTH/8）
    //   DATA_WIDTH=256     -> 161-bit tuser（byte_en 32 bits，parity 32 bits）
    //   DATA_WIDTH=512     -> 321-bit tuser（byte_en 64 bits，parity 64 bits）
    //
    // 256-bit 布局（参考值）：
    //   [31:0]    byte_en（32 bits）
    //   [32]      is_sof_0
    //   [33]      is_sof_1
    //   [34]      is_eof_0
    //   [37:35]   eof_offset_0
    //   [38]      is_eof_1
    //   [41:39]   eof_offset_1
    //   [42]      discontinue
    //   [74:43]   parity（32 bits）
    // -------------------------------------------------------------------------

    // encode_rc_tuser: 将各字段打包成 RC tuser 向量
    // 返回类型为最大宽度 bit[320:0]
    //
    // 参数说明：
    //   byte_en       [63:0]  字节使能向量（有效位宽 = DATA_WIDTH/8，高位补零）
    //   is_sof_0              Start-of-Frame 0 标志
    //   is_sof_1              Start-of-Frame 1 标志（512-bit 模式）
    //   is_eof_0              End-of-Frame 0 标志
    //   eof_offset_0  [2:0]   EOF 0 字节偏移
    //   is_eof_1              End-of-Frame 1 标志（512-bit 模式）
    //   eof_offset_1  [2:0]   EOF 1 字节偏移（512-bit 模式）
    //   discontinue           不连续位
    //   tdata         [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [320:0] encode_rc_tuser(
        bit [63:0]  byte_en,
        bit         is_sof_0,
        bit         is_sof_1,
        bit         is_eof_0,
        bit [2:0]   eof_offset_0,
        bit         is_eof_1,
        bit [2:0]   eof_offset_1,
        bit         discontinue,
        bit [511:0] tdata
    );
        bit [320:0] tuser;           // 最大宽度返回值
        int         be_bits;         // byte_en 有效位数 = DATA_WIDTH/8
        int         parity_bits;     // parity 位数 = DATA_WIDTH/8
        int         be_top;          // byte_en 字段最高位位置（包含）
        int         ctrl_base;       // 控制字段（sof/eof 等）起始位置
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser       = '0;
        be_bits     = DATA_WIDTH / 8;   // 64->8, 128->16, 256->32, 512->64
        parity_bits = DATA_WIDTH / 8;
        parity      = calc_parity(tdata);

        // ---------------------------------------------------------------
        // byte_en 字段：从 bit 0 开始，宽度为 be_bits
        // 256-bit 模式: [31:0]，512-bit 模式: [63:0]
        // ---------------------------------------------------------------
        be_top = be_bits - 1;   // byte_en 最高有效位索引

        // 写入 byte_en（有效位宽取决于 DATA_WIDTH）
        tuser[be_top:0] = byte_en[be_bits-1:0];

        // ---------------------------------------------------------------
        // 控制字段：紧接 byte_en 之后，偏移量由 be_bits 决定
        // ctrl_base = be_bits（即 byte_en 占用的 bit 数）
        // ---------------------------------------------------------------
        ctrl_base = be_bits;

        // [ctrl_base+0]         is_sof_0：SOF 0 标志
        tuser[ctrl_base]     = is_sof_0;

        // [ctrl_base+1]         is_sof_1：SOF 1 标志
        tuser[ctrl_base+1]   = is_sof_1;

        // [ctrl_base+2]         is_eof_0：EOF 0 标志
        tuser[ctrl_base+2]   = is_eof_0;

        // [ctrl_base+5:ctrl_base+3] eof_offset_0[2:0]：EOF 0 偏移
        tuser[ctrl_base+5:ctrl_base+3] = eof_offset_0;

        // [ctrl_base+6]         is_eof_1：EOF 1 标志
        tuser[ctrl_base+6]   = is_eof_1;

        // [ctrl_base+9:ctrl_base+7] eof_offset_1[2:0]：EOF 1 偏移
        tuser[ctrl_base+9:ctrl_base+7] = eof_offset_1;

        // [ctrl_base+10]        discontinue：不连续标志
        tuser[ctrl_base+10]  = discontinue;

        // parity 字段紧接 discontinue 之后
        // 起始位 ctrl_base+11，宽度为 parity_bits
        tuser[ctrl_base+10+parity_bits : ctrl_base+11] = parity[parity_bits-1:0];

        return tuser;
    endfunction : encode_rc_tuser

    // decode_rc_tuser: 从 RC tuser 向量中提取各字段
    function void decode_rc_tuser(
        input  bit [320:0] tuser,
        output bit [63:0]  byte_en,
        output bit         is_sof_0,
        output bit         is_sof_1,
        output bit         is_eof_0,
        output bit [2:0]   eof_offset_0,
        output bit         is_eof_1,
        output bit [2:0]   eof_offset_1,
        output bit         discontinue
    );
        int be_bits;      // byte_en 有效位数
        int be_top;       // byte_en 最高位
        int ctrl_base;    // 控制字段起始位

        be_bits   = DATA_WIDTH / 8;
        be_top    = be_bits - 1;
        ctrl_base = be_bits;

        // 初始化输出为全零
        byte_en      = '0;
        is_sof_0     = '0;
        is_sof_1     = '0;
        is_eof_0     = '0;
        eof_offset_0 = '0;
        is_eof_1     = '0;
        eof_offset_1 = '0;
        discontinue  = '0;

        // [be_top:0] byte_en：字节使能（低位）
        byte_en[be_bits-1:0] = tuser[be_top:0];

        // 控制字段提取（相对于 ctrl_base 的偏移与 encode 一致）

        // [ctrl_base+0]         is_sof_0
        is_sof_0     = tuser[ctrl_base];

        // [ctrl_base+1]         is_sof_1
        is_sof_1     = tuser[ctrl_base+1];

        // [ctrl_base+2]         is_eof_0
        is_eof_0     = tuser[ctrl_base+2];

        // [ctrl_base+5:ctrl_base+3] eof_offset_0
        eof_offset_0 = tuser[ctrl_base+5:ctrl_base+3];

        // [ctrl_base+6]         is_eof_1
        is_eof_1     = tuser[ctrl_base+6];

        // [ctrl_base+9:ctrl_base+7] eof_offset_1
        eof_offset_1 = tuser[ctrl_base+9:ctrl_base+7];

        // [ctrl_base+10]        discontinue
        discontinue  = tuser[ctrl_base+10];

    endfunction : decode_rc_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CQ 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-9）：
    //   DATA_WIDTH=64/128  -> 88-bit tuser
    //   DATA_WIDTH=256     -> 183-bit tuser（byte_en 32 bits，parity 32 bits）
    //   DATA_WIDTH=512     -> 375-bit tuser（byte_en 64 bits，parity 64 bits）
    //
    // 256-bit 布局（参考值）：
    //   [3:0]     first_be
    //   [7:4]     last_be
    //   [39:8]    byte_en（32 bits）
    //   [40]      sop
    //   [41]      sop_1
    //   [42]      discontinue
    //   [43]      tph_present
    //   [45:44]   tph_type
    //   [53:46]   tph_st_tag
    //   [54]      parity_en（置 1）
    //   [86:55]   parity（32 bits）
    //   [87]      is_eop
    //   [90:88]   eop_offset
    //   [91]      is_eop_1
    //   [94:92]   eop_offset_1
    //   [96:95]   tag_9_8
    // -------------------------------------------------------------------------

    // encode_cq_tuser: 将各字段打包成 CQ tuser 向量
    // 返回类型为最大宽度 bit[374:0]
    //
    // 参数说明：
    //   first_be     [3:0]   首 DW 字节使能
    //   last_be      [3:0]   末 DW 字节使能
    //   byte_en      [63:0]  字节使能（有效宽度 = DATA_WIDTH/8）
    //   sop                  Start-of-Packet 标志
    //   sop_1                Start-of-Packet 1 标志（512-bit 模式）
    //   discontinue          不连续标志
    //   tph_present          TPH 存在标志
    //   tph_type     [1:0]   TPH 类型
    //   tph_st_tag   [7:0]   TPH Steering Tag
    //   is_eop               End-of-Packet 标志
    //   eop_offset   [2:0]   EOP 字节偏移
    //   is_eop_1             End-of-Packet 1 标志（512-bit 模式）
    //   eop_offset_1 [2:0]   EOP 1 字节偏移（512-bit 模式）
    //   tag_9_8      [1:0]   Tag 高 2 位（10-bit Tag 扩展）
    //   tdata        [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [374:0] encode_cq_tuser(
        bit [3:0]   first_be,
        bit [3:0]   last_be,
        bit [63:0]  byte_en,
        bit         sop,
        bit         sop_1,
        bit         discontinue,
        bit         tph_present,
        bit [1:0]   tph_type,
        bit [7:0]   tph_st_tag,
        bit         is_eop,
        bit [2:0]   eop_offset,
        bit         is_eop_1,
        bit [2:0]   eop_offset_1,
        bit [1:0]   tag_9_8,
        bit [511:0] tdata
    );
        bit [374:0] tuser;           // 最大宽度返回值
        int         be_bits;         // byte_en 有效位数 = DATA_WIDTH/8
        int         parity_bits;     // parity 位数 = DATA_WIDTH/8
        int         be_off;          // byte_en 字段在 tuser 中的起始偏移（固定为 8）
        int         be_top;          // byte_en 字段最高位（包含）
        int         ctrl_base;       // 控制字段（sop/discontinue 等）起始位
        int         parity_base;     // parity 字段起始位
        int         eop_base;        // EOP 字段起始位
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser       = '0;
        be_bits     = DATA_WIDTH / 8;
        parity_bits = DATA_WIDTH / 8;
        parity      = calc_parity(tdata);

        // ---------------------------------------------------------------
        // 固定头部字段（所有数据宽度位置不变）
        // 参考 PG213 Table 2-9 (CQ tuser)
        // ---------------------------------------------------------------

        // [3:0]   first_be：首 DW 字节使能
        tuser[3:0]   = first_be;

        // [7:4]   last_be：末 DW 字节使能
        tuser[7:4]   = last_be;

        // ---------------------------------------------------------------
        // byte_en 字段：从 bit 8 开始，宽度为 be_bits（DATA_WIDTH/8）
        // 256-bit: [39:8]（32 bits），512-bit: [71:8]（64 bits）
        // ---------------------------------------------------------------
        be_off = 8;                    // byte_en 固定从 bit 8 开始
        be_top = be_off + be_bits - 1; // byte_en 字段最高位

        tuser[be_top:be_off] = byte_en[be_bits-1:0];

        // ---------------------------------------------------------------
        // 控制字段：紧接 byte_en 之后（be_top+1 开始）
        // ---------------------------------------------------------------
        ctrl_base = be_top + 1;   // 控制字段起始位

        // [ctrl_base+0]            sop：Start-of-Packet 标志
        tuser[ctrl_base]     = sop;

        // [ctrl_base+1]            sop_1：SOP 1 标志
        tuser[ctrl_base+1]   = sop_1;

        // [ctrl_base+2]            discontinue：不连续标志
        tuser[ctrl_base+2]   = discontinue;

        // [ctrl_base+3]            tph_present：TPH 存在标志
        tuser[ctrl_base+3]   = tph_present;

        // [ctrl_base+5:ctrl_base+4] tph_type：TPH 类型（2 位）
        tuser[ctrl_base+5:ctrl_base+4] = tph_type;

        // [ctrl_base+13:ctrl_base+6] tph_st_tag：TPH Steering Tag（8 位）
        tuser[ctrl_base+13:ctrl_base+6] = tph_st_tag;

        // [ctrl_base+14]           parity_en：奇偶校验使能（固定置 1）
        tuser[ctrl_base+14]  = 1'b1;

        // parity 字段：从 ctrl_base+15 开始，宽度为 parity_bits
        // 256-bit: 32 bits at [ctrl_base+46:ctrl_base+15]
        // 512-bit: 64 bits at [ctrl_base+78:ctrl_base+15]
        parity_base = ctrl_base + 15;
        tuser[parity_base + parity_bits - 1 : parity_base] = parity[parity_bits-1:0];

        // ---------------------------------------------------------------
        // EOP 字段：紧接 parity 之后
        // ---------------------------------------------------------------
        eop_base = parity_base + parity_bits;   // EOP 字段起始位

        // [eop_base+0]            is_eop：EOP 标志
        tuser[eop_base]     = is_eop;

        // [eop_base+3:eop_base+1] eop_offset[2:0]：EOP 字节偏移
        tuser[eop_base+3:eop_base+1] = eop_offset;

        // [eop_base+4]            is_eop_1：EOP 1 标志
        tuser[eop_base+4]   = is_eop_1;

        // [eop_base+7:eop_base+5] eop_offset_1[2:0]：EOP 1 字节偏移
        tuser[eop_base+7:eop_base+5] = eop_offset_1;

        // [eop_base+9:eop_base+8] tag_9_8：Tag 高 2 位
        tuser[eop_base+9:eop_base+8] = tag_9_8;

        return tuser;
    endfunction : encode_cq_tuser

    // decode_cq_tuser: 从 CQ tuser 向量中提取各字段
    function void decode_cq_tuser(
        input  bit [374:0] tuser,
        output bit [3:0]   first_be,
        output bit [3:0]   last_be,
        output bit [63:0]  byte_en,
        output bit         sop,
        output bit         sop_1,
        output bit         discontinue,
        output bit         tph_present,
        output bit [1:0]   tph_type,
        output bit [7:0]   tph_st_tag,
        output bit         is_eop,
        output bit [2:0]   eop_offset,
        output bit         is_eop_1,
        output bit [2:0]   eop_offset_1,
        output bit [1:0]   tag_9_8
    );
        int be_bits;      // byte_en 有效位数
        int be_off;       // byte_en 字段起始位（固定为 8）
        int be_top;       // byte_en 字段最高位
        int parity_bits;  // parity 位数
        int ctrl_base;    // 控制字段起始位
        int parity_base;  // parity 字段起始位
        int eop_base;     // EOP 字段起始位

        be_bits     = DATA_WIDTH / 8;
        be_off      = 8;
        be_top      = be_off + be_bits - 1;
        parity_bits = DATA_WIDTH / 8;
        ctrl_base   = be_top + 1;
        parity_base = ctrl_base + 15;
        eop_base    = parity_base + parity_bits;

        // 初始化输出
        first_be     = '0;
        last_be      = '0;
        byte_en      = '0;
        sop          = '0;
        sop_1        = '0;
        discontinue  = '0;
        tph_present  = '0;
        tph_type     = '0;
        tph_st_tag   = '0;
        is_eop       = '0;
        eop_offset   = '0;
        is_eop_1     = '0;
        eop_offset_1 = '0;
        tag_9_8      = '0;

        // [3:0]   first_be
        first_be = tuser[3:0];

        // [7:4]   last_be
        last_be  = tuser[7:4];

        // byte_en：[be_top:be_off]
        byte_en[be_bits-1:0] = tuser[be_top:be_off];

        // 控制字段
        sop         = tuser[ctrl_base];
        sop_1       = tuser[ctrl_base+1];
        discontinue = tuser[ctrl_base+2];
        tph_present = tuser[ctrl_base+3];
        tph_type    = tuser[ctrl_base+5:ctrl_base+4];
        tph_st_tag  = tuser[ctrl_base+13:ctrl_base+6];
        // [ctrl_base+14] parity_en（只读/忽略）

        // EOP 字段
        is_eop       = tuser[eop_base];
        eop_offset   = tuser[eop_base+3:eop_base+1];
        is_eop_1     = tuser[eop_base+4];
        eop_offset_1 = tuser[eop_base+7:eop_base+5];
        tag_9_8      = tuser[eop_base+9:eop_base+8];

    endfunction : decode_cq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-11）：
    //   DATA_WIDTH=64/128  -> 33-bit tuser（parity 8/16 bits，字段总宽 33）
    //   DATA_WIDTH=256     -> 81-bit tuser（parity 32 bits）
    //   DATA_WIDTH=512     -> 161-bit tuser（parity 64 bits）
    //
    // CC tuser 结构最简单，只含 discontinue 和 parity 两个有意义的字段：
    //   [0]       discontinue
    //   [parity_bits:1]  parity（DATA_WIDTH/8 bits）
    // -------------------------------------------------------------------------

    // encode_cc_tuser: 将 discontinue 和 parity 打包成 CC tuser 向量
    // 返回类型为最大宽度 bit[160:0]
    //
    // 参数说明：
    //   discontinue          不连续标志
    //   tdata       [511:0]  对应 AXI-Stream 数据（用于 parity 计算）
    function bit [160:0] encode_cc_tuser(
        bit         discontinue,
        bit [511:0] tdata
    );
        bit [160:0] tuser;       // 最大宽度返回值
        int         parity_bits; // parity 位数 = DATA_WIDTH/8
        bit [63:0]  parity;      // 计算得到的 parity 向量

        tuser       = '0;
        parity_bits = DATA_WIDTH / 8;
        parity      = calc_parity(tdata);

        // [0]         discontinue：不连续标志
        tuser[0]    = discontinue;

        // parity 字段：从 bit 1 开始，宽度为 parity_bits
        // 64/128-bit: parity_bits=8/16 bits，高位补零
        // 256-bit: [32:1]（32 bits），512-bit: [64:1]（64 bits）
        tuser[parity_bits:1] = parity[parity_bits-1:0];

        return tuser;
    endfunction : encode_cc_tuser

    // decode_cc_tuser: 从 CC tuser 向量中提取 discontinue 字段
    // parity 字段用于数据完整性验证，此处只提取控制字段
    function void decode_cc_tuser(
        input  bit [160:0] tuser,
        output bit         discontinue
    );
        // [0] discontinue：不连续标志（CC tuser 中唯一的控制字段）
        discontinue = tuser[0];
    endfunction : decode_cc_tuser

endclass : xilinx_tuser_codec

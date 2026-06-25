# Xilinx PCIe TL-Layer BFM 集成与使用指南

本文档说明如何把 `xilinx_pcie` BFM 集成进仿真环境并使用：依赖与构建链、编译期参数、8 通道接线与角色、`env_config` 配置、运行测试、自写 test/vseq、连接真实 Xilinx PCIe IP、复位接线注意点，以及已知陷阱。

> 设计原理（codec / tuser / straddle / router / agent / scoreboard 内部实现）见
> `docs/superpowers/specs/2026-04-27-xilinx-pcie-bfm-design.md`。本文只讲**怎么用**。

---

## 目录

1. [架构：组合复用三方 VIP](#1-架构组合复用三方-vip)
2. [依赖与构建链（含路径陷阱）](#2-依赖与构建链含路径陷阱)
3. [编译期参数](#3-编译期参数)
4. [8 通道接线与角色](#4-8-通道接线与角色)
5. [env_config 配置参考](#5-env_config-配置参考)
6. [运行测试](#6-运行测试)
7. [测试 / vseq / seq 库与自写 test](#7-测试--vseq--seq-库与自写-test)
8. [连接真实 Xilinx PCIe IP](#8-连接真实-xilinx-pcie-ip)
9. [复位接线注意点](#9-复位接线注意点)
10. [已知陷阱](#10-已知陷阱)

---

## 1. 架构：组合复用三方 VIP

`xilinx_pcie` 不自造底层，**组合复用**三个上游 VIP：

| 上游 | 提供 | 在本项目的角色 |
|------|------|----------------|
| `axis_work/axis_vip` | AXI-Stream VIP（`axis_if` / `axis_agent` / driver / monitor / `axis_config`） | 每条 PCIe 通道的物理层激励/采样，8 个 `axis_agent` |
| `pcie_work/pcie_tl_vip` | PCIe TL 层 TLP 类型、序列、`pcie_tl_pkg` | TLP 抽象、事务生成 |
| `shm_work/host_mem` | 统一内存模型（`host_mem_manager` / `host_mem_api`） | 统一内存测试（`use_unified_mem=1` 时） |

本项目自身实现：descriptor codec（RQ/RC/CQ/CC）、tuser codec、straddle 引擎、channel router、RC/EP agent、scoreboard、coverage、PCIe 序列库。

数据通路：`pcie_tl_tlp` ⇄ descriptor codec ⇄ AXI-Stream beat（经 8 个 `axis_agent`）⇄ DUT。

---

## 2. 依赖与构建链（含路径陷阱）

### 编译文件顺序（`sim/filelist.f`）

依赖必须**自底向上**编译，顺序固定：

```
1. axis_vip（经 -f 引用 lib-only filelist）
   -f <axis_vip>/sim/filelist_lib.f      // 仅 axis_if + axis_pkg，无 tests/tb/SVA
2. host_mem（统一内存模型）
   +incdir <shm_work>/host_mem/src
   <shm_work>/host_mem/src/host_mem_pkg.sv
   <shm_work>/host_mem/src/host_mem_manager.sv
3. pcie_tl_vip
   +incdir <pcie_work>/pcie_tl_vip/src（及各子目录）
   <pcie_work>/pcie_tl_vip/src/pcie_tl_if.sv     // 接口，包外
   <pcie_work>/pcie_tl_vip/src/pcie_tl_pkg.sv
4. xilinx_pcie（本项目）
   +incdir <axis_vip>/src + 本项目各 src 子目录
   src/interface/xilinx_pcie_if.sv               // 接口，包外，先于 pkg
   src/interface/xilinx_pcie_cfg_if.sv
   src/xilinx_pcie_pkg.sv                         // 顶层 package
   tb/xilinx_pcie_loopback_dut.sv
   tb/tb_top.sv                                   // 默认仿真顶层
   tests/*.sv
```

四个项目缺一不可：`axis_work`、`pcie_work`、`shm_work`、`xilinx_pcie`。

### ⚠️ 路径陷阱（务必读）

**`filelist.f` 与 `filelist_lib.f` 里的路径是硬编码绝对路径**（`/home/ubuntu/ryan/...`）。换机器/换目录时：

1. **逐机 sed**：`sed -i 's#/home/ubuntu/ryan#<新根>#g' xilinx_pcie/sim/filelist.f axis_work/axis_vip/sim/filelist_lib.f`。
   - `filelist.f` 内**同时**引用 axis/shm/pcie/xilinx 四方绝对路径，且 `filelist_lib.f` 内部也有绝对路径，**两个文件都要 sed**。
   - 若某机上的副本**已被前一次 sed 改成别的根**（如 `/home/ryan`），新一轮 relocate 时要 sed **两种** pattern（旧根 + 上一次的根），否则编译会**静默用错路径的源**。

2. **版本错位（高危）**：`filelist.f` 把 axis 解析到 `<根>/axis_work/axis_vip`。若该处是一份**过期副本**（非当前 git），编译会用旧 axis 而**不报错**——修复/改动静默丢失。集成或回归前务必确认 axis 副本是**最新版**（从 git 拉，或 rsync 覆盖）。

3. **盘满时的离线构建**：把 `{axis_work, pcie_work, shm_work, xilinx_pcie}` 镜像到一个可写根（保持目录名），rsync 最新 axis 覆盖，sed 两文件路径到该根，再编译。

---

## 3. 编译期参数

由 `+define+` 驱动，定义在 `src/xilinx_pcie_params.svh`：

| 宏 | 默认 | 说明 |
|----|------|------|
| `DATA_WIDTH` | 256 | AXI-Stream 数据位宽，合法值 **64 / 128 / 256 / 512**，须与真实 PCIe IP 配置一致 |
| `STRADDLE_EN` | 0 | straddle（跨 beat TLP 对齐）使能，**仅 DATA_WIDTH ≥ 256 有效** |

各通道 TUSER 宽度由 `DATA_WIDTH` 自动推导（PG213）：

| 通道 | DW=64/128 | DW=256 | DW=512 |
|------|-----------|--------|--------|
| RQ (`XILINX_RQ_TUSER_W`) | 62 | 137 | 285 |
| RC (`XILINX_RC_TUSER_W`) | 75 | 161 | 321 |
| CQ (`XILINX_CQ_TUSER_W`) | 88 | 183 | 375 |
| CC (`XILINX_CC_TUSER_W`) | 33 | 81 | 161 |

`XILINX_KEEP_W = DATA_WIDTH/32`（PCIe tkeep 为 per-DW；axis tkeep 为 per-byte，tb 内做转换）。

编译/运行时务必让 `+define+DATA_WIDTH` 与 `+DATA_WIDTH` plusarg 一致（见 §6）。

---

## 4. 8 通道接线与角色

PCIe 有 RC、EP 两侧，各 4 条 AXI-Stream 通道（RQ/RC/CQ/CC），共 **8 个 `axis_agent`**。每通道按 PG213 真实 TUSER 宽度独立参数化。

### 各通道 axis 角色（`xilinx_pcie_env_config::create_axis_config` 设定）

| 通道 | RC 侧角色 | EP 侧角色 | 含义 |
|------|----------|----------|------|
| RQ | SLAVE | **MASTER** | 请求发出 |
| RC | **MASTER** | SLAVE | Completion 返回 |
| CQ | **MASTER** | SLAVE | 请求到达 |
| CC | SLAVE | **MASTER** | Completion 返回 |

（MASTER 驱动 tvalid/tdata，SLAVE 驱动 tready。tb_top 的 `assign` 桥接与此一致。）

### tb_top 接线要点（回环仿真）

- 时钟：250 MHz（`always #2ns clk = ~clk`，4ns 周期）。
- 复位：`rst_n` 低有效，拉低 10+1 周期后释放。所有 `axis_if(.aresetn(rst_n))` 与 `xilinx_pcie_if(.rst_n(rst_n))` 共用。
- `axis_if` 实例参数：`#(DATA_WIDTH, 4, 4, <通道>_TUSER_WIDTH, 0, 1, 1)`（TID=TDEST=4，HAS_TSTRB=0，HAS_TKEEP=1，HAS_TLAST=1）。
- tkeep 转换：axis per-byte ⇄ pcie per-DW（`byte_keep_to_dw_keep` / `dw_keep_to_byte_keep`）。

### config_db 注册路径（vif 下发）

```systemverilog
// RC 侧四通道（EP 侧同理，路径前缀 ep_agent）
uvm_config_db#(vif_rq_t)::set(null,"uvm_test_top.env.rc_agent.rq_agent*","vif",rc_rq_if);
uvm_config_db#(vif_rc_t)::set(null,"uvm_test_top.env.rc_agent.rc_agent*","vif",rc_rc_if);
uvm_config_db#(vif_cq_t)::set(null,"uvm_test_top.env.rc_agent.cq_agent*","vif",rc_cq_if);
uvm_config_db#(vif_cc_t)::set(null,"uvm_test_top.env.rc_agent.cc_agent*","vif",rc_cc_if);
// cfg / interrupt agent
uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,"uvm_test_top.env.rc_cfg_agent*","cfg_vif",rc_cfg_if);
uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,"uvm_test_top.env.rc_int_agent*","cfg_vif",rc_cfg_if);
// 统一内存句柄（默认 use_unified_mem=0 时不被使用）
uvm_config_db#(host_mem_api)::set(null,"uvm_test_top.env","host_mem",host_mem_inst);
uvm_config_db#(host_mem_api)::set(null,"uvm_test_top.env","dev_mem", dev_mem_inst);
```

env 组件实例名：`rc_agent` / `ep_agent`（各含 `rq_agent`/`rc_agent`/`cq_agent`/`cc_agent`）、`rc_cfg_agent` / `ep_cfg_agent` / `rc_int_agent` / `ep_int_agent`、`v_sqr`（virtual sequencer）、`scb`（scoreboard）、`cov`（coverage）。

> vif typedef 的 7 个参数必须与 `xilinx_pcie_pkg` 内 `axis_agent_xx_t` 的内部 `vif_t` **完全一致**（DATA_WIDTH、各通道 TUSER 宽度），否则 config_db 类型不匹配、取不到 vif。

---

## 5. env_config 配置参考

`xilinx_pcie_env_config` 单对象集中配置，test 里 create 后下发到 env。常用字段（默认值）：

### 链路 / 能力

| 字段 | 默认 | 说明 |
|------|------|------|
| `DATA_WIDTH` | `XILINX_DATA_W` | 须与编译期 `+define+DATA_WIDTH` 一致 |
| `straddle_enable` | 0 | straddle 使能（DW≥256） |
| `max_payload_size` (MPS) | 256 | 字节，128/256/512/1024/2048/4096 |
| `max_read_request_size` (MRRS) | 512 | 字节 |
| `read_completion_boundary` (RCB) | 64 | 字节 |
| `link_width` | 8 | x1/x2/x4/x8/x16 |
| `extended_tag_enable` | 1 | 10-bit Tag |
| `max_outstanding` | 256 | 最大未完成请求 |

### 流控 / 排序

| 字段 | 默认 | 说明 |
|------|------|------|
| `fc_enable` / `infinite_credit` | 1 / 1 | 流控、无限信用 |
| `init_ph/pd/nph/npd/cplh/cpld_credit` | 32/256/32/256/32/256 | 初始信用 |
| `relaxed_ordering_enable` / `id_based_ordering_enable` | 1 / 1 | 排序属性 |

### Config / 中断

| 字段 | 默认 | 说明 |
|------|------|------|
| `cfg_enable` | 1 | config 空间使能 |
| `vendor_id` / `device_id` | 10EE / 9038 | Xilinx 默认 |
| `class_code` | 02_00_00 | |
| `interrupt_enable` / `msi_vector_count` | 1 / 1 | MSI |
| `msix_table_size` / `msix_table_bar` / `msix_table_offset` | 0 / 0 / 0 | MSI-X |

### 带宽（valid/ready 节奏，透传给 axis_config）

| 字段 | 默认 | 说明 |
|------|------|------|
| `tx_valid_mode` | `VALID_ZERO_IDLE` | 发送节奏（**零延时满吞吐**） |
| `tx_idle_cycles` / `tx_valid_weight` | 0 / 100 | |
| `rx_ready_mode` / `rx_ready_weight` | — / 100 | 接收背压 |
| `per_channel_bw_config` | 0 | 1 时逐通道独立配 `channel_bw_cfg[]` |

### EP 自动响应 / 内存 / 超时

| 字段 | 默认 | 说明 |
|------|------|------|
| `ep_auto_response` | 1 | EP 自动回 Completion |
| `response_delay_min/max` | 0 / 10 | 响应延迟（周期） |
| `use_unified_mem` | 0 | 1 时启用统一内存（需 §4 句柄） |
| `mem_size` | 4 GB | 内存模型大小 |
| `cpl_timeout_ns` | 50000 | Completion 超时 |

### 检查 / 覆盖率

| 字段 | 默认 | 说明 |
|------|------|------|
| `scb_enable` / `scb_completion_check` / `scb_data_integrity` / `scb_ordering_check` / `scb_descriptor_check` | 全 1 | scoreboard 各检查项 |
| `rq/rc/cq/cc_protocol_check_enable` | 全 1 | 各通道协议检查 |
| `desc_format_check_enable` / `tuser_consistency_check` / `payload_alignment_check` | 全 1 | |
| `cov_enable` 及 `cov_*` | **全 0** | 覆盖率默认关，按需开 |

---

## 6. 运行测试

```bash
cd xilinx_pcie/sim

make compile                              # 仅编译（默认 DATA_WIDTH=256, STRADDLE_EN=0）
make sim TEST=xilinx_pcie_sanity_test     # 跑指定 test（需先 compile）
make sanity                               # 编译+跑 sanity
make straddle                             # 编译+跑 straddle（STRADDLE_EN=1）
make loopback                             # 编译+跑 loopback
make clean

# 改位宽 / straddle / 种子
make sanity DATA_WIDTH=512
make straddle DATA_WIDTH=256 STRADDLE_EN=1
make sim TEST=xilinx_pcie_stress_test SEED=random
```

直接 VCS 命令（离线/自定义构建）：

```bash
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 \
    -f filelist.f +define+DATA_WIDTH=256 +define+STRADDLE_EN=0 -o work/simv
./work/simv +UVM_TESTNAME=xilinx_pcie_sanity_test +DATA_WIDTH=256 +STRADDLE_EN=0 +ntb_random_seed=1
```

> **plusarg 与 define 必须一致**：`+define+DATA_WIDTH=N`（编译期，定宽度）与 `+DATA_WIDTH=N`（运行期，传给 env_config）须相同。STRADDLE 同理。

可用 test：`xilinx_pcie_sanity_test` / `loopback_test` / `straddle_test` / `stress_test` / `mega_stress_test` / `unified_mem_test`（均继承 `xilinx_pcie_base_test`）。

### 判定 PASS

`UVM_ERROR = 0` 且 `UVM_FATAL = 0`；scoreboard 无 mismatch。

---

## 7. 测试 / vseq / seq 库与自写 test

### test → vseq 映射

| test | 启动的 vseq |
|------|-------------|
| sanity / loopback / straddle / stress | `xilinx_pcie_loopback_vseq` |
| mega_stress | `xilinx_pcie_mega_stress_vseq` |
| unified_mem | `xilinx_pcie_unified_mem_vseq` |

`xilinx_pcie_loopback_vseq` 覆盖：Config 枚举（CfgRd0）→ Memory Write/Read（MWr/MRd + CplD）→ DMA Write/Read → MSI 中断。旋钮：`num_transactions`、`max_payload_bytes`。

### seq 库（`src/seq/`）

`base` / `cfg`（配置读写）/ `mem`（MWr/MRd）/ `dma`（EP DMA）/ `msi`（中断）/ `atomic`（原子操作）。vseq：`loopback` / `mega_stress` / `unified_mem`。

### 自写 test 模板

```systemverilog
class my_pcie_test extends xilinx_pcie_base_test;
  `uvm_component_utils(my_pcie_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction

  task run_phase(uvm_phase phase);
    xilinx_pcie_loopback_vseq vseq;
    phase.raise_objection(this);
    vseq = xilinx_pcie_loopback_vseq::type_id::create("vseq");
    vseq.num_transactions  = 50;
    vseq.max_payload_bytes = 256;
    vseq.start(env.v_sqr);            // 在 virtual sequencer 上启动
    #50us;                            // drain：等 EP CplD 全部回完
    phase.drop_objection(this);
  endtask
endclass
```

> drain 时间要足够长（sanity 用 `#50us`）——MWr+MRd 对需等 EP 的 CplD 全部传回，过短会漏判。

---

## 8. 连接真实 Xilinx PCIe IP

回环仿真用 `tb/tb_top.sv` + `tb/xilinx_pcie_loopback_dut.sv`。接真实 Xilinx PCIe IP 时改用 `tb/tb_with_dut.sv`（模板，默认不参与编译）。

PG213 AXI-Stream 端口对应（EP 侧）：

| Xilinx IP 端口 | 方向 | 对应 `ep_if` 通道 |
|----------------|------|-------------------|
| `m_axis_rq_*` | EP → IP 请求 | `ep_if.rq_*` |
| `s_axis_rc_*` | IP → EP 完成 | `ep_if.rc_*` |
| `s_axis_cq_*` | IP → EP 请求 | `ep_if.cq_*` |
| `m_axis_cc_*` | EP → IP 完成 | `ep_if.cc_*` |

步骤（见 `tb_with_dut.sv` 头注释）：

1. 取消注释真实 DUT 实例化段落；
2. 把 `xdma_0` 换成实际 PCIe IP wrapper 模块名；
3. 按实际 IP 端口列表增删端口映射；
4. `filelist.f` 里把 `tb_top.sv` 换成 `tb_with_dut.sv` 作仿真顶层；
5. `+define+DATA_WIDTH=N` 须与真实 IP 配置一致。

---

## 9. 复位接线注意点

- **xilinx_pcie 不实例化 `axis_env`，也不接 `axis_reset_handler`。** 各 `axis_agent` 的 `rst_listener` 在 `connect_phase` 被连到 **dummy 事件**（防 null 访问），这些事件**永不触发**。
- 因此 axis VIP 的"env 级复位编排"在本项目里**被绕过**——复位完全由共享的 `rst_n`（低有效）经各 `axis_if.aresetn` 驱动。
- axis driver/monitor **直接采样 `aresetn`** 门控复位（按 `axis_config.reset_polarity`，默认 `AXIS_RESET_ACTIVE_LOW`，与 `rst_n` 极性匹配）：`rst_n=0` 期间 master 压低 tvalid、slave 压低 tready、monitor 不采样；释放后 master 首拍对齐时钟沿再驱动。**无需额外接线**，但需知道复位语义来自 `rst_n` 而非 axis 的 reset_handler。
- 接真实 DUT 时，确保 PCIe IP 的 user reset 与各 `axis_if.aresetn` 一致（低有效）。若 DUT 复位为高有效，需把对应 `axis_config.reset_polarity` 改为 `AXIS_RESET_ACTIVE_HIGH`。

---

## 10. 已知陷阱

- **路径硬编码 + 版本错位**（§2）：filelist 绝对路径需逐机 sed；务必确认 axis 副本是最新版，否则修复静默丢失。**集成/回归前先核对。**
- **straddle 仅 DATA_WIDTH ≥ 256**：低于此宽度开 `STRADDLE_EN=1` 无效/可能 FATAL。
- **define 与 plusarg 必须一致**：`+define+DATA_WIDTH` 与 `+DATA_WIDTH` 不一致会导致 env_config 与硬件宽度错配。
- **drain 时间**：vseq 跑完后需留足 drain（如 `#50us`）等 EP CplD 回完，否则漏判。
- **覆盖率默认关**：`cov_enable=0`，要测覆盖率须显式打开 `cov_*`。
- **统一内存默认关**：`use_unified_mem=0`；开启需注入 `host_mem`/`dev_mem` 句柄（tb_top 已注册，见 §4）。
- **回归基线**：在更新版 axis 上，`sanity/loopback/stress/unified_mem/straddle`@DW=256 与 `sanity`@DW=512 全部 `UVM_ERROR=0`（已实测）。

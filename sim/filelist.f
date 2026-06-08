//=============================================================================
// Xilinx PCIe TL-Layer BFM - VCS 编译文件列表
// 使用方法：vcs -f filelist.f <其他选项>
//=============================================================================

//-----------------------------------------------------------------------------
// 1. AXI-Stream VIP（axis_work）：引用 lib-only filelist（绝对路径，无 tests/tb）
//-----------------------------------------------------------------------------
-f /home/ubuntu/ryan/axis_work/axis_vip/sim/filelist_lib.f

//-----------------------------------------------------------------------------
// 2. PCIe TL VIP（pcie_work）：头文件搜索路径 + 源文件
//-----------------------------------------------------------------------------

// 头文件搜索路径（各子目录均需加入，以便 `include 能找到对应文件）
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/types
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/shared
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/agent
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/env
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/adapter
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/seq/base
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/seq/constraints
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/seq/scenario
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/seq/virtual
+incdir+/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/switch

// PCIe TL VIP 接口文件（模块，不在 package 内，需单独编译）
/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_if.sv

// PCIe TL VIP 顶层 package（包含所有类、序列、类型定义）
/home/ubuntu/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_pkg.sv

//-----------------------------------------------------------------------------
// 3. Xilinx PCIe BFM（本项目）：头文件搜索路径 + 源文件
//-----------------------------------------------------------------------------

// 头文件搜索路径
+incdir+/home/ubuntu/ryan/axis_work/axis_vip/src
+incdir+/home/ubuntu/ryan/xilinx_pcie/src
+incdir+/home/ubuntu/ryan/xilinx_pcie/src/codec
+incdir+/home/ubuntu/ryan/xilinx_pcie/src/agent
+incdir+/home/ubuntu/ryan/xilinx_pcie/src/cfg
+incdir+/home/ubuntu/ryan/xilinx_pcie/src/env
+incdir+/home/ubuntu/ryan/xilinx_pcie/src/seq

// 接口文件（模块，不在 package 内，需先于 package 编译）
/home/ubuntu/ryan/xilinx_pcie/src/interface/xilinx_pcie_if.sv
/home/ubuntu/ryan/xilinx_pcie/src/interface/xilinx_pcie_cfg_if.sv

// 顶层 package（包含所有类型、类、codec、agent、env、seq 定义）
/home/ubuntu/ryan/xilinx_pcie/src/xilinx_pcie_pkg.sv

// 测试平台文件（TB modules）
// 回环 DUT：将 RC/EP 四通道交叉连线
/home/ubuntu/ryan/xilinx_pcie/tb/xilinx_pcie_loopback_dut.sv
// 回环仿真顶层（默认编译目标）
/home/ubuntu/ryan/xilinx_pcie/tb/tb_top.sv
// 真实 DUT 连接模板（连接到 Xilinx PCIe IP 时使用，替换 tb_top.sv）
// /home/ubuntu/ryan/xilinx_pcie/tb/tb_with_dut.sv

// 测试用例文件（各 test class，后续 Task 创建）
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_base_test.sv
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_sanity_test.sv
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_straddle_test.sv
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_loopback_test.sv
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_stress_test.sv
/home/ubuntu/ryan/xilinx_pcie/tests/xilinx_pcie_mega_stress_test.sv

`ifndef XILINX_PCIE_CONNECT_SVH
`define XILINX_PCIE_CONNECT_SVH
// 多 agent 连线宏：用户在 tb 里逐 agent 调用。区分 RC/EP（各通道 master/slave 方向相反）。
// 用法: `XILINX_PCIE_WIRE_EP(0, ep_if, ep_cfg_if, clk, rst_n)
// 契约: 调用次数必须 >= env_config.num_<role>，否则 env 取 vif 时 uvm_fatal。

// 共享 tkeep 转换（automatic 可重入，整个编译单元定义一次）
function automatic logic [(`XILINX_KEEP_W)-1:0] xilinx_byte_keep_to_dw(
    input logic [(`XILINX_DATA_W/8)-1:0] bk);
  for (int dw=0; dw<`XILINX_KEEP_W; dw++) xilinx_byte_keep_to_dw[dw] = |bk[dw*4 +: 4];
endfunction
function automatic logic [(`XILINX_DATA_W/8)-1:0] xilinx_dw_keep_to_byte(
    input logic [(`XILINX_KEEP_W)-1:0] dk);
  xilinx_dw_keep_to_byte = '0;
  for (int dw=0; dw<`XILINX_KEEP_W; dw++) if (dk[dw]) xilinx_dw_keep_to_byte[dw*4 +: 4] = 4'hF;
endfunction

// ---- RC: RQ/CC = axis SLAVE(pcie->axis), RC/CQ = axis MASTER(axis->pcie) ----
`define XILINX_PCIE_WIRE_RC(IDX, PCIE_IF, CFG_IF, CLK, RSTN)                                       \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rc_agent_``IDX``_rq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc_agent_``IDX``_rc_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) rc_agent_``IDX``_cq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) rc_agent_``IDX``_cc_if(.aclk(CLK),.aresetn(RSTN)); \
  /* RQ slave: pcie->axis */                                                                      \
  assign rc_agent_``IDX``_rq_if.tdata=PCIE_IF.rq_tdata; assign rc_agent_``IDX``_rq_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.rq_tkeep); \
  assign rc_agent_``IDX``_rq_if.tlast=PCIE_IF.rq_tlast; assign rc_agent_``IDX``_rq_if.tvalid=PCIE_IF.rq_tvalid; \
  assign rc_agent_``IDX``_rq_if.tuser=PCIE_IF.rq_tuser; assign PCIE_IF.rq_tready=rc_agent_``IDX``_rq_if.tready; \
  /* CC slave: pcie->axis */                                                                      \
  assign rc_agent_``IDX``_cc_if.tdata=PCIE_IF.cc_tdata; assign rc_agent_``IDX``_cc_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.cc_tkeep); \
  assign rc_agent_``IDX``_cc_if.tlast=PCIE_IF.cc_tlast; assign rc_agent_``IDX``_cc_if.tvalid=PCIE_IF.cc_tvalid; \
  assign rc_agent_``IDX``_cc_if.tuser=PCIE_IF.cc_tuser; assign PCIE_IF.cc_tready=rc_agent_``IDX``_cc_if.tready; \
  /* RC master: axis->pcie */                                                                     \
  assign PCIE_IF.rc_tdata=rc_agent_``IDX``_rc_if.tdata; assign PCIE_IF.rc_tkeep=xilinx_byte_keep_to_dw(rc_agent_``IDX``_rc_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.rc_tlast=rc_agent_``IDX``_rc_if.tlast; assign PCIE_IF.rc_tvalid=rc_agent_``IDX``_rc_if.tvalid; \
  assign PCIE_IF.rc_tuser=rc_agent_``IDX``_rc_if.tuser; assign rc_agent_``IDX``_rc_if.tready=PCIE_IF.rc_tready; \
  /* CQ master: axis->pcie */                                                                     \
  assign PCIE_IF.cq_tdata=rc_agent_``IDX``_cq_if.tdata; assign PCIE_IF.cq_tkeep=xilinx_byte_keep_to_dw(rc_agent_``IDX``_cq_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.cq_tlast=rc_agent_``IDX``_cq_if.tlast; assign PCIE_IF.cq_tvalid=rc_agent_``IDX``_cq_if.tvalid; \
  assign PCIE_IF.cq_tuser=rc_agent_``IDX``_cq_if.tuser; assign rc_agent_``IDX``_cq_if.tready=PCIE_IF.cq_tready; \
  initial begin                                                                                   \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.rq_agent*",IDX),"vif",rc_agent_``IDX``_rq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.rc_agent*",IDX),"vif",rc_agent_``IDX``_rc_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.cq_agent*",IDX),"vif",rc_agent_``IDX``_cq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.cc_agent*",IDX),"vif",rc_agent_``IDX``_cc_if); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.rc_int_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
  end

// ---- EP: RQ/CC = axis MASTER(axis->pcie), RC/CQ = axis SLAVE(pcie->axis) ----
`define XILINX_PCIE_WIRE_EP(IDX, PCIE_IF, CFG_IF, CLK, RSTN)                                       \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) ep_agent_``IDX``_rq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) ep_agent_``IDX``_rc_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) ep_agent_``IDX``_cq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) ep_agent_``IDX``_cc_if(.aclk(CLK),.aresetn(RSTN)); \
  /* RQ master: axis->pcie */                                                                     \
  assign PCIE_IF.rq_tdata=ep_agent_``IDX``_rq_if.tdata; assign PCIE_IF.rq_tkeep=xilinx_byte_keep_to_dw(ep_agent_``IDX``_rq_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.rq_tlast=ep_agent_``IDX``_rq_if.tlast; assign PCIE_IF.rq_tvalid=ep_agent_``IDX``_rq_if.tvalid; \
  assign PCIE_IF.rq_tuser=ep_agent_``IDX``_rq_if.tuser; assign ep_agent_``IDX``_rq_if.tready=PCIE_IF.rq_tready; \
  /* CC master: axis->pcie */                                                                     \
  assign PCIE_IF.cc_tdata=ep_agent_``IDX``_cc_if.tdata; assign PCIE_IF.cc_tkeep=xilinx_byte_keep_to_dw(ep_agent_``IDX``_cc_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.cc_tlast=ep_agent_``IDX``_cc_if.tlast; assign PCIE_IF.cc_tvalid=ep_agent_``IDX``_cc_if.tvalid; \
  assign PCIE_IF.cc_tuser=ep_agent_``IDX``_cc_if.tuser; assign ep_agent_``IDX``_cc_if.tready=PCIE_IF.cc_tready; \
  /* RC slave: pcie->axis */                                                                      \
  assign ep_agent_``IDX``_rc_if.tdata=PCIE_IF.rc_tdata; assign ep_agent_``IDX``_rc_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.rc_tkeep); \
  assign ep_agent_``IDX``_rc_if.tlast=PCIE_IF.rc_tlast; assign ep_agent_``IDX``_rc_if.tvalid=PCIE_IF.rc_tvalid; \
  assign ep_agent_``IDX``_rc_if.tuser=PCIE_IF.rc_tuser; assign PCIE_IF.rc_tready=ep_agent_``IDX``_rc_if.tready; \
  /* CQ slave: pcie->axis */                                                                      \
  assign ep_agent_``IDX``_cq_if.tdata=PCIE_IF.cq_tdata; assign ep_agent_``IDX``_cq_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.cq_tkeep); \
  assign ep_agent_``IDX``_cq_if.tlast=PCIE_IF.cq_tlast; assign ep_agent_``IDX``_cq_if.tvalid=PCIE_IF.cq_tvalid; \
  assign ep_agent_``IDX``_cq_if.tuser=PCIE_IF.cq_tuser; assign PCIE_IF.cq_tready=ep_agent_``IDX``_cq_if.tready; \
  initial begin                                                                                   \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.rq_agent*",IDX),"vif",ep_agent_``IDX``_rq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.rc_agent*",IDX),"vif",ep_agent_``IDX``_rc_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.cq_agent*",IDX),"vif",ep_agent_``IDX``_cq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.cc_agent*",IDX),"vif",ep_agent_``IDX``_cc_if); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.ep_int_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
  end
`endif

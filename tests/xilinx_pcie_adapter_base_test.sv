import uvm_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

class xilinx_pcie_adapter_base_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_base_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this); #100ns; phase.drop_objection(this);
  endtask
endclass

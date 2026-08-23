// -----------------------------------------------------------------------------
// Functional coverage on real delivered traffic (subscribes to the monitor's
// output analysis port). Scope-appropriate items only:
//   input port, output port, backpressure, input x output.
// Goal at this milestone: prove covergroup sampling/bins/cross work
// end-to-end under Verilator 5.050 — not coverage closure.
//
// Note: the covergroup uses `with function sample(...)` arguments, since
// coverpoints referencing enclosing class members are unsupported in
// this simulator version (COVERIGN) — see docs/compatibility.md.
// -----------------------------------------------------------------------------
class floonoc_cov extends uvm_subscriber #(floonoc_flit_item);

  `uvm_component_utils(floonoc_cov)

  int unsigned n_sampled;

  covergroup flit_cg with function sample(int unsigned src, int unsigned dst_out, bit bp);
    option.per_instance = 1;
    cp_src : coverpoint src {
      bins north = {0};
      bins east  = {1};
      bins south = {2};
      bins west  = {3};
      bins eject = {4};
    }
    cp_out : coverpoint dst_out {
      bins north = {0};
      bins east  = {1};
      bins south = {2};
      bins west  = {3};
      bins eject = {4};
    }
    cp_backpressure : coverpoint bp {
      bins stalled = {1};
      bins free    = {0};
    }
    x_src_out : cross cp_src, cp_out;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    flit_cg = new();
  endfunction

  virtual function void write(floonoc_flit_item t);
    flit_cg.sample(t.src_port, t.out_port, t.backpressured);
    n_sampled++;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV", $sformatf("sampled %0d flits, flit_cg coverage = %0.1f%%",
              n_sampled, flit_cg.get_inst_coverage()), UVM_LOW)
  endfunction

endclass : floonoc_cov

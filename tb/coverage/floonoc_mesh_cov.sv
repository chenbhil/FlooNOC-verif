// -----------------------------------------------------------------------------
// Functional coverage on real delivered traffic (subscribes to the monitor's
// output analysis port). Scope-appropriate items only: source router,
// destination router, hop count, backpressure, and the src x dst cross.
//
// Bin ranges are derived from NumRouters / MeshDiameter, so a larger mesh
// needs no edit here.
//
// Note: the covergroup uses `with function sample(...)` arguments, since
// coverpoints referencing enclosing class members are unsupported in this
// simulator version (COVERIGN) — see docs/compatibility.md.
// -----------------------------------------------------------------------------
class floonoc_mesh_cov extends uvm_subscriber #(floonoc_mesh_flit_item);

  `uvm_component_utils(floonoc_mesh_cov)

  int unsigned n_sampled;

  covergroup flit_cg with function sample(int unsigned src, int unsigned dst,
                                          int unsigned hops, bit bp);
    option.per_instance = 1;

    cp_src_router : coverpoint src {
      bins r[] = {[0:NumRouters-1]};
    }
    cp_dst_router : coverpoint dst {
      bins r[] = {[0:NumRouters-1]};
    }
    // Minimum 1 hop (src == dst is illegal), maximum the mesh diameter.
    cp_hops : coverpoint hops {
      bins h[] = {[1:MeshDiameter]};
    }
    cp_backpressure : coverpoint bp {
      bins stalled = {1};
      bins free    = {0};
    }

    // The src == dst diagonal is unreachable by construction (c_legal_route),
    // so N of the N^2 cross bins can never be hit and this cross tops out at
    // (N^2-N)/N^2 — 75% on a 2x2 mesh. It SHOULD carry
    //   ignore_bins loopback = x_src_dst with (cp_src_router == cp_dst_router);
    // but Verilator 5.052 cannot parse a `with` clause on a cross:
    //   %Error: syntax error, unexpected with-then-(, expecting '('
    // Hand-enumerating binsof/intersect per router instead would hardcode the
    // mesh size, which is exactly the genericity this file is built to keep,
    // so the unreachable bins are left in and documented rather than papered
    // over — see docs/uvm_coverage.md. Read the cross number against a 75%
    // ceiling on a 2x2 mesh, not 100%.
    x_src_dst : cross cp_src_router, cp_dst_router;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    flit_cg = new();
  endfunction

  virtual function void write(floonoc_mesh_flit_item t);
    flit_cg.sample(t.src_router, t.out_router, t.exp_hops(), t.backpressured);
    n_sampled++;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV", $sformatf("sampled %0d flits, flit_cg coverage = %0.1f%%",
              n_sampled, flit_cg.get_inst_coverage()), UVM_LOW)
  endfunction

endclass : floonoc_mesh_cov

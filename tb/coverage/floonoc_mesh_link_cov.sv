// -----------------------------------------------------------------------------
// Link coverage: one bin per directed router-to-router link that EXISTS in
// the mesh (subscribes to floonoc_mesh_link_monitor::hop_ap).
//
// Bins are over link_index(), a dense numbering of the (router, direction)
// pairs for which has_neighbor() holds, so boundary directions have no bin
// at all and nothing is hardcoded to 2x2 (NumLinks = 8 there). Verilator
// 5.052 cannot parse `with` on bins, so the dense index is how
// non-existent links are kept out of the denominator.
//
// Reference: the directed phase of floonoc_mesh_smoke_seq exercises every
// link in both directions, so this should read 100% on the smoke test.
// -----------------------------------------------------------------------------
class floonoc_mesh_link_cov extends uvm_subscriber #(floonoc_mesh_hop_item);

  `uvm_component_utils(floonoc_mesh_link_cov)

  int unsigned n_sampled;

  covergroup link_cg with function sample(int unsigned link);
    option.per_instance = 1;
    cp_link : coverpoint link {
      bins l[] = {[0:NumLinks-1]};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    link_cg = new();
  endfunction

  virtual function void write(floonoc_mesh_hop_item t);
    // Boundary ports never produce a hop item (the monitor errors instead),
    // so link_index() is always called with a real link here.
    link_cg.sample(link_index(t.router, t.dir));
    n_sampled++;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV", $sformatf("sampled %0d link hops, link_cg coverage = %0.1f%% (%0d links)",
              n_sampled, link_cg.get_inst_coverage(), NumLinks), UVM_LOW)
  endfunction

endclass : floonoc_mesh_link_cov

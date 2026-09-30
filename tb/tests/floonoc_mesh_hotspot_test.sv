// -----------------------------------------------------------------------------
// Hotspot test: floonoc_mesh_hotspot_seq instead of the smoke stimulus, with
// the smoke test's watchdogs, drain and PASS criteria (0 errors, matched > 0,
// 0 mismatches). Also creates the hotspot monitor (via config_db
// "hotspot_target"), whose contention coverage / backpressure / arbitration
// report is printed in report_phase.
//
// Plusargs (all optional):
//   +hs_target=<r>   target router (default: centre, router_idx(MeshX/2, MeshY/2))
//   +hs_d=<d>        source distance (default: largest d <= 2 with all four
//                    T+-d inside the mesh, at least 1)
//   +hs_mode=axis|ring
//   +hs_k=<k>        flits per source (default InFifoDepth+OutFifoDepth+1;
//                    with +hs_fill: d*(In+Out) + In + Out + 1)
//   +hs_fill         fill every buffer on each source's path
//   +hs_hold=0|1     hold T's Eject stalled at the start (default 1)
//   +hs_hold_cycles=<H>
// Run:  make run-mesh TEST=floonoc_mesh_hotspot_test MESH_X=5 MESH_Y=5 \
//         PLUSARGS="+hs_mode=ring +hs_fill"
// -----------------------------------------------------------------------------
class floonoc_mesh_hotspot_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_hotspot_test)

  int    target       = -1;
  int    d            = -1;
  bit    ring_mode    = 1'b0;
  int    k            = -1;
  bit    fill         = 1'b0;
  int    hold         = 1;
  int    hold_cycles  = -1;
  int    late_src_idx = -1;   // NM5 only

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string mode;
    void'($value$plusargs("hs_target=%d", target));
    void'($value$plusargs("hs_d=%d", d));
    void'($value$plusargs("hs_k=%d", k));
    void'($value$plusargs("hs_hold=%d", hold));
    void'($value$plusargs("hs_hold_cycles=%d", hold_cycles));
    fill = $test$plusargs("hs_fill");
    if ($value$plusargs("hs_mode=%s", mode)) begin
      if (mode == "ring")      ring_mode = 1'b1;
      else if (mode != "axis") `uvm_fatal("HOTSPOT", {"unknown +hs_mode=", mode, " (axis|ring)"})
    end
    if (target < 0) target = int'(router_idx(MeshX / 2, MeshY / 2));
    uvm_config_db#(int)::set(this, "env", "hotspot_target", target);
    super.build_phase(phase);
  endfunction

  virtual task run_stimulus();
    floonoc_mesh_hotspot_seq seq;
    seq = floonoc_mesh_hotspot_seq::type_id::create("hotspot_seq");
    seq.target       = target;
    seq.d            = d;
    seq.ring_mode    = ring_mode;
    seq.k            = k;
    seq.fill         = fill;
    seq.hold         = (hold != 0);
    seq.hold_cycles  = hold_cycles;
    seq.late_src_idx = late_src_idx;
    seq.start(env.vsqr);
  endtask

endclass : floonoc_mesh_hotspot_test

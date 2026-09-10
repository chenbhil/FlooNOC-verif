// -----------------------------------------------------------------------------
// Interface-level protocol assertions for the FlooNoC mesh bench: the same
// property set as the single-router bench's floonoc_router_sva, applied to
// every router's Eject port instead of to one router's five ports.
//
// Every property is traceable to an upstream contract:
//  - A_IN_VALID_STABLE / A_OUT_VALID_STABLE mirror the DUT's own
//    StableValidIn/StableValidOut assertions (hw/floo_router.sv:494-512
//    @ v0.8.4): once valid is asserted it must remain asserted until the
//    transfer completes (VcNaive configuration).
//  - A_OUT_QUIET_IN_RESET: all output/input buffering resets empty
//    (common_cells stream_fifo/fifo_v3 reset behavior), so no output valid
//    may be asserted while reset is active. See docs/assumptions.md A3.
//
// Deliberately NOT asserted here:
//  - XYDirectionNotAllowed / NoLoopback. These are the DUT's OWN assertions
//    (hw/floo_router.sv:515, :537). They elaborate inside every router
//    instance and run under Verilator's --assert, so re-implementing them at
//    TB level would add no coverage — and could not be written at TB level
//    anyway, since they reference the router's internal route_mask.
//  - Inter-router link protocol. Both ends of every N/E/S/W link are DUT
//    ports, already covered by the DUT's own StableValidIn/Out. Only Eject
//    ports face the TB, and only those carry a TB-side obligation. They are
//    also not reachable from here: since the mesh RTL moved into
//    floonoc_mesh_dut, the inter-router handshakes are internal to that
//    module and no longer visible at tb_top_mesh. If they are ever wanted,
//    the answer is a `bind` inside floonoc_mesh_dut, not a hierarchical
//    reference into i_mesh.gen_routers[...].
//  - Output DATA stability under stall: upstream keeps its equivalent
//    StableDataIn assertion commented out, and the output arbiter may switch
//    payloads between competing inputs while valid is high.
//
// MEASURED VACUITY, 2x2 / 27 flits: A_IN_VALID_STABLE currently never
// evaluates. Its antecedent is `valid_in && !ready_in`, i.e. the DUT
// backpressuring the TB, and C_IN_BACKPRESSURE below reads 0. The reason is
// structural, not a stimulus accident: the mesh holds
// NumRouters * NumPorts * (InFifoDepth + OutFifoDepth) = 4*5*4 = 80 flit
// slots, the driver has at most one flit outstanding at a time, and the
// sequence sends 27 — so no Eject input FIFO can ever fill. Confirmed by
// experiment: with the driver's output ready forced to 0 for the whole run
// (all 27 flits stuck in the mesh, delivered=0) all 27 were still accepted
// on the input side with C_IN_BACKPRESSURE still 0.
//
// The assertion is kept rather than deleted: it is a real TB-side
// obligation, it is live code (mutating its antecedent to the reachable
// `valid_in && ready_in` makes it fire at every router, so the statement is
// compiled and sampled), and it starts doing work the moment the bench
// outgrows the mesh's buffering — more flits in flight, a shallower
// InFifoDepth, or a driver with more than one outstanding item.
// C_IN_BACKPRESSURE is what keeps that fact VISIBLE instead of letting the
// assertion sit silently vacuous; do not delete the cover to make the
// assertion-coverage percentage look better.
// -----------------------------------------------------------------------------
module floonoc_mesh_router_sva
  import floo_tb_mesh_types_pkg::*;
(
  input logic                   clk,
  input logic                   rst_n,
  input logic [NumRouters-1:0]  valid_in,
  input logic [NumRouters-1:0]  ready_in,
  input logic [NumRouters-1:0]  valid_out,
  input logic [NumRouters-1:0]  ready_out
);

  for (genvar r = 0; r < NumRouters; r++) begin : gen_router_sva

    // TB-side obligation: our driver must hold valid until the DUT accepts.
    A_IN_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_in[r] && !ready_in[r] |=> valid_in[r])
      else $error("[SVA] router %0d Eject-in: valid_in dropped before handshake", r);

    // DUT-side guarantee: output valid held until we accept.
    A_OUT_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && !ready_out[r] |=> valid_out[r])
      else $error("[SVA] router %0d Eject-out: valid_out dropped before handshake", r);

    // DUT-side guarantee: outputs quiescent while in reset.
    A_OUT_QUIET_IN_RESET : assert property (@(posedge clk)
      !rst_n |-> !valid_out[r])
      else $error("[SVA] router %0d Eject-out: valid_out asserted during reset", r);

    // Handshake covers (also serve as sanity that traffic really flowed at
    // every router — a mesh-specific value the single-router bench cannot
    // have: these prove every router both injected and ejected).
    C_IN_HANDSHAKE  : cover property (@(posedge clk) disable iff (!rst_n)
      valid_in[r] && ready_in[r]);
    C_OUT_HANDSHAKE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && ready_out[r]);

    // The two backpressure covers are deliberately the exact ANTECEDENTS of
    // A_OUT_VALID_STABLE and A_IN_VALID_STABLE. An implication whose
    // antecedent never holds passes vacuously and proves nothing, so these
    // are the standing evidence that those two assertions are actually
    // being evaluated rather than silently skipped. If either reads zero,
    // the corresponding assertion is dead weight in that run — treat it as
    // a stimulus gap, not as a pass. (C_IN_BACKPRESSURE is an addition over
    // the single-router bench's property set, which covers only the output
    // side and therefore has no such evidence for its A_IN_VALID_STABLE.)
    C_OUT_BACKPRESSURE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && !ready_out[r]);
    C_IN_BACKPRESSURE  : cover property (@(posedge clk) disable iff (!rst_n)
      valid_in[r] && !ready_in[r]);

  end

endmodule : floonoc_mesh_router_sva

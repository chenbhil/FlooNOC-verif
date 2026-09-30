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
// VACUITY OF A_IN_VALID_STABLE DEPENDS ON THE TEST. Its antecedent is
// `valid_in && !ready_in`, i.e. the DUT backpressuring the TB, witnessed by
// C_IN_BACKPRESSURE below.
//  - Smoke test (2x2, 30 flits): VACUOUS, C_IN_BACKPRESSURE reads 0. The mesh
//    holds NumRouters * NumPorts * (InFifoDepth + OutFifoDepth) = 80 flit
//    slots and the smoke stimulus is serial (one flit outstanding at a time),
//    so no Eject input FIFO can fill. Confirmed by experiment: with every
//    Eject output ready forced to 0, all flits were still accepted with
//    C_IN_BACKPRESSURE at 0.
//  - Hotspot test with +hs_fill (floonoc_mesh_hotspot_test): LIVE. Each
//    source sends enough flits to fill every buffer on its path to a stalled
//    target, so backpressure reaches the source's own Eject input and
//    C_IN_BACKPRESSURE is non-zero at every source router (measured, see
//    docs/compatibility.md). This is what makes the assertion do real work.
//
// C_IN_BACKPRESSURE is what keeps the vacuity VISIBLE per run instead of
// letting the assertion sit silently vacuous; do not delete the cover to make
// the assertion-coverage percentage look better.
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

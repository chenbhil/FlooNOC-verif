// -----------------------------------------------------------------------------
// Interface-level protocol assertions for the floo_router smoke bench.
//
// Every property is traceable to an upstream contract:
//  - A_IN_VALID_STABLE / A_OUT_VALID_STABLE mirror the DUT's own
//    StableValidIn/StableValidOut assertions (hw/floo_router.sv, lines
//    494-512 @ v0.8.4): once valid is asserted it must remain asserted
//    until the transfer completes (VcNaive configuration).
//  - A_OUT_QUIET_IN_RESET: all output/input buffering resets empty
//    (common_cells stream_fifo/fifo_v3 reset behavior), so no output
//    valid may be asserted while reset is active. See docs/assumptions.md A3.
//
// Deliberately NOT asserted (see docs/verification_plan.md deferred ideas):
//  - Output DATA stability under stall: upstream keeps its equivalent
//    StableDataIn assertion commented out, and the output arbiter may
//    switch payloads between competing inputs while valid is high.
// -----------------------------------------------------------------------------
module floonoc_router_sva
  import floo_tb_types_pkg::*;
(
  input logic                 clk,
  input logic                 rst_n,
  input logic [NumPorts-1:0]  valid_in,
  input logic [NumPorts-1:0]  ready_in,
  input logic [NumPorts-1:0]  valid_out,
  input logic [NumPorts-1:0]  ready_out
);

  for (genvar p = 0; p < NumPorts; p++) begin : gen_port_sva

    // TB-side obligation: our driver must hold valid until the DUT accepts.
    A_IN_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_in[p] && !ready_in[p] |=> valid_in[p])
      else $error("[SVA] input port %0d: valid_in dropped before handshake", p);

    // DUT-side guarantee: output valid held until we accept.
    A_OUT_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_out[p] && !ready_out[p] |=> valid_out[p])
      else $error("[SVA] output port %0d: valid_out dropped before handshake", p);

    // DUT-side guarantee: outputs quiescent while in reset.
    A_OUT_QUIET_IN_RESET : assert property (@(posedge clk)
      !rst_n |-> !valid_out[p])
      else $error("[SVA] output port %0d: valid_out asserted during reset", p);

    // Handshake covers (also serve as sanity that traffic really flowed)
    C_IN_HANDSHAKE  : cover property (@(posedge clk) disable iff (!rst_n)
      valid_in[p] && ready_in[p]);
    C_OUT_HANDSHAKE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[p] && ready_out[p]);
    C_OUT_BACKPRESSURE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[p] && !ready_out[p]);

  end

endmodule : floonoc_router_sva

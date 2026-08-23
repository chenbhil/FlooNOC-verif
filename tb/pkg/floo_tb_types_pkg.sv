// -----------------------------------------------------------------------------
// Shared (non-UVM) types for the FlooNoC router smoke-test bench.
// Builds the concrete flit/header/ID types from FlooNoC's own typedef macros
// so the TB and the DUT agree on the wire format by construction.
// -----------------------------------------------------------------------------
`include "floo_noc/typedef.svh"
`include "dut_config.svh"

package floo_tb_types_pkg;

  import floo_pkg::*;

  localparam int unsigned NumPorts     = `FLOO_VERIF_NUM_PORTS;
  localparam int unsigned FlitDataW    = `FLOO_VERIF_FLIT_DATA_W;
  localparam int unsigned RouterX      = `FLOO_VERIF_ROUTER_X;
  localparam int unsigned RouterY      = `FLOO_VERIF_ROUTER_Y;
  localparam int unsigned InFifoDepth  = `FLOO_VERIF_IN_FIFO_DEPTH;
  localparam int unsigned OutFifoDepth = `FLOO_VERIF_OUT_FIFO_DEPTH;

  typedef logic [`FLOO_VERIF_X_BITS-1:0]       x_bits_t;
  typedef logic [`FLOO_VERIF_Y_BITS-1:0]       y_bits_t;
  typedef logic [`FLOO_VERIF_PORT_ID_BITS-1:0] port_id_t;
  typedef logic [FlitDataW-1:0]                payload_t;

  // Concrete DUT types from FlooNoC's own macros (hw/include/floo_noc/typedef.svh)
  `FLOO_TYPEDEF_XY_NODE_ID_T(xy_id_t, x_bits_t, y_bits_t, port_id_t)
  `FLOO_TYPEDEF_HDR_T(hdr_t, xy_id_t, xy_id_t, logic, logic)
  `FLOO_TYPEDEF_GENERIC_FLIT_T(req, hdr_t, payload_t)

  typedef floo_req_generic_flit_t flit_t;

  // Reference model of the DUT's XY routing rule.
  // Source: hw/floo_route_select.sv (gen_xy_routing, lines 131-155 @ v0.8.4)
  // and the direction enum in hw/floo_pkg.sv (North=0, East=1, South=2,
  // West=3, Eject=4). X is resolved first, then Y, then eject.
  function automatic route_direction_e exp_out_port(xy_id_t dst);
    if (32'(dst.x) == RouterX && 32'(dst.y) == RouterY) begin
      return Eject; // port_id is constrained to 0 => Eject + 0
    end else if (32'(dst.x) != RouterX) begin
      return (32'(dst.x) < RouterX) ? West : East;
    end else begin
      return (32'(dst.y) < RouterY) ? South : North;
    end
  endfunction

  function automatic string dir_name(int unsigned p);
    case (p)
      32'(North): return "North";
      32'(East):  return "East";
      32'(South): return "South";
      32'(West):  return "West";
      32'(Eject): return "Eject";
      default:    return $sformatf("port%0d", p);
    endcase
  endfunction

endpackage : floo_tb_types_pkg

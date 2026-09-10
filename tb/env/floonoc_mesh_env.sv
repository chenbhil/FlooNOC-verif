// -----------------------------------------------------------------------------
// Mesh environment: one active agent, scoreboard, coverage collector.
//
// Note which port feeds the scoreboard's expectation side: the DRIVER's
// sent_ap (the original sequence item, cloned, published once the input
// handshake completed), NOT the monitor's in_ap. Keying expectations off the
// input wire would make a driver-side encoding bug self-certifying — the
// wrong header would be decoded back into the same wrong expectation, the
// DUT would faithfully route there, and the scoreboard would score a match.
// See the plan's amendment A8 and the comment on floonoc_mesh_driver::sent_ap.
//
// mon.in_ap is deliberately left unsubscribed here. It is not dead: the
// monitor already checks the input-side hdr.src_id encoding against the
// physical injection port itself, and in_ap exists for protocol and
// backpressure observation by any later subscriber.
// -----------------------------------------------------------------------------
class floonoc_mesh_env extends uvm_env;

  `uvm_component_utils(floonoc_mesh_env)

  floonoc_mesh_agent      agent;
  floonoc_mesh_scoreboard sb;
  floonoc_mesh_cov        cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = floonoc_mesh_agent::type_id::create("agent", this);
    sb    = floonoc_mesh_scoreboard::type_id::create("sb", this);
    cov   = floonoc_mesh_cov::type_id::create("cov", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.drv.sent_ap.connect(sb.in_imp);
    agent.mon.out_ap.connect(sb.out_imp);
    agent.mon.out_ap.connect(cov.analysis_export);
  endfunction

endclass : floonoc_mesh_env

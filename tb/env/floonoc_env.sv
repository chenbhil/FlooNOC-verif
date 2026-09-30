// -----------------------------------------------------------------------------
// Environment: one active agent, scoreboard, coverage collector.
//
// The scoreboard's expectation side is fed by the DRIVER's sent_ap (the
// original sequence item, cloned, published once the input handshake
// completed), NOT the monitor's in_ap. Keying expectations off the input
// wire would make a driver-side encoding bug self-certifying — see
// floonoc_driver::sent_ap and docs/verification_plan.md N4.
//
// mon.in_ap is deliberately left unsubscribed. It is not dead: the monitor
// checks the input-side hdr.src_id encoding against the physical input port
// itself, and in_ap stays available for any later subscriber.
// -----------------------------------------------------------------------------
class floonoc_env extends uvm_env;

  `uvm_component_utils(floonoc_env)

  floonoc_agent      agent;
  floonoc_scoreboard sb;
  floonoc_cov        cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = floonoc_agent::type_id::create("agent", this);
    sb    = floonoc_scoreboard::type_id::create("sb", this);
    cov   = floonoc_cov::type_id::create("cov", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.drv.sent_ap.connect(sb.in_imp);
    agent.mon.out_ap.connect(sb.out_imp);
    agent.mon.out_ap.connect(cov.analysis_export);
  endfunction

endclass : floonoc_env

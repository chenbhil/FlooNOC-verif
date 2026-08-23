// -----------------------------------------------------------------------------
// Environment: one active agent, scoreboard, coverage collector.
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
    agent.mon.in_ap.connect(sb.in_imp);
    agent.mon.out_ap.connect(sb.out_imp);
    agent.mon.out_ap.connect(cov.analysis_export);
  endfunction

endclass : floonoc_env

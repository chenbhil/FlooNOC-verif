# UVM Methodology Coverage

The [verification plan](verification_plan.md) is organized around the *DUT
requirements* (what `floo_router` must do). This document is the orthogonal
**methodology** view: which UVM (IEEE 1800.2) constructs this bench actually
exercises, and where. Every row points at real source you can open.

Standards column names the relevant UVM area (base-class group / facility)
rather than clause numbers — deliberately, to avoid citing a clause we have
not verified against the standard text.

## Component hierarchy & factory

| Construct | Exercised in | Role in this bench | UVM area |
|---|---|---|---|
| `uvm_test` | `tb/tests/floonoc_smoke_test.sv:6`; negative tests `tb/tests/floonoc_negative_tests.sv` | top-level test; builds env, runs sequence under objection, reports | Component classes |
| `uvm_env` | `tb/env/floonoc_env.sv:4` | container for agent, scoreboard, coverage | Component classes |
| `uvm_agent` | `tb/agents/floonoc_agent.sv:7` | groups sequencer + driver + monitor | Component classes |
| `uvm_driver #(T)` | `tb/agents/floonoc_driver.sv:14` | pulls items, drives flits onto the vif | Component classes |
| `uvm_monitor` | `tb/agents/floonoc_monitor.sv:6` | samples handshakes, publishes observed flits | Component classes |
| `uvm_scoreboard` | `tb/env/floonoc_scoreboard.sv:15` | routing / integrity / loss / ordering checks | Component classes |
| `uvm_subscriber #(T)` | `tb/coverage/floonoc_cov.sv:12` | covergroup sampling off the delivered-flit stream | Component classes |
| `uvm_sequencer #(T)` | `tb/agents/floonoc_agent.sv:5` (typedef) | arbitrates sequence items to the driver | Sequences |
| `` `uvm_component_utils `` | every component (e.g. `floonoc_env.sv:6`, `floonoc_driver.sv:16`) | factory registration of components | Factory / macros |
| `` `uvm_object_utils `` | `floonoc_flit_item.sv:24`, `floonoc_smoke_seq.sv:8` | factory registration of objects | Factory / macros |
| `run_test()` | `tb/top/tb_top.sv:101` | factory-driven test entry from the HDL top | Factory / phasing |

## Stimulus (sequences)

| Construct | Exercised in | Role in this bench | UVM area |
|---|---|---|---|
| `uvm_sequence_item` | `tb/sequences/floonoc_flit_item.sv:12` | randomizable flit (src/dst/payload) with constraints | Sequences |
| `uvm_sequence #(T)` | `tb/sequences/floonoc_smoke_seq.sv:6` | 10 directed + 15 constrained-random flits | Sequences |
| `start_item` / `finish_item` | `floonoc_smoke_seq.sv:43-59` | sequence-side of the sequencer/driver handshake | Sequences |
| `seq_item_port.get_next_item` / `item_done` | `floonoc_driver.sv:56,58` | driver-side of the same handshake | Sequences |
| `seq_item_port.connect(seq_item_export)` | `tb/agents/floonoc_agent.sv:28` | wires driver to sequencer in `connect_phase` | Sequences / TLM |

## Analysis / TLM

| Construct | Exercised in | Role in this bench | UVM area |
|---|---|---|---|
| `uvm_analysis_port #(T)` | `tb/agents/floonoc_monitor.sv:12-13` (`in_ap`, `out_ap`) | monitor broadcasts accepted + delivered flits | TLM analysis |
| `` `uvm_analysis_imp_decl(_in/_out) `` | `tb/env/floonoc_scoreboard.sv:12-13` | two distinct analysis exports into one scoreboard | TLM analysis |
| analysis `connect` (monitor → sb, monitor → cov) | `tb/env/floonoc_env.sv` (connect_phase) | fans the monitor streams to scoreboard and coverage | TLM analysis |

## Configuration & phasing

| Construct | Exercised in | Role in this bench | UVM area |
|---|---|---|---|
| `uvm_config_db#(virtual if)::set/get` | set `tb/top/tb_top.sv:100`; get `floonoc_driver.sv:30`, `floonoc_monitor.sv:27` | publishes the virtual interface to the components | Config / resource DB |
| `uvm_config_db#(int)::set/get` (knobs) | `floonoc_driver.sv:35` (`ready_pct`), `floonoc_scoreboard.sv:44-45`, negative tests `floonoc_negative_tests.sv:20,38,58` | backpressure % + fault-injection indices for negative tests | Config / resource DB |
| standard phases (`build`/`connect`/`run`/`check`/`report`) | all components | canonical UVM phase flow | Phasing |
| `raise_objection` / `drop_objection` | `tb/tests/floonoc_smoke_test.sv:32,72` | keeps `run_phase` alive while the sequence + drain complete | Phasing / objections |

## Reporting

| Construct | Exercised in | Role in this bench | UVM area |
|---|---|---|---|
| `` `uvm_info / `uvm_error / `uvm_fatal `` | throughout (tests, scoreboard, driver, monitor) | structured messaging; errors gate pass/fail | Reporting |
| `uvm_report_server::get_server()` | `tb/tests/floonoc_smoke_test.sv:76` | reads final `UVM_ERROR` count for the result banner | Reporting |

## Not exercised at this milestone

Intentionally out of scope for a smoke bench (candidates for later milestones,
see [verification_plan.md](verification_plan.md) "Next-milestone candidates"):
RAL / register model, virtual sequences & virtual sequencers, callbacks,
heartbeat, `uvm_event`/`uvm_barrier` synchronization, phase jumping / custom
phases, and factory type/instance overrides (registration is exercised;
override-based substitution is not).

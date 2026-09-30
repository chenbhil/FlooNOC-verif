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
| `uvm_analysis_port #(T)` | `tb/agents/floonoc_monitor.sv` (`in_ap`, `out_ap`); `tb/agents/floonoc_driver.sv` (`sent_ap`) | monitor broadcasts accepted + delivered flits; driver publishes a clone of each item's intent once accepted | TLM analysis |
| `` `uvm_analysis_imp_decl(_in/_out) `` | `tb/env/floonoc_scoreboard.sv:12-13` | two distinct analysis exports into one scoreboard | TLM analysis |
| analysis `connect` (driver → sb, monitor → sb, monitor → cov) | `tb/env/floonoc_env.sv` (connect_phase) | expectations from the driver's `sent_ap`, observations from the monitor's `out_ap` | TLM analysis |
| `clone()` / hand-written `do_copy` / `do_compare` | `tb/sequences/floonoc_flit_item.sv` | field macros avoided (Verilator width warnings); without `do_copy`, `clone()` would copy nothing | Objects |

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

## Mesh bench functional coverage

`tb/coverage/floonoc_mesh_cov.sv`, a `uvm_subscriber #(floonoc_mesh_flit_item)`
on the mesh monitor's **output** analysis port, so every sample is a flit the
DUT actually delivered.

| Coverpoint | Samples | Bins | Derived from |
|---|---|---|---|
| `cp_src_router` | `t.src_router`, decoded from `hdr.src_id` | one bin per router | `NumRouters` |
| `cp_dst_router` | `t.out_router`, the physical Eject port it surfaced on | one bin per router | `NumRouters` |
| `cp_hops` | `t.exp_hops()` | `[1:MeshDiameter]` | `MeshDiameter = MeshX+MeshY-2` |
| `cp_backpressure` | `t.backpressured` | `stalled` / `free` | — |
| `x_src_dst` | cross of `cp_src_router` x `cp_dst_router` | `NumRouters^2` | see the ceiling note below |

No bin range is hardcoded: a larger mesh in `config/dut_config_mesh.svh`
rescales all of them with no edit here.

`cp_dst_router` deliberately samples the **observed** exit router rather than
the predicted destination, so coverage records what the DUT did, not what the
model expected. A misroute therefore shows up in coverage as well as in the
scoreboard.

### Read `x_src_dst` against a 75% ceiling, not 100%

`c_legal_route` forbids `src_router == dst_router`, so `NumRouters` of the
`NumRouters^2` cross bins are structurally unreachable — 4 of 16 on a 2x2
mesh, capping the cross at `(N^2-N)/N^2` = **75%**.

That would normally be expressed as
`ignore_bins loopback = x_src_dst with (cp_src_router == cp_dst_router);`,
but **Verilator 5.052 cannot parse a `with` clause on a cross**:

```
%Error: tb/coverage/floonoc_mesh_cov.sv:42:40: syntax error, unexpected
        with-then-(, expecting '('
```

The alternative — hand-enumerating `binsof`/`intersect` per router — would
hardcode the mesh size, which is exactly the genericity the file is built to
keep. So the unreachable bins are left in and documented here instead. The
covergroup carries the same note at the point of use.

Measured on the 30-flit smoke run (15 directed + 15 random), `make cov-mesh`:

| Item | Result |
|---|---|
| `flit_cg` overall | **85.7% (24/28)** |
| `cp_src_router` | 100% (4/4) |
| `cp_dst_router` | 100% (4/4) |
| `cp_hops` | 100% (2/2) |
| `cp_backpressure` | 100% (2/2) |
| `x_src_dst` | **75% (12/16)** — at the ceiling |
| `link_cg` (`floonoc_mesh_link_cov`) | **100% (8/8 links)**, 40 observed hops |
| aggregate functional (`make cov-mesh`) | **88.9% (32/36)** |

The four unhit cross bins are exactly `r[0]_x_r[0]`, `r[1]_x_r[1]`,
`r[2]_x_r[2]` and `r[3]_x_r[3]`: the `src == dst` diagonal. All 12 legal
pairs are hit. There is no stimulus gap behind the 85.7% — it is 24 of 28
with 4 bins unreachable by construction, and 24 of 24 reachable bins hit.

### Link coverage

`floonoc_mesh_link_cov` subscribes to `floonoc_mesh_link_monitor::hop_ap` and
has one bin per directed router-to-router link that exists. The bins run over
`link_index()`, a dense numbering of the `(router, direction)` pairs for
which `has_neighbor()` holds (`NumLinks`, 8 on 2x2). Boundary directions
therefore have no bin at all, and nothing is hardcoded to 2x2. This is the
workaround for Verilator 5.052 not parsing `with` on bins. The directed phase
crosses every link in both directions, so the smoke run reads 100%.

New mesh components for the per-hop path check (RM8):
`floonoc_mesh_link_if` (read-only interface), `floonoc_mesh_link_monitor`
(passive `uvm_monitor`), `floonoc_mesh_hop_item` (`uvm_sequence_item` with a
hand-written `do_copy`), a third `` `uvm_analysis_imp_decl(_mesh_hop) `` export
on the scoreboard, and `floonoc_mesh_link_cov` (`uvm_subscriber`).

## Not exercised at this milestone

Intentionally out of scope for a smoke bench (candidates for later milestones,
see [verification_plan.md](verification_plan.md) "Next-milestone candidates"):
RAL / register model, virtual sequences & virtual sequencers, callbacks,
heartbeat, `uvm_event`/`uvm_barrier` synchronization, phase jumping / custom
phases, and factory type/instance overrides (registration is exercised;
override-based substitution is not).

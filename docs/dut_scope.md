# DUT Scope Selection

## Chosen DUT: `floo_router`

- **Top-level module:** `floo_router`
- **Source path:** `rtl_or_vendor/floonoc/hw/floo_router.sv`
- **FlooNoC revision:** `14c253c996fcdc78b793fe28ac18964769b768df` (tag `v0.8.4`)
- **TB instantiation:** `tb/top/tb_top.sv` (UVM) and `tb/top/lint_wrapper.sv` (lint)

This follows preference #1 of the scoping directive: a router-level DUT wrapped
with a small local interface. `floo_vc_router` was rejected because upstream has
moved it (and all its `vc_router_util` helpers) under the `floo_deprecated_hw`
Bender target at v0.8.4 — building a new environment on deprecated RTL would be
wasted effort. Generated networks and chimneys were not needed: `floo_router`
is fully instantiable standalone (upstream's own `hw/tb/tb_floo_router.sv`
demonstrates this).

## Why it is the minimum meaningful DUT

- Externally visible, spec-checkable behavior: XY routing decision, payload
  transport, valid/ready handshake, backpressure, per-pair ordering.
- No AXI, iDMA, FPnew or atomics dependencies at this parameterization —
  dependency closure is `common_cells` + one self-contained package file
  (`axi_pkg.sv`, needed only because `floo_pkg` defines width-helper
  functions that reference it).
- Smaller candidates (`floo_route_select`, `floo_wormhole_arbiter`) exist but
  verify only one function each; the router is the smallest block whose
  behavior maps onto real NoC requirements (routing/ordering/no-loss).

## Selected parameterization (see `config/dut_config.svh`)

| Parameter | Value | Rationale |
|---|---|---|
| `NumRoutes` | 5 | Canonical 2D-mesh router: North/East/South/West/Eject (`floo_pkg::route_direction_e`) |
| `NumVirtChannels` | 1 | Simplest legal config; `floo_vc_arbiter` becomes a passthrough (`gen_virt_eq_phys`), keeping handshake semantics clean |
| `NumPhysChannels` | 1 | Must equal VCs for passthrough; only 1 and `==VCs` are implemented upstream |
| `RouteAlgo` | `XYRouting` | The routing rule is fully documented in-source (`floo_route_select.sv` lines 131–155), giving the scoreboard a citable reference model. `SourceRouting` mutates the header in flight; `IdTable` needs a route map we would have to invent |
| `IdWidth`/`id_t` | 5 / `xy_id_t {x[1:0], y[1:0], port_id[0]}` | 2-bit coordinates suffice for one router at (1,1) with neighbors on all sides |
| `xy_id_i` | (x=1, y=1, port 0) | Interior position: all four directions plus eject are reachable |
| `InFifoDepth` | 2 | Input buffering required for wormhole operation; upstream TB uses 4, 2 is the minimum useful depth |
| `OutFifoDepth` | 2 | Decouples output valid from arbiter internals |
| `flit_t` | `FLOO_TYPEDEF_GENERIC_FLIT_T(req, hdr_t, logic[63:0])` | Generic flit exactly as upstream's own router TB builds it; payload opaque to the DUT |
| `XYRouteOpt` | 1 (default) | Kept at default; consequences encoded as stimulus constraints (see below) |
| `NoLoopback` | 1 (default) | Kept at default; loopback destinations excluded from stimulus |
| `CollectiveCfg`/`RedCfg`/`AxiCfg*` | all-disabled defaults | Collectives/reductions are out of scope; disabling removes the FPnew/AXI datapath entirely |

## Clock / reset

- `clk_i`: single clock, TB drives 100 MHz.
- `rst_ni`: async active-low; TB asserts for 5 cycles. All internal state
  (common_cells `fifo_v3`, `` `FF `` registers) resets to empty/0.
- `test_enable_i`: DFT enable, tied 0.

## Interfaces

Per input port `i`, per VC `v` (here v=0):
`valid_i[i][v]`, `ready_o[i][v]`, `data_i[i][phys]` (flit), `credit_o[i][v]`
— and mirrored `valid_o/ready_i/data_o/credit_i` on outputs. Credits are
inert in the default `VcNaive` implementation (`credit_o` constant 1,
`credit_i` ignored) and are tied off in the TB. `xy_id_i` is the router's
own coordinate; `id_route_map_i` is IdTable-only and tied 0.
`offload_req_o`/`offload_rsp_i` (reduction offload) are tied off — the
reduction unit is not even elaborated with collectives disabled.

Relevant packages/structs: `floo_pkg` (enums, cfg structs),
`hw/include/floo_noc/typedef.svh` (flit/header/ID struct macros — the TB
uses these same macros in `tb/pkg/floo_tb_types_pkg.sv`).

## Legal traffic (drives the stimulus constraints)

Two default optimizations tie off crossbar connections; driving them would
deadlock the flit and fire the DUT's own assertions
(`XYDirectionNotAllowed`, `NoLoopback`, `floo_router.sv` lines 344–363,
514–544):

- `XYRouteOpt`: no South/North input may route East/West (X must already be
  resolved for traffic arriving on Y ports).
- `NoLoopback`: no input may route back to its own port index.

Hence the constraints in `floonoc_flit_item::c_legal_route` (router at (1,1)):
from North: `dst = (1, y<=1)`; from East: `dst.x <= 1`; from South:
`dst = (1, y>=1)`; from West: `dst.x >= 1`; from Eject: `dst != (1,1)`.

## Required FlooNoC dependencies

| Dependency | Used for | Pinned by |
|---|---|---|
| `common_cells` 1.39.0 | `stream_fifo_optimal_wrap`, `rr_arb_tree`, `cf_math_pkg`, `registers.svh`, `assertions.svh`, etc. | upstream `Bender.lock` |
| `axi` 0.39.7 — **only `src/axi_pkg.sv`** | width-helper functions referenced by `floo_pkg` | upstream `Bender.lock` |

All other Bender dependencies (iDMA, FPnew/cvfpu, axi_riscv_atomics,
common_verification, tech_cells_generic, ...) are fetched by `bender
checkout` (lock-pinned) but **not compiled**.

## Intentionally excluded upstream files

- `hw/tb/*`, `hw/test/*` — commercial-simulator TBs and VIP (`floo_test` target)
- `hw/floo_axi_chimney.sv`, `hw/floo_nw_chimney.sv`, `hw/floo_nw_join.sv`,
  `hw/floo_axi_router.sv`, `hw/floo_nw_router.sv` — AXI-facing wrappers, pull the full AXI/iDMA stack
- `hw/floo_rob*.sv`, `hw/floo_meta_buffer.sv`, `hw/floo_id_translation.sv`, `hw/floo_cdc.sv`, `hw/floo_cut.sv`, `hw/floo_fifo.sv`, `hw/floo_reduction_*.sv`, `hw/floo_alu.sv` — not in the router's elaboration closure at this config (`floo_reduction_arbiter` additionally references `axi_pkg` response types)
- `hw/synth/*`, `hw/deprecated/*`, `generated/*`, `floogen` outputs

The exact compile set is `config/filelists/floo_dut_files.txt` (7 FlooNoC
files) + all of `common_cells` (bender order) + `axi_pkg.sv`; materialized
by `make sources` into `build/sources.f`.

## Known/uncertain language constructs (pre-compilation assessment)

| Construct | Location | Status after build |
|---|---|---|
| `assert property` + `$stable`/`|=>` | `floo_router.sv`, TB SVA | compiles and executes (`--assert`) |
| unpacked struct params (`axi_cfg_t`, `collect_op_be_cfg_t`) | `floo_pkg` | OK |
| `(* ungroup *)` attribute | `floo_router.sv` | accepted (ignored) |
| 1-bit vs 4-bit enum compare in `NoLoopback` assert | `floo_router.sv:541` | WIDTHEXPAND warning, waived with justification |
| UVM class library, config_db, phasing, TLM | UVM 1800.2-2017 1.0 | works with `+define+UVM_NO_DPI` |
| class-member coverpoints | TB coverage | **unsupported (COVERIGN)** — worked around with `with function sample(...)` |

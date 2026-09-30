# Local Assumptions

Every scoreboard/assertion behavior that is not directly citable from
FlooNoC documentation or source comments is recorded here. Each entry
states the assumption, why we believe it, and what would invalidate it.

## A1 — Handshake semantics are AXI-style valid/ready

**Assumption:** A flit transfers on a rising clock edge where
`valid && ready`; valid may not be retracted before the transfer; data
must be held stable while valid is high and ready is low (on the input
side, as an obligation on our driver).

**Basis:** The DUT asserts `StableValidIn`/`StableValidOut`
(`hw/floo_router.sv:494-512`) for the `VcNaive` configuration, and the
FlooNoC paper/README describe the links as decoupled ready/valid
channels. Data stability is *our driver's* discipline; the DUT's
equivalent input-data assertion exists upstream but is commented out.

**Invalidated if:** a VC implementation with preemption (`VcPreemptValid`)
is selected — valid may then be retracted (upstream guards its
assertions accordingly).

## A2 — Single-flit packets (`hdr.last = 1`) are legal and self-contained

**Assumption:** Every injected flit carries `hdr.last = 1`, forming a
1-flit packet; the wormhole route lock (`floo_route_select.sv`,
`LockRouting`, lines 200–228) therefore opens and closes per flit and
never couples consecutive transactions.

**Basis:** `LockRouting` locks the selected route "until the `last` flag
is received" (source comment, line 17–19). With `last` always 1, the
lock never persists across flits. Upstream's router TB also terminates
every packet with `last`.

**Invalidated if:** multi-flit packets are introduced — then per-packet
(not per-flit) ordering and route locking must be modeled.

## A3 — Outputs are quiescent during reset

**Assumption:** `valid_o == 0` whenever `rst_ni == 0` (assertion
`A_OUT_QUIET_IN_RESET`).

**Basis:** All storage in the output path (common_cells
`stream_fifo_optimal_wrap`/`fifo_v3`, spill registers, `` `FF ``
registers) resets to empty/zero; the wormhole/VC arbiters derive valid
combinationally from FIFO fill state. There is no explicit upstream
reset-behavior statement, so this is a local (low-risk) inference.

**Invalidated if:** upstream ever registers `valid_o` with a non-zero
reset value.

## A4 — Ordering guarantee is per (input port -> output port) pair only

**Assumption:** Flits accepted on input `i` destined to output `o` are
delivered at `o` in acceptance order. No ordering is assumed between
flits from different inputs, even to the same output.

**Basis:** The per-input path is a FIFO (`stream_fifo_optimal_wrap`)
followed by a fixed route computation; there is no reordering resource
between one input and one output in this configuration (1 VC, 1 phys
channel). Cross-input order depends on `rr_arb_tree` arbitration, which
upstream does not document as fair-ordered — so we deliberately do not
check it.

**Invalidated if:** multiple VCs/physical channels are enabled (per-pair
traffic could then interleave across channels).

## A5 — `hdr.src_id` is opaque payload at router scope

**Assumption:** The TB encodes the physical input-port index into
`hdr.src_id` and trusts it when matching output flits back to their
source.

**Basis:** At this parameterization the router's routing logic reads only
`hdr.dst_id` (and `hdr.last`, `hdr.collective_op == Unicast = 0`);
`src_id` is used upstream only by reduction/multicast features, which
are disabled. Verified by reading `floo_route_select.sv` and the
crossbar logic in `floo_router.sv`.

**Checked on the input side:** the input monitor verifies on every input
handshake that `hdr.src_id` decodes to the physical input port it arrived
on (`MON` error otherwise). An encode bug in the driver therefore surfaces
at the input, not as a confusing "unexpected flit" downstream. The
scoreboard's expectations come from the driver's intent (`sent_ap`), not
from this decode; see verification_plan.md N4.

**Invalidated if:** collective operations are enabled.

## A6 — Illegal-destination behavior is out of scope

No check is implemented for flits whose destination would require a
tied-off crossbar connection (Y->X turns, loopback): upstream defines no
externally specified error behavior for them (they simply stall forever
and fire internal assertions). The stimulus constraints exclude them
(see docs/dut_scope.md "Legal traffic"). This mirrors the requirement
that undocumented behavior must not be guessed.

## Mesh-bench assumptions

These apply to `tb_top_mesh` only. The single-router assumptions above are
unchanged by the mesh bench, which shares no code with it.

### A4-M — Per-pair ordering holds across the mesh

The mesh scoreboard's RM6 check assumes that two flits sharing the same
(source router, destination router) pair are delivered in acceptance order.
This is not inherited from A4 (which reasons about one router); it follows
independently from three properties of this configuration:

1. Dimension-order XY routing is deterministic and stateless — the route
   depends only on `hdr.dst_id` and the current router's `xy_id_i`
   (`hw/floo_route_select.sv`, `gen_xy_routing`). Two flits with the same
   destination injected at the same router therefore traverse the identical
   sequence of routers and ports.
2. At every stage between them the storage is FIFO: the per-input
   `stream_fifo` (`InFifoDepth`) and the per-output fifo (`OutFifoDepth`).
3. `hdr.last == 1` on every flit, so the wormhole route lock opens and
   closes per flit and cannot interleave a packet.

Nothing on that path can reorder two same-pair flits relative to each other.
Cross-pair ordering is deliberately NOT assumed, exactly as in A4.

**Invalidated if:** routing becomes adaptive or source-routed, a stage
between two same-pair flits stops being FIFO, or multi-flit packets are
introduced (`hdr.last == 0`).

### A5-M — `hdr.src_id` survives every hop

The mesh transaction encodes its injection router in `hdr.src_id` so the
output-side monitor can recover it — the monitor sees only `rif.data_out[r]`,
and the scoreboard keys its expectation FIFOs on (src router, dst router).

**Basis:** `hw/floo_route_select.sv:96` rewrites `hdr.dst_id` only under
`SourceRouting`; under `XYRouting` the header passes through every hop
unmodified (`:190`, `channel_o = channel_i`). `hdr.src_id` is read only by
`floo_route_xymask.sv`, the multicast path, which is inert in this
configuration (`collective_op == Unicast`, `EnCollective` off). Confirmed in
practice by the first end-to-end run: all 12 directed flits, including the
2-hop diagonals, were matched on a key that includes the decoded `src_id`,
which cannot happen if the field is rewritten in flight.

**Invalidated if:** `SourceRouting` or collective operations are enabled.

### A8-M — Cross-source order and fairness are NOT assumed

Nothing in the bench assumes the order in which flits from DIFFERENT sources
leave a shared output, or any fairness bound. Only per-(src, dst) order is
checked (A4-M). The hotspot test's arbitration report (the order at T's Eject
after release, per-source deliveries per window, and the maximum number of
other-source flits that left T while a given source had one inside T) is a
**measurement**, printed in `report_phase`, never a pass/fail criterion. The
upstream spec does not promise fairness. What it shows (see compatibility.md)
is round-robin fair **per input port**, not per flow. Sources merged onto one
input share that port's slot, which is expected and not a bug.

**Invalidated if:** a fairness or starvation bound is added as a check. That
would be a design-intent check needing its own spec basis and its own negative
test.

### A7-M — Inter-router links are observed by hierarchical reference

The per-hop path check (RM8) needs the North/East/South/West handshakes,
which `floonoc_mesh_if` does not expose. `tb_top_mesh` copies them into the
read-only `floonoc_mesh_link_if` through hierarchical references to
`i_mesh.dut_valid_out` / `dut_ready_out` / `dut_data_out`. Those arrays belong
to **our** wrapper `floonoc_mesh_dut`, not to vendor RTL. Nothing is driven
back, and the wrapper's ports are unchanged. `ready` on a link is the
neighbor's input ready, or the tie-off `0` at a boundary.

**Invalidated if:** the wrapper's internal array names or their
`[router][direction][vc]` shape change, or more than one virtual channel is
enabled (the monitor reads VC 0 only).

## Environment-level decisions

- **E1:** Bender is driven inside the pinned FlooNoC checkout
  (`rtl_or_vendor/floonoc`), using upstream's own `Bender.yml` +
  `Bender.lock` as the manifest of record; the workspace adds a
  file-selection layer (`config/filelists/` + `scripts/bender_sources.sh`)
  instead of a second manifest. This avoids duplicate dependency
  checkouts and keeps revisions bit-identical to upstream CI.
- **E2:** UVM library is the unmodified Accellera 1800.2-2017 1.0 kit
  (`UVM_HOME`), compiled with `+define+UVM_NO_DPI`. DPI-dependent UVM
  features (regex config matching, component name checks, HDL backdoor)
  are accepted as degraded; the name-check emits benign
  `UVM/COMP/NAME` warnings at startup (see docs/known_issues.md KI-2).

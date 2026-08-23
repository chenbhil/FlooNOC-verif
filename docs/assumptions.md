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

**Invalidated if:** collective operations are enabled.

## A6 — Illegal-destination behavior is out of scope

No check is implemented for flits whose destination would require a
tied-off crossbar connection (Y->X turns, loopback): upstream defines no
externally specified error behavior for them (they simply stall forever
and fire internal assertions). The stimulus constraints exclude them
(see docs/dut_scope.md "Legal traffic"). This mirrors the requirement
that undocumented behavior must not be guessed.

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

# [DRAFT — GitHub issue for verilator/verilator]

## Title

Intermittent crash (heap corruption / `FST_CHECK failed: enc == EncodingType::BINARY`) in new fstcpp FST writer at 5.050

## Labels

`bug`, `area: tracing`

---

## Describe the bug

With `--trace-fst`, a simulation binary built by Verilator 5.050 crashes
intermittently (roughly 10–25 % of runs on our design) with one of two
symptoms, while the identical invocation succeeds on the other runs and
produces a complete, byte-identical FST file:

1. `SIGTRAP` (exit 133) with **no output from the FST writer** and an empty
   `.fst` file. An `lldb` backtrace shows macOS `libsystem_malloc` trapping on
   an internal heap-integrity check (`mfm_alloc + 524`,
   `EXC_BREAKPOINT`) during an **unrelated allocation** (in our case inside a
   UVM `report_header` string-queue copy at time 0), i.e. the heap has
   already been corrupted by that point:

   ```
   * frame #0: libsystem_malloc.dylib`mfm_alloc + 524
     frame #1: libc++abi.dylib`operator new(unsigned long) + 52
     frame #2: Vtb_top`std::__1::__allocate_at_least<std::__1::allocator<std::__1::basic_string<...>*>> + 32
     frame #3: Vtb_top`std::__1::deque<std::__1::basic_string<...>>::__add_back_capacity + 176
     ...
     frame #7: Vtb_top`Vtb_top_uvm_pkg__03a__03auvm_root::__VnoInFunc_report_header + 1960
     ...
     frame #10: Vtb_top`Vtb_top___024root___eval_initial__TOP__Vtiming__1 + 248
     frame #12: Vtb_top`Vtb_top::eval_step() + 104
     frame #13: Vtb_top`main + 136
   ```

2. `SIGABRT` (exit 134) with

   ```
   FST_CHECK failed: enc == EncodingType::BINARY
   ```

   and a truncated (~355 byte) `.fst` file. This check is the
   admitted-incomplete path in
   `include/fstcpp/fstcpp_variable_info.h:559`:

   ```c++
   FST_CHECK(enc == EncodingType::BINARY);  // TODO
   ```

In both cases the simulation itself has already run correctly (all
`$display`/UVM output is complete and identical to passing runs); only the
process exit / trace finalization differs. Without `+trace` (i.e. when
`$dumpfile/$dumpvars` are not executed at runtime) the binary exits 0 on
100+ consecutive runs.

## Observations

- Nondeterministic across identical invocations (same binary, same
  plusargs, same seed): ~1–2 failures in 8 runs. This smells like
  address-layout/heap-layout dependence rather than a data race — the
  fstcpp writer appears to be single-threaded.
- Reproduces with a pure-RTL `$dumpvars` scope (no UVM classes in the
  traced hierarchy), 10 % failure rate over 10 runs.
- `--x-initial 0 --x-assign 0` does **not** eliminate it (1/8 failures).
- macOS `MallocScribble=1 MallocPreScribble=1` does not make it more
  deterministic (1/5 failures).
- The two symptoms are plausibly one bug: an out-of-bounds/UAF write in
  the writer's value-change buffering, detected either by libmalloc
  (symptom 1) or by the writer's own encoding check reading back a
  corrupted buffer (symptom 2).
- When the run succeeds, the FST appears complete and is byte-identical
  across runs.

## Environment

- Verilator: `Verilator 5.050 2026-07-01 rev vUNKNOWN-built20260701`
  (Homebrew bottle)
- OS: macOS (Darwin 25.5.0), Apple Silicon (arm64)
- Compiler: Apple clang (Homebrew default toolchain)
- lz4: Homebrew, linked via `-CFLAGS -I$(brew --prefix lz4)/include
  -LDFLAGS "-L$(brew --prefix lz4)/lib -llz4"`
  (aside: `verilated_fst_c.cpp` does not compile out of the box on macOS
  because `<lz4.h>` is not found without these extra flags — possibly
  worth a doc note or configure check)

## Test case

Our reproducer is a UVM testbench around the PULP FlooNoC `floo_router`
(~100 RTL files + UVM 1800.2-2017 1.0, `+define+UVM_NO_DPI`), compiled
with:

```
verilator --binary -j 0 -sv --timing --assert --coverage-user \
  --trace-fst --trace-structs --x-initial 0 --x-assign 0 \
  +define+UVM_NO_DPI ... --top-module tb_top
./obj_dir/Vtb_top +UVM_TESTNAME=... +trace   # crashes ~1 in 8 runs
```

`$dumpfile("waves/tb_top.fst")` + `$dumpvars(0, tb_top)` are called at
time 0 behind `$test$plusargs("trace")`. Repository with full
reproduction steps available on request; we have not yet minimized to a
self-contained snippet because the failure is heap-layout dependent (a
minimal design may not exhibit it).

We attempted an AddressSanitizer build to capture the first corrupting
write (`-CFLAGS "-fsanitize=address -g" -LDFLAGS -fsanitize=address`),
but the ASan-instrumented binary hangs before producing any output on
macOS/arm64 — possibly an interaction between ASan and the `--timing`
coroutine scheduler. An ASan run on Linux/x86_64 is the obvious next
diagnostic step.

<!-- TODO before filing: attempt Linux/x86_64 repro + ASan there;
     attempt minimization once a deterministic trigger is known. -->

## Expected behavior

Traced simulation exits 0 deterministically and writes a complete FST,
as pre-fstcpp Verilator releases did with the same testbench flow.

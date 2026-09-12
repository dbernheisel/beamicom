# Nx APU runtime bottleneck

The main measured bottleneck is **XLA's concurrent task scheduling and dependency
bookkeeping for the scalar APU loop**. A process-local override that changes only
executor scheduling reduces the unchanged Nx workload from **211.205 ms to
80.598 ms** (seven-run medians), a **61.8% reduction / 2.62x speedup**.
Compilation is excluded. The same state remains on EXLA between calls, and PCM
export is included. PCM is byte-identical and final state matches (integers exact,
floats within 1e-12).

This conclusion comes from profiling Nx itself and changing its scheduling. The
separate native-C APU speed comparison is not the evidence used here.

The follow-up [timestamped block renderer](APU_BLOCK_RESULTS.md) now reduces how
often the full APU state is processed, with a measured improvement on the actual
15-second captured audio timeline.

## Runtime samples

Linux blocks perf events (`perf_event_paranoid=4`). Instead, `sample_apu.py`
launches the Nx-only workload as a GDB child and takes 200 all-thread stack
snapshots after compilation and warmup. Running intervals are randomly spaced
8–23 ms apart. No machine security settings are changed.

The default sample contains 165 stacks with `ThunkExecutor` visible in the first
16 frames, across 158 snapshots. Its leaf locations are:

| Location | Executor stacks |
| --- | ---: |
| Dependency scheduling / executor bookkeeping | 83 |
| Thread synchronization / queueing | 36 |
| Generated computation | 14 |
| Buffer copying | 10 |
| Async lifecycle / allocation | 9 |
| Other / unresolved | 8 |
| Kernel dispatch | 5 |

In particular, **56 stacks stop directly in
`ThunkExecutor::ProcessCompletedOutEdges`**. Other stacks show `FifoReadyQueue`
processing, `ExecuteState::Node` construction, Eigen thread-pool scheduling,
condition-variable signals, and futex wakeups. Together the first two categories
account for 119/165 sampled executor stacks.

These are **stack counts, not precise CPU-time percentages**. GDB pauses perturb
scheduling, a snapshot can contain multiple executor stacks, and the 16-frame
filter excludes other host work. The timing intervention below provides stronger
causal evidence than the counts alone. The long profiling workload continues
from one real Castlevania APU state without further register writes; the timing
workload restarts from that seed for each repetition of 64 intervals.

## Scheduling-only intervention

`native/sequential_thunks.cc` interposes `ThunkExecutor::Create` against the exact
bundled XLA headers/library. With `NX_APU_FORCE_SEQUENTIAL` set, it raises both
sequential-execution heuristic thresholds to their maximum. Without that variable,
it forwards the original options unchanged. This changes execution policy, not
APU equations, compiler inputs, tensor shapes, or generated audio functionality.

The installed XLA header documents defaults of 512 bytes for the buffer-size
threshold and eight thunks for the sequence-length threshold. It explicitly warns
that concurrency overhead can dominate small tasks. This APU has many scalar
outputs alongside larger lookup tables and an audio buffer; the runtime samples
confirm that its default execution uses the concurrent dependency executor.
The experiment does not isolate which individual buffer triggers that policy.

| Nx variant | Matched default scheduling | Forced sequential | Reduction |
| --- | ---: | ---: | ---: |
| Scalar state | 211.205 ms | 80.598 ms | 61.8% |
| Packed state | 289.781 ms | 88.945 ms | 69.3% |

Each number is the median of seven measurements of 64 intervals × 29,830 CPU
cycles, about 1.067 seconds of emulated audio. Implementation order rotates after
warmup. The matched control loads the same diagnostic library and crypto library,
but leaves scheduling unchanged. The default control remains consistent with the
earlier 209.694 ms scalar result. Desktop noise and unpinned clocks still apply.
The complete PCM SHA-256 remains
`3364b2f92e1f3b79d2ebd9fc769b2bfbb552fdb488fd0533848afd5e9603dc7b`.

Disabling `xla_cpu_multi_thread_eigen` and
`xla_cpu_enable_concurrency_optimized_scheduler` together did not solve the
problem: scalar median was 252.450 ms, packed median 269.199 ms. Those flags are
not equivalent to bypassing the runtime's concurrent dependency executor.

## Remaining cost

With sequential execution, another 200 snapshots contain 122 executor stacks:

| Location | Executor stacks |
| --- | ---: |
| Generated computation | 44 |
| Kernel dispatch | 36 |
| Sequential executor bookkeeping | 21 |
| Buffer copying | 14 |
| Other / unresolved | 6 |
| Async lifecycle / allocation | 1 |
| Thread synchronization / queueing | 0 |

The remaining time is spread across generated kernels, dispatch, and small state
copies. The profile does not establish a single pulse/noise/filter component as
the main bottleneck. Kernel fusion / fewer separately dispatched state updates
is the next profiling target after eliminating concurrent task overhead.

The override is diagnostic only, explicitly loaded for selected processes. No
production configuration, core code, or EXLA dependency source was changed, and
this is not a full-game performance result.

## Reproduce

Run in this experiment directory with its installed Elixir/OTP on PATH. The
existing ignored `tmp/devices.etf` capture is required (see DEVICE_RESULTS.md).

```sh
mise exec elixir@1.20.2-otp-29 erlang@29.0.3 -- python3 sample_apu.py
python3 summarize_apu_profile.py
python3 build_scheduler_probe.py
```

The benchmark still includes the earlier native-C control; build that library
once with `MIX_ENV=prod mix run build_native.exs`. For the matched Nx timings:

```sh
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  MIX_ENV=prod mix run apu_continuous.exs results/apu_nx_scheduler_control.json
LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libcrypto.so.3:$PWD/tmp/sequential_thunks.so" \
  NX_APU_FORCE_SEQUENTIAL=1 MIX_ENV=prod mix run apu_continuous.exs results/apu_nx_sequential.json
APU_PROFILE_SEQUENTIAL=1 APU_PROFILE_LABEL=_sequential \
  mise exec elixir@1.20.2-otp-29 erlang@29.0.3 -- python3 sample_apu.py
python3 summarize_apu_profile.py tmp/apu_stacks_sequential.json results/apu_nx_sequential_stack_profile.json
```

This preload command is Linux/machine specific. Loading system crypto first
preserves Erlang crypto symbol resolution; preloading the XLA-linked diagnostic
library alone prevented Erlang's crypto NIF from loading. `-DNDEBUG` in the build
script matches EXLA's required C++ ABI. The shared object and raw stack logs are
ignored under `tmp/`; result summaries contain no ROM data.

Artifacts: `results/apu_nx_stack_profile.json`,
`results/apu_nx_sequential_stack_profile.json`,
`results/apu_nx_scheduler_control.json`, `results/apu_nx_sequential.json`, and
`results/apu_nx_scheduler_flags.json`.

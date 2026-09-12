# EXLA / ROCm investigation

Investigated 2026-09-11/12. **EXLA successfully executes GPU arithmetic, PPU rendering and block APU kernels on the Radeon 8060S through AMD's external ROCm PJRT plugin**, using a separately patched EXLA adapter and temporary runtime libraries. No full XLA source build was needed. Bounded NES correctness smoke tests pass; timings below are exploratory, not a full-core benchmark. The initial failed probe and successful follow-up are both documented below.

All probes used fresh Elixir VMs and temporary files under `/tmp/dbern/exla-rocm-pjrt`. No system packages were installed, no existing dependency builds or configuration were modified, and the native Elixir emulator was untouched.

## Local evidence

| Component | Observed |
| --- | --- |
| GPU | Radeon 8060S, `gfx1151`, 40 compute units, wavefront 32 |
| CPU | AMD Ryzen AI MAX+ 395 |
| OS / kernel | Ubuntu 26.04.1 / `7.0.0-31-generic` |
| ROCm | `/opt/rocm` resolves to `/opt/rocm-7.2.4`; `.info/version` is `7.2.4` |
| Runtime | `rocminfo`: HSA runtime 1.18, GPU agent present |
| Device access | `/dev/kfd`, `/dev/dri/renderD128` available outside the tool sandbox |
| Existing packages | Nx / EXLA 0.13.1, XLA 0.10.0; current experiment explicitly uses host CPU |

The sandbox hides GPU device nodes. Its missing `/dev/kfd` is not a machine/driver failure. The read-only unsandboxed `rocminfo` probe succeeded.

AMD identifies the Ryzen AI Max+ 395 as `gfx1151` in its [Ryzen support matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityryz/native_linux/native_linux_compatibility.html). Hardware enumeration alone does not establish that this exact OS/runtime/framework combination is a validated AMD configuration.

## Lower-cost route: external PJRT plugin

Installed EXLA supports `platform: :pjrt_plugin`, with `device_type` and `plugin_path`. This can reuse the existing CPU EXLA build and load a GPU runtime dynamically. See the [EXLA implementation](https://github.com/elixir-nx/nx/blob/main/exla/lib/exla.ex), and locally `deps/exla/lib/exla/client.ex` and `deps/exla/c_src/exla/exla_client.cc`.

Downloaded the official AMD artifact linked by its [ROCm 7.2 JAX instructions](https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-jax.html):

```text
https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/jax_rocm7_pjrt-0.8.0%2Brocm7.2.0-py3-none-manylinux_2_28_x86_64.whl
183707750 bytes
SHA256 d0f11672c50328d13621dd8a33be0b830e28e857998b4b2957bb6d6061daeadf
```

This was extracted as a zip, not installed into Python. The library is:

```text
/tmp/dbern/exla-rocm-pjrt/unpacked/jax_plugins/xla_rocm7/xla_rocm_plugin.so
```

Initial loading failed because the installed ROCm runtime lacks profiler libraries. Downloading and extracting these packages from AMD's `https://repo.radeon.com/rocm/apt/7.2.4/` repository into the temporary directory resolved all reported dynamic-linker dependencies:

- `rocprofiler-sdk_1.1.0-93~24.04_amd64.deb`
- `rocprofiler-sdk-roctx_1.1.0-93~24.04_amd64.deb`
- `rocprofiler-sdk-rocpd_1.1.0-93~24.04_amd64.deb`
- `hsa-amd-aqlprofile_1.0.0.70204-93~24.04_amd64.deb`

The three SDK package downloads were verified against SHA256 values in AMD's package index. The AQL package was retrieved directly from the same HTTPS repository. No package manager installation occurred.

The next probe successfully reported:

```text
XLA service ... initialized for platform ROCM
StreamExecutor device (0): Radeon 8060S Graphics, AMDGPU ISA version: gfx1151
GetPjrtApi was found for ROCM
PJRT_Api is set for device type rocm
```

It then failed inside `EXLA.NIF.get_c_api_client("ROCM")` with `unknown exception thrown within NIF`. The planned `[1, 2, 3] + 1` computation was never reached. This establishes successful plugin loading and GPU discovery, not a functioning EXLA GPU backend.

### Allocator issue discovered

The plugin logged a 99,857,989,632-byte BFC allocator allocation and a 33,285,996,544-byte collective allocator limit. These are reported allocator requests/limits, not measurements of physical pages committed. The VM exited immediately after the exception.

EXLA's generic PJRT path calls `xla::GetCApiClient(device_type)` without options. Its `memory_fraction` and `preallocate` settings are forwarded only to the built-in CUDA/ROCm path, not the generic plugin path. JAX's plugin initialization instead explicitly generates GPU plugin options before registration. Therefore `preallocate: false` in the generic EXLA client configuration is **not** a sufficient fix. Environment variables normally interpreted by Python cannot be assumed to work in this Elixir-only route.

The opaque exception's cause has not been established. Allocator behavior and compatibility between EXLA's XLA revision (matching JAX 0.9.0) and this AMD JAX 0.8.0 plugin are concrete things to investigate; neither is a proven cause yet.

### Reproduction of the failed probe

From `experiments/nx_nes`, with the temporary extracted artifacts present:

```sh
mise exec elixir@1.20.2-otp-29 erlang@29.0.3 -- env \
  ROCM_PATH=/opt/rocm-7.2.4 \
  LD_LIBRARY_PATH=/tmp/dbern/exla-rocm-pjrt/sdk/opt/rocm-7.2.4/lib:/opt/rocm-7.2.4/lib \
  elixir -pa '_build/prod/lib/*/ebin' -e '
    Application.load(:exla)
    Application.put_env(:exla, :clients,
      probe_rocm: [
        platform: :pjrt_plugin,
        device_type: "ROCM",
        plugin_path: "/tmp/dbern/exla-rocm-pjrt/unpacked/jax_plugins/xla_rocm7/xla_rocm_plugin.so"
      ])
    Application.put_env(:exla, :default_client, :probe_rocm)
    Application.ensure_all_started(:exla) |> IO.inspect()
    EXLA.Client.fetch!(:probe_rocm) |> IO.inspect()
    f = EXLA.jit(fn x -> Nx.add(x, 1) end, client: :probe_rocm)
    f.(Nx.tensor([1, 2, 3])) |> Nx.to_flat_list() |> IO.inspect()
  '
```

This bypasses Mix compilation and changes configuration only inside the new VM. The allocator behavior above should be addressed before repeating GPU probes or attempting benchmark kernels.

## Source-build route

The [XLA package documentation](https://github.com/elixir-nx/xla) provides ROCm only through source builds: `XLA_BUILD=true XLA_TARGET=rocm`. Switching client configuration alone cannot give the current CPU binary built-in ROCm support.

The installed XLA package pins OpenXLA revision `bb760b047bdbfeff962f0366ad5cc782c98657e0` (same revision as JAX 0.9.0). Its README calls for Bazel 7.7.0, Clang 18, Git and Python with NumPy, and warns of long build times. No Bazel executable was found on the current PATH; ROCm has its own Clang in `/opt/rocm/llvm/bin`.

The package's hardcoded `TF_ROCM_AMDGPU_TARGETS` list is `gfx90a,gfx942,gfx1030,gfx1100,gfx1200,gfx1201`, which omits this machine's `gfx1151`. In an **isolated dependency copy**, change that build target to `gfx1151` (or add it). Simply setting the same option through `BUILD_FLAGS` is unreliable here: the Makefile appends its internal flags after user flags.

An isolated build would need:

1. A separate Mix project / dependency and build directory, with a local patched XLA 0.10.0 dependency; leave the CPU experiment's `deps` and `_build` alone.
2. Compatible Bazel, Clang and ROCm development dependencies, including the profiler dependencies identified above.
3. Environment `XLA_BUILD=true`, `XLA_TARGET=rocm`, `ROCM_PATH=/opt/rocm-7.2.4`, and the matching runtime library path.
4. A `gfx1151` XLA build, followed by compiling EXLA against that artifact.
5. Client configuration `rocm: [platform: :rocm, preallocate: false]`, with explicit `client: :rocm` for validation. Keep host CPU as a separately available client.

No source build was started. It fetches and compiles a substantial compiler toolchain; build duration and disk requirements have not been measured here.

## Recommended next steps

First create an isolated EXLA adapter experiment that forwards PJRT client options (especially allocator preallocation/memory fraction) and reports the underlying native exception. Test a compatible AMD plugin version before spending time on the full source build. The current EXLA NIF already exposes plugin loading; this is the smaller uncertainty to resolve.

After a tiny integer kernel succeeds, validate the existing APU and PPU fixtures on ROCm, including their floating-point/state tolerances, then benchmark with warm compilation and explicit output synchronization. Test both resident and upload-inclusive timings. GPU launch overhead may worsen a sequential CPU interpreter; graphics/audio block speedups cannot be assumed to transfer to the whole core.

Keep Nx/EXLA in the separate implementation so that the existing native Elixir core remains usable without XLA or GPU runtime libraries.

## Successful isolated adapter follow-up

The recommended adapter investigation above was completed. The adapter is at `/tmp/dbern/exla-rocm-pjrt/adapter`; its reproducible source delta is saved in [`rocm_pjrt_adapter.patch`](rocm_pjrt_adapter.patch). It is a probe patch, not a production-ready upstream change: it hardcodes ROCm's platform/allocator options and the temporary NIF path.

Changes:

- Forward the configured `memory_fraction` and `preallocate` through the Elixir client and three-argument NIF into `xla::GetCApiClient` options. The probe uses `memory_fraction: 0.05`, `preallocate: false`, platform `ROCM`, allocator `bfc`.
- Catch `std::exception` around native client creation and include the exception type and message. Fine's existing handler catches `std::runtime_error` and `std::invalid_argument`, but otherwise hides details under its generic catch.
- Load the copied NIF from its explicit temporary path so OTP cannot resolve the original application's `priv` directory.

This exposed the precise failure:

```text
absl::BadStatusOrAccess: FAILED_PRECONDITION:
Could not load dynamic library 'libMIOpen.so.1'
```

The initial opaque exception was therefore missing MIOpen, not established evidence of a PJRT ABI incompatibility.

Downloaded `miopen-hip_3.5.1.70204-93~24.04_amd64.deb` (307,969,764 bytes) from AMD's ROCm 7.2.4 repository. Its SHA256 is `b5759989f8d95b367d83309f4d9da3c55c1e5868703aaede1647434df375b6c2`, matching package metadata. Extracted **only** `./opt/rocm-7.2.4/lib/libMIOpen.so*` into the existing temporary `sdk` directory, avoiding its large kernel database and a system installation.

The next probe succeeded:

```text
StreamExecutor device (0): Radeon 8060S Graphics, AMDGPU ISA version: gfx1151
XLA backend will use up to 6657199408 bytes on device 0 for BFCAllocator.
PjRtCApiClient created.
%EXLA.Client{platform: :pjrt_plugin, name: :probe_rocm, device_count: 1, ...}
GPU result: [2, 3, 4]
```

The allocator now reports an upper limit with preallocation disabled. It also reports a large **collective** allocator limit; this probe has no collectives and does not establish their physical memory behavior. A reusable adapter should expose/control collective allocation options as well. The GPU linker emitted a `libxml2.so.2` version-information warning, but the arithmetic compilation and execution succeeded.

The arithmetic probe includes GPU-to-host result synchronization. Startup, compilation and execution were not timed separately, so its approximately few-second process duration is not a performance benchmark.

### Exact artifacts and commands

The runtime-only script is `/tmp/dbern/exla-rocm-pjrt/probe.exs`. The patched NIF is `/tmp/dbern/exla-rocm-pjrt/adapter/app/priv/libexla.so`; patched beams are in the neighboring `ebin` directory. The adapter reused existing XLA headers/libraries read-only and rebuilt only EXLA's C++ wrapper. It did not run `mix deps.compile` or change the experiment's dependency build.

Wrapper build, from the adapter directory:

```sh
make -j2 EXLA_CPU_ONLY=1 EXLA_VERSION=0.13.1 MIX_ENV=prod \
  MIX_BUILD_EMBEDDED=true \
  MIX_APP_PATH=/tmp/dbern/exla-rocm-pjrt/adapter/app \
  ERTS_INCLUDE_DIR=/home/dbern/.local/share/mise/installs/erlang/29.0.3/erts-17.0.3/include \
  FINE_INCLUDE_DIR=/home/dbern/beamicom/experiments/nx_nes/deps/fine/c_include
```

`EXLA_CPU_ONLY=1` here disables EXLA's optional CUDA wrapper compilation; GPU execution is supplied by the dynamically loaded PJRT plugin. Compile the changed `lib/exla/client.ex` and `lib/exla/nif.ex` into the adapter's `app/ebin` with `elixirc`, using the original dependency beams on the code path. The copied app's `priv/xla_extension/lib` must resolve to the existing XLA library directory.

Successful run:

```sh
mise exec elixir@1.20.2-otp-29 erlang@29.0.3 -- env \
  ROCM_PATH=/opt/rocm-7.2.4 \
  LD_LIBRARY_PATH=/tmp/dbern/exla-rocm-pjrt/sdk/opt/rocm-7.2.4/lib:/opt/rocm-7.2.4/lib \
  elixir \
  -pa '/home/dbern/beamicom/experiments/nx_nes/_build/prod/lib/*/ebin' \
  -pa /tmp/dbern/exla-rocm-pjrt/adapter/app/ebin \
  /tmp/dbern/exla-rocm-pjrt/probe.exs
```

Next: validate the NES block audio and graphics fixtures through this adapter, then benchmark them. Generalize and test the small EXLA adapter change before exposing ROCm as a supported application backend. Full XLA source compilation is unnecessary for the successful arithmetic route demonstrated here.

## NES kernel correctness smoke test

Completed the bounded follow-up using the current project beams, the captured Castlevania states and the isolated adapter. Reproducible scripts are retained as [`rocm_probe.exs`](rocm_probe.exs) and [`rocm_smoke.exs`](rocm_smoke.exs). They expect the temporary plugin/adapter libraries described above. Run the successful command above with `rocm_smoke.exs` as the script, from `experiments/nx_nes`.

- **PPU:** selected 24 captured scanlines spread across the capture (`take_every(90)`), evaluated together in one vectorized `PPU.render/2` call. All 6,144 pixel bytes, all status registers and all next-scroll values exactly matched the native Elixir rendering reference.
- **Block APU:** started from a captured MMC5-active state, then evaluated three consecutive intervals: 29,830 cycles with 12 timestamped events, 29,830 cycles without writes, and 1,234 cycles with two disabling writes. The first interval exercises same-cycle event ordering, sample-adjacent writes, a status read, frame-sequencer mode change, noise mode, and MMC5 pulse/PCM writes.
- All **1,501 PCM samples matched byte-for-byte** (735 + 735 + 31); emitted counts, consumed events and unconsumed-cycle values matched. Every returned state field matched the native reference, with floating-point tolerance `1e-12` and exact integer comparison.
- For correctness inspection the smoke test exports full APU state after each call, compares it, and uploads it for continuation. This is not a benchmark of uninterrupted GPU-resident state.

Exploratory single-call timings on this machine:

| Call | Time |
| --- | ---: |
| PPU, 24 lines, first call including compilation | 410.236 ms |
| PPU, same resident inputs, one warm call with output export | 0.948 ms |
| APU, 29,830 cycles / 12 events, first call including compilation and full-state export | 1,600.285 ms |
| APU, 29,830 cycles / no events, warm call including full-state export | 49.391 ms |
| APU, 1,234 cycles / two events, warm call including full-state export | 12.623 ms |

These are one-off smoke-test timings under an experimental plugin configuration. They are not directly comparable to the earlier CPU benchmark medians, which have different workloads/export boundaries. In particular they do **not** demonstrate GPU APU acceleration. No scalar APU kernel or full NES replay was run on GPU.

The next useful measurement is an identical, repeated resident-input CPU/GPU comparison of the batched kernels, with only intended output exported. The correctness smoke test demonstrates feasibility of the ROCm backend; it does not establish that GPU execution is advantageous for a single emulator instance.

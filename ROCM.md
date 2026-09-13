# ROCm with the optional NES/GBC Nx renderers

Updated 2026-09-13. Both `beamicom_nes_nx` and `beamicom_gbc_nx` pin **Nx 1.0.0 / EXLA 1.0.0 / XLA 0.10.0**. The native `beamicom_nes` and `beamicom_gbc` applications remain independent of Nx/EXLA. CPU execution, bus/device timing and mapper effects remain native; optional Nx packages accelerate rendering/audio blocks.

**Current status:** the installed XLA artifact is CPU-only. All existing NES/GBC renderer compilation and resident-copy sites explicitly select `client: :host`. Setting EXLA's default client to ROCm will therefore **not** move these renderers to the GPU. There is no application-wide ROCm switch yet.

## Hardware and runtime prerequisites

Rechecked locally: Ryzen AI MAX+ 395, Radeon 8060S (`gfx1151`), ROCm **7.2.4** at `/opt/rocm-7.2.4`, HSA runtime 1.18. GPU access requires working `amdgpu`/KFD drivers and permission to access `/dev/kfd` and `/dev/dri/renderD128`. These nodes are hidden inside the tool sandbox but available outside it; `rocminfo` successfully enumerates the GPU.

```sh
rocminfo
cat /opt/rocm/.info/version
ls -l /dev/kfd /dev/dri/renderD128
```

Use a mutually compatible ROCm SDK, GPU target, driver and Linux distribution; successful enumeration does not certify every framework configuration. The GPU identity is documented in AMD's [Ryzen compatibility matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityryz/native_linux/native_linux_compatibility.html).

Beyond HIP/HSA, XLA's ROCm runtime may require rocBLAS, hipBLASLt, MIOpen and profiler libraries even for a simple computation. Local MIOpen remains absent from `/opt/rocm/lib`; the earlier probe supplied it temporarily. Linker dependencies must be checked with `ldd`, but that does not reveal every library opened dynamically during client initialization.

## Upstream build path: built-in `:rocm`

XLA 0.10.0 offers ROCm through a **source build**, with `XLA_BUILD=true XLA_TARGET=rocm`; there is no official ROCm prebuilt archive in that package. Its documented build prerequisites include Bazel 7.7.0, Clang 18, Git and Python/NumPy. This build has not been attempted here. See [XLA build instructions](https://github.com/elixir-nx/xla#building-from-source).

Build in a separate checkout, preserving CPU dependency/build caches. The example copies committed repository state; it does not include uncommitted work:

```sh
cd /home/dbern/beamicom
ROCM_CHECKOUT=$(mktemp -d /tmp/beamicom-rocm.XXXXXX)
git clone --local . "$ROCM_CHECKOUT/repo"
cd "$ROCM_CHECKOUT/repo/beamicom_nes_nx"

export ROCM_PATH=/opt/rocm-7.2.4
export LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_CACHE_HOME="$ROCM_CHECKOUT/cache"
export XLA_BUILD=true XLA_TARGET=rocm
mix deps.get
```

With the pinned XLA package, patch **only that checkout's** GPU target list before compiling. It currently omits `gfx1151`. Its internal Bazel flags follow `BUILD_FLAGS`, so a conflicting user flag is not a reliable override:

```sh
python3 - <<'PY'
from pathlib import Path
p = Path("deps/xla/lib/xla.ex")
s = p.read_text()
old = 'gfx90a,gfx942,gfx1030,gfx1100,gfx1200,gfx1201'
assert old in s, "Recheck XLA's GPU build flags before proceeding"
p.write_text(s.replace(old, 'gfx1151'))
PY
mix deps.compile
mix compile
```

These commands assume the project's compatible Elixir/OTP and the required compiler tools are already on PATH. Here Elixir 1.20.2 / OTP 29.0.3 are available through `mise exec elixir@1.20.2-otp-29 erlang@29.0.3 --`. Building is substantial and may expose further version-specific issues; the commands are a build recipe, not a verified successful build.

## Client selection and CPU fallback

For a ROCm-capable XLA build, use this **consumer application's** configuration:

```elixir
config :exla, :clients,
  host: [platform: :host],
  rocm: [platform: :rocm, preallocate: false, memory_fraction: 0.05]

config :exla, :default_client, :host
```

Select the GPU explicitly for a kernel and its buffers; leave host as the default:

```elixir
gpu = Nx.backend_copy(Nx.tensor([1, 2, 3]), {EXLA.Backend, client: :rocm})
run = EXLA.jit(fn x -> Nx.add(x, 1) end, client: :rocm)
[2, 3, 4] = run.(gpu) |> Nx.to_flat_list()
```

This is the [EXLA client configuration model](https://exla.hexdocs.pm/EXLA.html#module-clients). GPU build selection occurs at dependency compilation; `EXLA_TARGET=rocm` is not an application runtime selector.

To enable it for the actual NES/GBC renderers, implementation work remains: introduce a client selection shared by `EXLA.compile` and every `Nx.backend_copy`, include the client in compiled-function/atlas cache keys, and reconstruct resident audio state on that same client. Audit NES `ppu_renderer.ex`/`apu_block_renderer.ex`, GBC `ppu_renderer.ex`/`apu_block_renderer.ex`/`apu_synth_renderer.ex`, and new postprocessing kernels. Mixing GPU compilation with host-resident state introduces transfers or errors.

Keep host selection as the default and validate a requested GPU before loading a machine. If GPU startup fails, explicitly choose host before creating resident state; do not silently reset active emulation mid-frame. A separate CPU-only XLA build remains necessary on systems unable to load ROCm-linked libraries. For **no XLA support**, use the native packages without the optional Nx dependencies. Renderer selection is generally compile-time configuration and requires recompilation when changing the selected modules; an EXLA default-client change cannot substitute for that.

## Alternative: external AMD PJRT plugin

EXLA 1.0 still exposes `platform: :pjrt_plugin`, but its generic client path does **not** forward `preallocate`/`memory_fraction`. An isolated adapter was tested previously with **EXLA 0.13.1**, reusing the CPU XLA library and dynamically loading AMD's plugin. That result has not been revalidated against EXLA 1.0 and is not a supported packaged backend today.

Historical artifacts still present under `/tmp/dbern/exla-rocm-pjrt`:

- `adapter/`: modified EXLA wrapper and beams; forwards allocator options and reveals `std::exception` details.
- `unpacked/jax_plugins/xla_rocm7/xla_rocm_plugin.so`: AMD JAX 0.8.0 + ROCm 7.2.0 plugin.
- `sdk/opt/rocm-7.2.4/lib`: temporarily extracted profiler/AQL/MIOpen libraries.
- `probe.exs`, `nes_smoke.exs`: old probes referencing the removed experimental project.

The plugin came from AMD's [ROCm 7.2 JAX distribution](https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-jax.html). Exact download:

```text
https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/jax_rocm7_pjrt-0.8.0%2Brocm7.2.0-py3-none-manylinux_2_28_x86_64.whl
SHA256 d0f11672c50328d13621dd8a33be0b830e28e857998b4b2957bb6d6061daeadf
```

Its adapter bootstrap was:

```elixir
Application.put_env(:exla, :clients,
  probe_rocm: [platform: :pjrt_plugin, device_type: "ROCM",
    plugin_path: "/tmp/dbern/exla-rocm-pjrt/unpacked/jax_plugins/xla_rocm7/xla_rocm_plugin.so",
    preallocate: false, memory_fraction: 0.05])
```

Launch with `ROCM_PATH=/opt/rocm-7.2.4` and `LD_LIBRARY_PATH=/tmp/dbern/exla-rocm-pjrt/sdk/opt/rocm-7.2.4/lib:/opt/rocm-7.2.4/lib`. The allocator options work **only with that patched adapter**, not stock EXLA's generic PJRT client. Rebuild the adapter against current EXLA before reuse; do not put old 0.13.1 beams ahead of 1.0 beams.

Earlier missing profiler libraries prevented plugin loading; missing `libMIOpen.so.1` then caused client creation to fail. The NIF initially hid the MIOpen error as an unknown exception. Once resolved, GPU arithmetic succeeded, 24 old PPU scanlines matched exactly, and 1,501 old block-APU samples matched byte-for-byte with final state within `1e-12`. **No GBC or current 1.0 renderer GPU correctness claim follows from those tests.** Preallocation was disabled; the collective allocator still reported a large upper limit and needs explicit review in a reusable adapter.

## Performance expectations and validation

A single NES/GBC instance produces small frame/audio blocks. Kernel launches, output synchronization and sequential audio filters can outweigh GPU parallelism. The earlier GPU smoke test did not establish a speedup. Current README performance numbers concern **EXLA CPU**, not ROCm. NES frame composition/audio batching and GBC's 160×144 output have different costs; neither implies the other benefits.

Many independent emulator instances provide a more promising batch axis. Combine same-shape device workloads into one execution while retaining per-instance input, timing and state. This is prospective work: the repository does not yet expose a multi-instance GPU batch runner. Unified physical memory on the 8060S does not automatically remove EXLA transfers or synchronization.

Validation checklist:

1. Confirm GPU architecture, permissions, runtime libraries and actual selected EXLA client; synchronize a tiny integer kernel's output.
2. Run current NES and GBC differential tests, including mapper effects, DMC/expansion audio, save/restore and frame/sample boundaries. Compare PCM/video hashes and state, not just successful execution.
3. Run identical ROM/input traces on native, EXLA host and ROCm. Warm compilation separately; report repeated medians, full-frame latency and transfer-inclusive costs.
4. Measure one instance first, then explicit batches (for example 8 and 32), including latency and memory use. Export only intended PCM/video during performance runs.
5. Verify startup without GPU and the dependency-free native build without Nx/EXLA.

For this documentation refresh, local 1.0 development beams reported `Nx 1.0.0`, `EXLA 1.0.0`, supported platforms `%{host: 32}`, and host arithmetic `[1,2,3] + 1 == [2,3,4]`. Hardware/runtime checks were repeated. No new GPU build or emulator benchmark was run. The old investigation document under `experiments/nx_nes` no longer exists, so this file replaces that historical location without modifying active renderer work.

# Building Beamicom Nx/EXLA with ROCm

This guide covers the ROCm source build used by Beamicom's optional Nx
renderers. It intentionally contains no workstation-specific hardware,
account, or filesystem details.

The current lockfiles select Nx 1.0.0, EXLA 1.0.0, and XLA 0.10.0. XLA does
not publish a prebuilt ROCm archive for this combination, so the XLA native
extension must be built locally. Build it from an application that directly
depends on EXLA, such as `beamicom_phx` or `beamicom_scenic`.

The first build compiles OpenXLA and is large and slow. Keep its caches if the
same artifact will be reused.

## 1. Install and check the prerequisites

Install a ROCm SDK supported by the GPU and operating system, including its
development packages. OpenXLA's configuration step needs more than the HIP
runtime: it also looks for MIOpen, rocTracer, and rocProfiler SDK headers and
libraries. On an Ubuntu installation using AMD's package repository, the
additional package names are commonly:

```sh
sudo apt-get install \
  build-essential git python3-numpy \
  libnuma-dev \
  clang-18 lld-18 gcc-15 g++-15 \
  miopen-hip miopen-hip-dev roctracer-dev rocprofiler-sdk
```

Package names vary by distribution and ROCm release. AMD's `rocm-ml-sdk`
metapackage is another way to obtain the machine-learning development stack.

XLA 0.10.0 specifically requires Bazel 7.7.0 and uses Clang 18 for its host
C++ build. Verify the tools before starting:

```sh
rocminfo
bazel --version                    # bazel 7.7.0
/usr/lib/llvm-18/bin/clang --version
python3 -c 'import numpy; print(numpy.__version__)'
```

If Bazel 7.7.0 is not packaged by the distribution, install the official
release binary and verify its published checksum:

```sh
BAZEL_VERSION=7.7.0
BAZEL_FILE="bazel-${BAZEL_VERSION}-linux-x86_64"
BAZEL_URL="https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}"
BAZEL_TMP="$(mktemp -d)"

curl -fL "$BAZEL_URL/$BAZEL_FILE" -o "$BAZEL_TMP/$BAZEL_FILE"
curl -fL "$BAZEL_URL/$BAZEL_FILE.sha256" -o "$BAZEL_TMP/$BAZEL_FILE.sha256"
(cd "$BAZEL_TMP" && sha256sum --check "$BAZEL_FILE.sha256")
install -Dm755 "$BAZEL_TMP/$BAZEL_FILE" "$HOME/.local/bin/bazel"
```

Make sure `$HOME/.local/bin` is on `PATH` in the shell used for the build.

## 2. Select the ROCm SDK and GPU target

Resolve the ROCm symlink. Supplying a resolved compiler path matters because
Bazel validates absolute header paths:

```sh
export ROCM_PATH="$(readlink -f /opt/rocm)"
export HIP_CLANG_PATH="$(readlink -f "$ROCM_PATH/llvm")/bin"
export LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

GPU_TARGET="$(rocminfo | awk '/Name:/ && $2 ~ /^gfx[0-9]/ { print $2; exit }')"
test -n "$GPU_TARGET" || { echo "No ROCm GPU target found" >&2; exit 1; }
printf 'Building for %s\n' "$GPU_TARGET"
```

Do not use the host Clang as `HIP_CLANG_PATH`; HIP device compilation needs the
compiler bundled with the selected ROCm SDK. Conversely, keep Clang 18
installed at `/usr/lib/llvm-18` for the OpenXLA host build.

## 3. Prepare the dependency source

Choose a direct consumer and fetch its dependencies:

```sh
cd beamicom_scenic                 # or: cd beamicom_phx

export XLA_BUILD=true
export XLA_TARGET=rocm
export XLA_CACHE_DIR="$HOME/.cache/beamicom-xla"
export BEAMICOM_SCENIC_NX=1        # required when using beamicom_scenic

mix deps.get
```

XLA 0.10.0 has a fixed ROCm architecture list. If the detected `GPU_TARGET` is
not in that list, patch the fetched dependency to build for the local GPU. The
following replacement is intentionally validated and changes only the target
argument:

```sh
python3 - "$GPU_TARGET" <<'PY'
import re
import sys
from pathlib import Path

path = Path("deps/xla/lib/xla.ex")
source = path.read_text()
pattern = r'~s/--action_env=TF_ROCM_AMDGPU_TARGETS="[^"]+"/'
replacement = f'~s/--action_env=TF_ROCM_AMDGPU_TARGETS="{sys.argv[1]}"/'
updated, count = re.subn(pattern, replacement, source, count=1)
if count != 1:
    raise SystemExit("XLA ROCm target flag was not found; inspect deps/xla/lib/xla.ex")
path.write_text(updated)
PY
```

This is a generated dependency-tree change. Repeat it after replacing or
updating `deps/xla`; do not commit it as a Beamicom source change.

### Compatibility setting for newer C++ runtimes

If Clang 18 automatically selects a newer libstdc++ and fails in standard
library headers with incomplete-type/template errors, point it at GCC 15's
compatible runtime headers and libraries:

```sh
GCC_INSTALL_DIR="$(dirname "$(gcc-15 -print-libgcc-file-name)")"
export BUILD_FLAGS="--copt=--gcc-install-dir=$GCC_INSTALL_DIR \
--host_copt=--gcc-install-dir=$GCC_INSTALL_DIR \
--linkopt=--gcc-install-dir=$GCC_INSTALL_DIR \
--host_linkopt=--gcc-install-dir=$GCC_INSTALL_DIR"
```

Leave `BUILD_FLAGS` unset unless this compatibility problem occurs.

## 4. Build XLA, EXLA, and the application

Keep every environment variable above in the shell for all of these commands:

```sh
mix deps.clean xla --build
mix deps.compile xla --force
mix deps.compile exla --force
mix compile
```

`mix deps.compile xla` performs the long Bazel build and writes a reusable
archive below:

```text
$XLA_CACHE_DIR/0.10.0/build/xla_extension-0.10.0-x86_64-linux-gnu-rocm.tar.gz
```

To reuse that artifact in another clean checkout with the same OS, CPU
architecture, ROCm stack, and dependency versions:

```sh
unset XLA_BUILD
export XLA_TARGET=rocm
export XLA_ARCHIVE_PATH=/absolute/path/to/xla_extension-0.10.0-x86_64-linux-gnu-rocm.tar.gz
mix deps.compile xla --force
mix deps.compile exla --force
```

`XLA_ARCHIVE_PATH` avoids rebuilding OpenXLA. It does not remove the runtime
requirement for the matching ROCm libraries.

## 5. Configure Beamicom to select ROCm

Configure both the EXLA clients and Nx's default defn options before EXLA is
started:

```elixir
config :exla, :clients,
  rocm: [platform: :rocm, preallocate: false],
  host: [platform: :host]

config :nx, :default_defn_options,
  compiler: EXLA,
  client: :rocm
```

The `preallocate: false` setting is a conservative starting point. Tune EXLA's
allocator options only after measuring the application's memory needs.

Setting only `config :exla, :default_client, :rocm` is insufficient for the
standard Beamicom renderer modules: their fallback options explicitly select
the host when Nx has no default defn options. The `:nx` setting above supplies
the compiler/client pair used for compilation and resident tensors.

`beamicom_phx` enables the NES and GBC Nx renderers in its application config.
For `beamicom_scenic`, set `BEAMICOM_SCENIC_NX=1` on every Mix invocation that
compiles or runs the application.

Most standard NES, GBC, and SNES Nx renderers use these shared Nx options. Two
specialized NES modules, `FrameVideoExecutable` and `FrameAPUExecutable`, still
compile explicitly for `client: :host`; they require a code change if those
particular wrappers must run on ROCm.

## 6. Run a GPU smoke test

Run the probe outside containers or sandboxes that hide `/dev/kfd` or the DRM
render node:

```sh
mix run --no-start -e '
Application.put_env(:exla, :clients,
  rocm: [platform: :rocm, preallocate: false],
  host: [platform: :host])
{:ok, _} = Application.ensure_all_started(:exla)
tensor = Nx.backend_copy(Nx.tensor([1, 2, 3]),
  {EXLA.Backend, client: :rocm})
increment = EXLA.jit(fn value -> Nx.add(value, 1) end, client: :rocm)
[2, 3, 4] = tensor |> increment.() |> Nx.to_flat_list()
IO.puts("ROCm EXLA smoke test passed")
'
```

This tests client creation, device transfer, compilation, execution, and
synchronization. A successful dependency compile alone does not prove that the
runtime can open the GPU device and all dynamically loaded ROCm libraries.

## Benchmark results

The validated build was benchmarked on 2026-09-15 with the repository's
deterministic NES and Game Boy benchmark tasks. Each client received one
complete untimed warm-up run, so compilation and first-use setup were excluded.
Five measured runs followed. Frame results were copied back to binaries, which
synchronizes device work and prevents asynchronous execution from making the
ROCm timings look artificially fast.

| Workload | EXLA host median | EXLA ROCm median | ROCm relative to host |
| --- | ---: | ---: | ---: |
| NES, Nx video and native audio, 181 frames per run | 137.4 FPS | 144.9 FPS | 1.054x (5.4% faster) |
| NES, Nx video and original `f64` Nx block audio, 301 frames per run | 139.4 FPS | 20.3 FPS | 0.146x (6.85x slower) |
| NES, Nx video and Q30 fixed-point Nx block audio, 301 frames per run | 141.6 FPS | 22.23 FPS | 0.157x (6.37x slower) |
| NES, vectorized Q30 Nx block audio, 301 frames per run | 141.54 FPS | 85.42 FPS | 0.604x (1.66x slower) |
| Game Boy, Nx video and native audio, 300 frames per run | 80.43 FPS | 58.82 FPS | 0.731x (1.37x slower) |
| Game Boy, Nx video and original integer Nx synthesis, 300 frames per run | 69.13 FPS | 58.65 FPS | 0.848x (1.18x slower) |
| Game Boy, Nx video and frame-parallel integer Nx synthesis, 300 frames per run | 73.19 FPS | 60.81 FPS | 0.831x (1.20x slower) |
| Game Boy, sparse sprite PPU and frame-parallel integer Nx synthesis, 300 frames per run | 70.18 FPS | 65.37 FPS | 0.932x (1.07x slower) |

The separated results are important: ROCm does accelerate the NES frame-wide
PPU renderer. The initial all-Nx result was dominated by the NES block APU and
was not representative of the video kernel. Temporary stage instrumentation
measured the warmed `BlockAPU.run/6` executable call at about 37.8 ms per frame
on ROCm and 0.68 ms on the host. Packing, transfers, and result synchronization
together accounted for about 0.64 ms of the ROCm call. This graph contains
scalar `while` control flow and double-precision recurrent audio state, which
maps poorly to the GPU despite being expressed through Nx.

The block APU was subsequently converted to signed Q30 fixed point. Its exact
integer phase accumulator and fixed-point mixer/filter reproduce the original
five-second audio hash. The dedicated DMC, expansion-audio, donation, and
save-state tests also pass. This raised ROCm throughput by 9.3%, from 20.34 to
22.23 FPS, and host throughput by 1.6%, from 139.4 to 141.6 FPS. This showed
that floating-point arithmetic was not the primary bottleneck.

The fixed-point implementation was then restructured so each event-free epoch
computes up to 128 exact sample positions and raw mixer values with vector
operations. The strictly recurrent high-pass/low-pass filter is applied to the
returned Q30 samples on the host. That filter cannot use ordinary element-wise
parallelism because each output depends on the previous output, but it is small
enough that moving it out of the device graph is inexpensive. This change
raised ROCm throughput from 22.23 to 85.42 FPS (3.84x) and to 4.20x the original
`f64` result. It is about 1.42x real time. Host throughput remained essentially
unchanged at 141.54 FPS. The audio and video hashes remained identical across
all five runs and both clients.

ROCm remains slower than the host for this APU because work is still divided by
timestamped register events, the device is invoked once per emulated frame, and
the amount of audio arithmetic per invocation is small. The parallel section
is now large enough to amortize much more of the device-control cost, while the
unavoidable filter recurrence no longer serializes a GPU kernel.

The tested Game Boy PPU graph remained slower on ROCm at this single-frame
granularity. The Game Boy event-block synthesizer was already
integer-only and already kept its analog high-pass recurrence on the host. It
was further restructured so a small sequential pass records control-epoch start
states and a single tensor operation evaluates pulse, wave, noise, routing, and
stereo mixing for every frame sample. This raised the end-to-end ROCm median
from 58.65 to 60.81 FPS (3.7%) and the host median from 69.13 to 73.19 FPS
(5.9%), with unchanged hashes. The PPU remains the dominant cost in this
whole-system measurement.

The Game Boy PPU was then changed to select only the first ten eligible sprites
per scanline and rasterize their eight-pixel spans. The earlier graph expanded
all forty OAM entries across all 160 screen pixels. This raised the end-to-end
ROCm median from 60.81 to 65.37 FPS (7.5%); the host median changed from 73.19
to 70.18 FPS (-4.1%). A separate timed-write benchmark showed that reconstructing
per-scanline VRAM, OAM, and palette state once was 1.39x to 3.16x faster than
replaying writes at every read site on ROCm for one through sixteen events. The
same reconstruction was slower on the host in isolation, but the renderer now
uses the same parallel reconstruction graph on every Nx backend. Static frames
do not materialize per-scanline memory. Output hashes remained identical in all
comparisons.

Host and ROCm produced identical video and audio hashes in every comparison.
The NES benchmark's serialized machine-state hash includes backend-resident
tensor objects and therefore differs between clients; it is useful for checking
repeatability on one client, but is not a valid cross-client state-equivalence
test.

For NES, the fastest ROCm configuration tested is the Nx PPU with native audio:

```elixir
config :beamicom_nes,
  ppu_renderer: Beamicom.NES.Nx.PPURenderer,
  apu_renderer: :native
```

Use this together with the ROCm Nx/EXLA configuration above. Do not place the
NES `APUBlockRenderer` on ROCm when maximum throughput is the goal: the native
audio configuration is still faster. The vectorized Nx APU is now viable for
real-time output when device-executed audio is desired. Running the Nx APU on
the host while the Nx PPU runs on ROCm would require per-renderer compiler
options; the current renderer helpers use one global `Nx.Defn.default_options/0`
setting. For the tested Game Boy workload, the EXLA host client remains faster,
although sparse sprite rasterization narrowed the ROCm gap to 7%. Larger fused
workloads or batched multi-instance rendering may change these tradeoffs and
should be measured independently.

To reproduce the workloads with another suitable ROM, first compile with the
requested renderer pair, then run the corresponding command once with
`client: :host` and once with `client: :rocm` in the Nx configuration:

```sh
mix nes.bench path/to/test.nes \
  --seconds 3 --repeats 5 --renderer nx --audio-renderer native

mix nes.bench path/to/test.nes \
  --seconds 3 --repeats 5 --renderer native --audio-renderer nx_block

mix gb.bench path/to/test.gbc \
  --frames 300 --repeats 5 --renderer nx --audio-renderer nx
```

Use the all-Nx renderer pair as a separate comparison if desired. Renderer
selection is compile-time, so the task rejects flags that do not match the
compiled application configuration.

No SNES end-to-end number is reported because the repository does not include
a redistributable SNES benchmark ROM.

## Troubleshooting

- **No ROCm precompiled archive:** confirm both `XLA_BUILD=true` and
  `XLA_TARGET=rocm`, then run `mix deps.clean xla --build` before recompiling.
- **`MIOpen version file ... not found`:** install both the MIOpen runtime and
  development package from the same ROCm repository.
- **rocTracer version/header not found:** install `roctracer-dev`.
- **rocProfiler SDK library not found:** install the full `rocprofiler-sdk`, not
  only its registration helper package.
- **Final link fails with `unable to find library -lnuma`:** install
  `libnuma-dev`; the runtime library alone does not provide the linker name.
- **HIP compiler path names a nonexistent LLVM directory:** set
  `HIP_CLANG_PATH` to the resolved `$ROCM_PATH/llvm/bin` directory as shown
  above; verify that `$HIP_CLANG_PATH/clang` exists.
- **libstdc++ incomplete-type/template errors:** use the GCC 15 `BUILD_FLAGS`
  compatibility setting above.
- **Only a host client is available:** the CPU archive was reused. Rebuild XLA
  with the ROCm environment, or set `XLA_ARCHIVE_PATH` to the ROCm archive.
- **Client creation cannot access a device:** check `rocminfo`, membership and
  permissions for the system's GPU device nodes, and whether the execution
  environment exposes them.
- **A runtime library is missing:** run `ldd` on EXLA's `libexla.so` and the XLA
  extension, then ensure the matching ROCm library directory is on the dynamic
  loader path. Some ROCm components are loaded dynamically and may not appear
  in `ldd`; the first client-creation error is usually more specific.

## What was validated

Validated end to end on 2026-09-15 against the versions pinned by this
repository:

- OpenXLA completed its host and HIP device compilation, linked, and produced
  the reusable ROCm archive.
- EXLA compiled and linked against that archive.
- `beamicom_scenic` and its Nx-enabled NES, GBC, and SNES dependencies compiled
  with `BEAMICOM_SCENIC_NX=1`.
- The smoke test created the ROCm client, transferred an integer tensor,
  compiled and ran the kernel, and returned `[2, 3, 4]`.

This validates the build path and a basic GPU execution. It is not a renderer
correctness or performance benchmark.

Upstream references:

- [Elixir XLA build and ROCm instructions](https://github.com/elixir-nx/xla#building-from-source)
- [AMD ROCm Linux installation guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [AMD MIOpen installation guide](https://rocm.docs.amd.com/projects/MIOpen/en/latest/install/install.html)

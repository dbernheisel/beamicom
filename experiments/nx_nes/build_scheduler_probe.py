"""Build a process-local diagnostic override against this exact bundled XLA ABI."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parent
include = root / 'deps/exla/cache/xla_extension/include'
library = root / '_build/prod/lib/exla/priv/xla_extension/lib'
output = root / 'tmp/sequential_thunks.so'
output.parent.mkdir(exist_ok=True)
# NDEBUG is required by EXLA's Makefile to match XLA's struct layouts.
subprocess.run(['c++', '-std=c++17', '-DNDEBUG', '-O2', '-fPIC', '-shared',
    '-isystem', str(include), str(root / 'native/sequential_thunks.cc'),
    '-o', str(output), '-L' + str(library), '-lxla_extension',
    '-Wl,-rpath,' + str(library), '-ldl'], check=True)
print(output)

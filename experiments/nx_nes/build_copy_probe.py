"""Build the optional process-local XLA CopyThunk counter for this bundled ABI."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
library = root / '_build/prod/lib/exla/priv/xla_extension/lib'
output = root / 'tmp/copy_probe.so'
output.parent.mkdir(exist_ok=True)
subprocess.run(['c++', '-std=c++17', '-DNDEBUG', '-O2', '-fPIC', '-shared',
               '-isystem', str(root / 'deps/exla/cache/xla_extension/include'),
               str(root / 'native/copy_probe.cc'), '-o', str(output),
               '-L' + str(library), '-lxla_extension', '-Wl,-rpath,' + str(library),
               '-ldl'], check=True)
print(output)

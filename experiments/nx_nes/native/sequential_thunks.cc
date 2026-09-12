// Diagnostic interposer: change only XLA's small-task scheduling heuristic.
// Never loaded by the app's normal configuration.
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include "xla/backends/cpu/runtime/thunk_executor.h"

namespace xla::cpu {
absl::StatusOr<ThunkExecutor> ThunkExecutor::Create(ThunkSequence sequence,
                                                   const Options& options) {
  using Fn = absl::StatusOr<ThunkExecutor> (*)(ThunkSequence, const Options&);
  static Fn original = reinterpret_cast<Fn>(dlsym(RTLD_NEXT,
      "_ZN3xla3cpu13ThunkExecutor6CreateENS0_13ThunkSequenceERKNS1_7OptionsE"));
  if (!original) { std::fprintf(stderr, "Cannot resolve original ThunkExecutor::Create\n"); std::abort(); }
  if (!std::getenv("NX_APU_FORCE_SEQUENTIAL")) return original(std::move(sequence), options);
  Options sequential = options;
  sequential.execute_sequential_buffer_threshold = std::numeric_limits<size_t>::max();
  sequential.execute_sequential_num_thunks_threshold = std::numeric_limits<size_t>::max();
  static const bool reported = [] {
    std::fprintf(stderr, "Diagnostic: forcing sequential XLA thunk execution\n");
    return true;
  }();
  (void)reported;
  return original(std::move(sequence), sequential);
}
}

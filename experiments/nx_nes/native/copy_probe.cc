// Diagnostic only: count executed XLA CopyThunks by exact buffer byte size.
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include "xla/backends/cpu/runtime/copy_thunk.h"
namespace {
constexpr size_t kLimit = 1 << 20;
std::atomic<unsigned long long> counts[kLimit + 2]{};
__attribute__((destructor)) void report() {
  const char* path = std::getenv("NX_COPY_REPORT");
  if (!path) return;
  FILE* f = std::fopen(path, "w");
  if (!f) return;
  std::fprintf(f, "bytes,count\n");
  for (size_t i = 0; i <= kLimit + 1; ++i) {
    auto n = counts[i].load(std::memory_order_relaxed);
    if (n) std::fprintf(f, "%zu,%llu\n", i, n);
  }
  std::fclose(f);
}
}
namespace xla::cpu {
tsl::AsyncValueRef<Thunk::ExecuteEvent> CopyThunk::Execute(const ExecuteParams& params) {
  using Fn = tsl::AsyncValueRef<Thunk::ExecuteEvent> (*)(CopyThunk*, const ExecuteParams&);
  static Fn original = reinterpret_cast<Fn>(dlsym(RTLD_NEXT,
    "_ZN3xla3cpu9CopyThunk7ExecuteERKNS0_5Thunk13ExecuteParamsE"));
  if (!original) std::abort();
  size_t n = src_buffer().size();
  counts[n <= kLimit ? n : kLimit + 1].fetch_add(1, std::memory_order_relaxed);
  return original(this, params);
}
}

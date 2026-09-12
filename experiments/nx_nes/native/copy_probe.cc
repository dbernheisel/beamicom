// Diagnostic only: count executed XLA CopyThunks by exact buffer byte size.
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <unordered_map>
#include "xla/backends/cpu/runtime/copy_thunk.h"
namespace {
constexpr size_t kLimit = 1 << 20;
std::atomic<unsigned long long> counts[kLimit + 2]{};
auto* sites = new std::unordered_map<std::string, std::pair<size_t, unsigned long long>>;
auto* sites_mutex = new std::mutex;
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
  if (std::getenv("NX_COPY_SITES")) {
    std::string site_path = std::string(path) + ".sites.csv";
    f = std::fopen(site_path.c_str(), "w");
    if (!f) return;
    std::fprintf(f, "op,bytes,count\n");
    for (const auto& entry : *sites)
      std::fprintf(f, "%s,%zu,%llu\n", entry.first.c_str(), entry.second.first, entry.second.second);
    std::fclose(f);
  }
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
  static const bool record_sites = std::getenv("NX_COPY_SITES") != nullptr;
  if (record_sites && n >= 1024) {
    std::lock_guard<std::mutex> lock(*sites_mutex);
    auto& entry = (*sites)[info().op_name];
    entry.first = n;
    ++entry.second;
  }
  return original(this, params);
}
}

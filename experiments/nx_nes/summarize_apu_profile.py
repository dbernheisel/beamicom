"""Summarize sampled executor stacks; percentages are stack counts, not CPU time."""
import collections, json, pathlib, re, sys
source = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'tmp/apu_stacks.json')
snapshots = json.loads(source.read_text())
tops, groups = collections.Counter(), collections.Counter()
hits = 0
for snapshot in snapshots:
    seen = False
    for block in re.split(r'\n(?=Thread \d+)', snapshot):
        if 'ThunkExecutor' not in block:
            continue
        seen = True
        top = re.search(r'^#0\s+(.*)', block, re.M).group(1)
        top = re.sub(r'0x[0-9a-f]+ in ', '', top)
        top = re.split(r' \(\) from | at ', top)[0]
        # Strip unstable futex/mutex addresses and arguments from libc symbols.
        if not ('xla::' in top or 'tsl::' in top or 'Eigen::' in top):
            top = top.split(' (')[0]
        tops[top] += 1
        if 'ThunkExecutor' in top:
            group = 'dependency scheduling/executor bookkeeping'
        elif any(x in top for x in ['futex', 'condvar', 'pthread', 'Eigen::', 'Mutex', 'SpinLock']):
            group = 'thread synchronization/queueing'
        elif 'fusion' in top or 'computation' in top:
            group = 'generated computation'
        elif 'CopyThunk' in top or 'memcpy' in top or 'memmove' in top:
            group = 'buffer copying'
        elif 'KernelThunk' in top:
            group = 'kernel dispatch'
        elif 'AsyncValue' in top or 'RefCount' in top or 'malloc' in top or 'free' in top:
            group = 'async lifecycle/allocation'
        else:
            group = 'other/unresolved'
        groups[group] += 1
    hits += seen
result = {
    'method': 'GDB all-thread stack snapshots after compile/warmup, randomized 8–23ms running intervals',
    'caveat': 'Debugger perturbs scheduling. Counts select stacks containing ThunkExecutor in 16 frames; not CPU-time percentages. A snapshot can contain multiple executor stacks.',
    'snapshots': len(snapshots), 'snapshots_with_executor': hits,
    'executor_stacks': sum(tops.values()), 'leaf_categories': dict(groups),
    'leaf_symbols': dict(tops.most_common())}
output = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else 'results/apu_nx_stack_profile.json')
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k:v for k,v in result.items() if k != 'leaf_symbols'}, indent=2))

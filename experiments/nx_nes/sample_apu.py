"""Launch a warmed Nx workload under GDB and sample native stacks (no perf permission).
Run from the experiment with Elixir and Erlang bin directories on PATH.
Debugger pauses perturb execution; use this to locate hot native paths, not time them.
"""
import ast, json, os, pathlib, queue, random, subprocess, threading, time

pathlib.Path('tmp/apu_profile.ready').unlink(missing_ok=True)
env = dict(os.environ, MIX_ENV='prod')
elixir = subprocess.check_output(['which', 'elixir'], text=True).strip()
mix = subprocess.check_output(['which', 'mix'], text=True).strip()
p = subprocess.Popen(['gdb', '-q', '-nx', '--interpreter=mi2', '--args', '/bin/sh', elixir, mix,
                      'run', 'apu_profile.exs'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
q = queue.Queue()
def reader():
    for line in p.stdout: q.put(line.rstrip())
threading.Thread(target=reader, daemon=True).start()
token = 0
label = os.environ.get('APU_PROFILE_LABEL', '')
log = open('tmp/apu_gdb' + label + '.log', 'w')
def get(timeout=60):
    line = q.get(timeout=timeout)
    log.write(line + '\n'); log.flush()
    return line

def command(cmd):
    global token
    token += 1
    p.stdin.write(str(token) + cmd + '\n'); p.stdin.flush()
    lines = []
    while True:
        line = get()
        lines.append(line)
        if line.startswith(str(token) + '^'):
            if '^error' in line: raise RuntimeError(line)
            return lines

def console(cmd):
    lines = command('-interpreter-exec console ' + json.dumps(cmd))
    return ''.join(ast.literal_eval(l[1:]) for l in lines if l.startswith('~'))
try:
    command('-gdb-set pagination off')
    command('-gdb-set confirm off')
    command('-gdb-set debuginfod enabled off')
    command('-gdb-set mi-async on')
    console('handle SIGUSR1 SIGUSR2 SIGPIPE SIGALRM nostop noprint pass')
    if os.environ.get('APU_PROFILE_SEQUENTIAL'):
        command('-gdb-set environment LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libcrypto.so.3:' + str(pathlib.Path('tmp/sequential_thunks.so').resolve()))
        command('-gdb-set environment NX_APU_FORCE_SEQUENTIAL=1')
    command('-exec-run')
    deadline = time.time() + 120
    while not pathlib.Path('tmp/apu_profile.ready').exists():
        if time.time() > deadline: raise RuntimeError('workload did not become ready')
        try:
            line = get(.1)
            if line.startswith('*stopped'): raise RuntimeError('inferior stopped: ' + line)
        except queue.Empty: pass
    print('Warmed Nx workload ready; sampling.', flush=True)
    snapshots = []
    random.seed(451)
    for i in range(int(os.environ.get('APU_SAMPLES', '200'))):
        time.sleep(random.uniform(.008, .023))
        command('-exec-interrupt')
        # The interrupt acknowledgement precedes the all-stop notification.
        while not get().startswith('*stopped'): pass
        snapshots.append(console('thread apply all bt 16'))
        pathlib.Path('tmp/apu_stacks' + label + '.json').write_text(json.dumps(snapshots))
        command('-exec-continue')
        if (i + 1) % 25 == 0: print(f'{i + 1} snapshots', flush=True)
    pathlib.Path('tmp/apu_stacks' + label + '.json').write_text(json.dumps(snapshots))
    print('Saved tmp/apu_stacks' + label + '.json', flush=True)
finally:
    try: command('-gdb-exit')
    except Exception: p.kill()
    log.close()

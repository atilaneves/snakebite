#!/usr/bin/env python3
"""List cores by how free they are: pinned threads (from /proc/*/task/*/status
Cpus_allowed_list), busy percentage over a 1 s sample (/proc/stat), and the
SMT sibling (/sys topology). A core is free when neither it nor its sibling
has a pinned process and both were under 20% busy."""
import glob, os, time

ncpu = os.cpu_count()

def parse(lst):
    cpus = set()
    for part in lst.split(','):
        a, _, b = part.partition('-')
        cpus.update(range(int(a), int(b or a) + 1))
    return cpus

def sibling(c):
    path = f'/sys/devices/system/cpu/cpu{c}/topology/thread_siblings_list'
    return parse(open(path).read().strip()) - {c}

pinned = {c: [] for c in range(ncpu)}
for status in glob.glob('/proc/[0-9]*/task/[0-9]*/status'):
    try:
        fields = dict(l.split(':\t', 1) for l in open(status) if ':\t' in l)
        allowed = parse(fields['Cpus_allowed_list'].strip())
    except (OSError, KeyError, ValueError):
        continue
    if fields.get('Kthread', '0').strip() == '1' or fields.get('PPid', '').strip() == '2':
        continue
    if len(allowed) < ncpu:
        name = fields['Name'].strip()
        for c in allowed:
            pinned[c].append(f"{status.split('/')[2]}/{status.split('/')[4]}:{name}")

def sample():
    out = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3].isdigit():
            f = l.split()
            vals = list(map(int, f[1:]))
            out[int(f[0][3:])] = (sum(vals), vals[3] + vals[4])
    return out

a = sample(); time.sleep(1); b = sample()
busy = {c: 100 * (1 - (b[c][1] - a[c][1]) / max(1, b[c][0] - a[c][0])) for c in a}

for c in range(ncpu):
    sib = sibling(c)
    free = not pinned[c] and all(not pinned[s] for s in sib) and busy[c] < 20 \
        and all(busy[s] < 20 for s in sib)
    print(f"cpu{c:<3} sib {','.join(map(str, sorted(sib))):<4} busy {busy[c]:5.1f}%  "
          f"{'FREE' if free else '    '}  {' '.join(pinned[c][:4])}")

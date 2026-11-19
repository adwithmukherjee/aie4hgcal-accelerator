"""Fail before a large platform job if the build VM lacks memory/disk headroom."""
import argparse,json,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('build',type=Path);p.add_argument('--min-memory-gib',type=float,default=16);p.add_argument('--min-disk-gib',type=float,default=6);a=p.parse_args()
mem={line.split(':',1)[0]:int(line.split()[1])*1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith(('MemTotal:','MemAvailable:'))}
root=a.build.resolve()
while not root.exists():root=root.parent
free=shutil.disk_usage(root).free
record=dict(available_memory_gib=round(mem['MemAvailable']/2**30,2),free_disk_gib=round(free/2**30,2),minimum_memory_gib=a.min_memory_gib,minimum_disk_gib=a.min_disk_gib)
print(json.dumps(record),flush=True)
if mem['MemAvailable']<a.min_memory_gib*2**30 or free<a.min_disk_gib*2**30:
 raise SystemExit('Insufficient headroom: wait for other work to finish before starting another platform job.')

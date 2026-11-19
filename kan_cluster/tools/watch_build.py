"""Run one FPGA build with a shared lock, live resource records and early stops.

Use a systemd MemoryMax scope/service as a separate hard containment limit.
This monitor stops earlier on low system headroom, anonymous job memory or disk.
Only processes belonging to this command are terminated by the monitor.
"""
import argparse,atexit,csv,fcntl,json,os,shutil,signal,subprocess,time
from pathlib import Path

GIB=2**30

def memory_available():
 for line in Path('/proc/meminfo').read_text().splitlines():
  if line.startswith('MemAvailable:'):return int(line.split()[1])*1024
 raise RuntimeError('MemAvailable unavailable')

def processes():
 result={}
 for path in Path('/proc').iterdir():
  if not path.name.isdigit():continue
  try:
   fields=(path/'stat').read_text().rsplit(')',1)[1].split()
   result[int(path.name)]=dict(ppid=int(fields[1]),pgid=int(fields[2]),
     start=int(fields[19]),rss=int(fields[21])*os.sysconf('SC_PAGE_SIZE'))
  except (FileNotFoundError,ProcessLookupError,PermissionError):pass
 return result

def cgroup_memory():
 for line in Path('/proc/self/cgroup').read_text().splitlines():
  _,controllers,group=line.split(':',2)
  if 'memory' in controllers.split(','):
   base=Path('/sys/fs/cgroup/memory')/group.lstrip('/')
   stats=dict(row.split() for row in (base/'memory.stat').read_text().splitlines())
   return dict(cgroup=str(base),cgroup_bytes=int((base/'memory.usage_in_bytes').read_text()),
     cgroup_limit_bytes=int((base/'memory.limit_in_bytes').read_text()),
     cgroup_anon_bytes=int(stats.get('total_rss',stats['rss'])),
     cgroup_failcnt=int((base/'memory.failcnt').read_text()))
 return {}

def write_state(path,state):
 temporary=path.with_suffix('.tmp');temporary.write_text(json.dumps(state,indent=2)+'\n');temporary.replace(path)

def terminate_owned(process,owned):
 # A separate session isolates the command from this watchdog and SSH.
 try:os.killpg(process.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 current=processes()
 for pid,start in owned.items():
  if pid in current and current[pid]['start']==start:
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
 deadline=time.monotonic()+3
 while process.poll() is None and time.monotonic()<deadline:time.sleep(.1)
 try:os.killpg(process.pid,signal.SIGKILL)
 except ProcessLookupError:pass
 current=processes()
 for pid,start in owned.items():
  if pid in current and current[pid]['start']==start:
   try:os.kill(pid,signal.SIGKILL)
   except ProcessLookupError:pass
 process.wait()

def main():
 p=argparse.ArgumentParser()
 p.add_argument('--build',type=Path,required=True);p.add_argument('--lock',type=Path,required=True)
 p.add_argument('--reserve-memory-gib',type=float,default=6)
 p.add_argument('--max-anon-gib',type=float,default=22)
 p.add_argument('--min-free-disk-gib',type=float,default=2)
 p.add_argument('--start-memory-gib',type=float,default=20)
 p.add_argument('--start-disk-gib',type=float,default=10)
 p.add_argument('--interval',type=float,default=1)
 p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
 command=a.command[1:] if a.command[:1]==['--'] else a.command
 if not command:p.error('Specify a command after --')
 if a.interval<=0:p.error('interval must be positive')
 a.build.mkdir(parents=True,exist_ok=True);a.lock.parent.mkdir(parents=True,exist_ok=True)
 lock=a.lock.open('a+')
 try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:raise SystemExit('Another guarded FPGA build holds the lock')
 heavy={'vivado','v++','vitis_hls','aiecompiler','aieir_be','xsim','xsimk'}
 for pid in processes():
  try:name=Path(f'/proc/{pid}/comm').read_text().strip()
  except (FileNotFoundError,ProcessLookupError,PermissionError):continue
  if name in heavy:raise SystemExit(f'Existing heavy process {pid} ({name}); start no parallel build')
 available=memory_available();disk=shutil.disk_usage(a.build).free
 if available<a.start_memory_gib*GIB or disk<a.start_disk_gib*GIB:
  raise SystemExit(f'Insufficient initial headroom: RAM {available/GIB:.2f} GiB; disk {disk/GIB:.2f} GiB')
 state=dict(status='starting',command=command,watchdog_pid=os.getpid(),
  policy=dict(reserve_memory_gib=a.reserve_memory_gib,max_anon_gib=a.max_anon_gib,
   min_free_disk_gib=a.min_free_disk_gib,sample_seconds=a.interval),
  started_unix=time.time(),minimum_available_bytes=available,minimum_free_disk_bytes=disk,
  peak_tree_rss_bytes=0,peak_cgroup_bytes=0,peak_cgroup_anon_bytes=0)
 state_path=a.build/'guard-state.json';owned={};interrupted=[]
 for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda signum,frame:interrupted.append(signum))
 with (a.build/'build-driver.log').open('a',buffering=1) as log, (a.build/'memory.csv').open('w',newline='',buffering=1) as output:
  process=subprocess.Popen(command,cwd=a.build,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  atexit.register(lambda:terminate_owned(process,owned) if process.poll() is None else None)
  state.update(status='running',build_pid=process.pid)
  writer=csv.DictWriter(output,fieldnames=['unix','available_bytes','free_disk_bytes','tree_rss_bytes','cgroup_bytes','cgroup_anon_bytes','processes'])
  writer.writeheader();last_record=0;reason=None;initial_failcnt=cgroup_memory().get('cgroup_failcnt',0)
  while True:
   table=processes();members={process.pid}
   changed=True
   while changed:
    children={pid for pid,info in table.items() if info['ppid'] in members}
    changed=not children.issubset(members);members|=children
   for pid in members:
    if pid in table:owned[pid]=table[pid]['start']
   current={pid for pid,start in owned.items() if pid in table and table[pid]['start']==start}
   rss=sum(table[pid]['rss'] for pid in current)
   available=memory_available();disk=shutil.disk_usage(a.build).free;group=cgroup_memory()
   state.update(last_sample_unix=time.time(),available_bytes=available,free_disk_bytes=disk,
    tree_rss_bytes=rss,process_count=len(current),**group)
   state['minimum_available_bytes']=min(state['minimum_available_bytes'],available)
   state['minimum_free_disk_bytes']=min(state['minimum_free_disk_bytes'],disk)
   state['peak_tree_rss_bytes']=max(state['peak_tree_rss_bytes'],rss)
   state['peak_cgroup_bytes']=max(state['peak_cgroup_bytes'],group.get('cgroup_bytes',0))
   state['peak_cgroup_anon_bytes']=max(state['peak_cgroup_anon_bytes'],group.get('cgroup_anon_bytes',0))
   if available<a.reserve_memory_gib*GIB:reason='system memory reserve reached'
   if group.get('cgroup_anon_bytes',0)>a.max_anon_gib*GIB:reason='anonymous build memory threshold reached'
   if disk<a.min_free_disk_gib*GIB:reason='disk reserve reached'
   if interrupted:reason='watchdog interrupted'
   if time.monotonic()-last_record>=5 or reason or process.poll() is not None:
    writer.writerow(dict(unix=time.time(),available_bytes=available,free_disk_bytes=disk,tree_rss_bytes=rss,
      cgroup_bytes=group.get('cgroup_bytes',''),cgroup_anon_bytes=group.get('cgroup_anon_bytes',''),processes=len(current)))
    output.flush();write_state(state_path,state);last_record=time.monotonic()
   if reason:
    print('Stopping this build: '+reason,flush=True);terminate_owned(process,owned);break
   if process.poll() is not None:break
   time.sleep(a.interval)
  code=process.wait()
  state.update(status='resource_stopped' if reason else ('passed' if code==0 else 'failed'),
   reason=reason,exit_code=code,finished_unix=time.time(),
   cgroup_failcnt_increase=group.get('cgroup_failcnt',0)-initial_failcnt)
  write_state(state_path,state)
  print(json.dumps(state,indent=2),flush=True)
 return 75 if reason else code

if __name__=='__main__':raise SystemExit(main())

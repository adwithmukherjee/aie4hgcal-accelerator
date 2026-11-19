"""Stage an unchanged, qualified 32-tile AIE archive and its exact packet routes."""
import argparse,hashlib,json,shutil,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('build',type=Path);a=p.parse_args()
r=json.loads((a.archive/'provenance.json').read_text());assert r['source_commit']=='42546581b4cbf7ac4db8fc55b7284ba2b0363b50'
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
record={}
source=Path(__file__).resolve().parents[2]
source_archive=a.archive/'source.tar.gz'
assert digest(source_archive)==r['sha256']['source.tar.gz']
with tarfile.open(source_archive,'r:gz') as archive:
 for name in ('array/graph.cpp','array/kernel.cpp','array/assignment.hpp','aie/density_core.hpp'):
  archived=archive.extractfile(name).read()
  assert (source/name).read_bytes()==archived,('AIE source changed; rebuild the archive',name)
  record[name]=dict(sha256=hashlib.sha256(archived).hexdigest(),source=str(source_archive))
for name,destination in [('libadf.a','libadf.a'),('route_headers.bin','config/route_headers.bin'),('output_ids.bin','config/output_ids.bin'),('packet_map.json','config/packet_map.json')]:
 matches=[k for k in r['sha256'] if k.endswith('/'+name)];assert len(matches)==1,(name,matches)
 path=a.archive/matches[0];assert digest(path)==r['sha256'][matches[0]]
 out=a.build/destination;out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,out)
 record[destination]=dict(sha256=digest(out),source=str(path))
(a.build/'config/aie-reuse.json').write_text(json.dumps(dict(source_commit=r['source_commit'],files=record),indent=2)+'\n')
print('Verified and staged the qualified 32-tile AIE binary and packet routes')

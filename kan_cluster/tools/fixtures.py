"""Prepare register-resident raw events and exact clustering oracles outside Git.

Inputs are the archived packed real events and manifests from the existing AIE
benchmark, plus the SHA256-pinned epoch-6 KAN tables. No cluster access needed.
"""
import argparse,hashlib,importlib.util,json,re,tarfile
from pathlib import Path
import numpy as np

def sha(x):return hashlib.sha256(x).hexdigest()
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def unpack(block,record,layout):
 result={};offset=0
 for field in layout:
  kind=field['kind'];dtype=np.dtype(field['dtype'])
  if kind=='identity':dtype=np.dtype(f'<U{record["id_chars"]}');shape=()
  elif kind=='features':shape=(record['cells'],5)
  elif kind=='scalar':shape=()
  else:shape=(record[kind],)
  result[field['name']]=np.ndarray(shape,dtype=dtype,buffer=block,offset=offset)
  offset+=result[field['name']].nbytes
 assert offset==len(block)
 return result

def mem(path,values,width):path.write_text(''.join(f'{int(v):0{width}x}\n' for v in values))

def main():
 p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('real_manifest',type=Path);p.add_argument('cluster_manifest',type=Path);p.add_argument('cuts',type=Path);p.add_argument('tables',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
 source=Path(__file__).resolve().parents[2]
 encoder=module('encoder_export',source/'kan/tools/export.py')
 oracle=module('cluster_oracle',source/'array/tools/clustering_reference.py')
 assert sha(a.tables.read_bytes())==encoder.SHA256
 rm=json.loads(a.real_manifest.read_text());cm=json.loads(a.cluster_manifest.read_text())
 assert sha(a.archive.read_bytes())==rm['source_archive_sha256']
 with np.load(a.tables,allow_pickle=False) as z:tables=[z['table_0'],z['table_1']]
 cuts=np.array(sorted(int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)u',a.cuts.read_text())),dtype=np.uint32)
 assert len(cuts)==255 and len(set(cuts))==255
 a.output.mkdir(parents=True,exist_ok=True);events=[]
 with tarfile.open(a.archive,'r:gz') as tar:
  layout=json.loads(tar.extractfile('index.json').read())['layout']
  for prior in rm['fixtures']:
   event=prior['index'];meta=json.loads(tar.extractfile(f'{event}.json').read());block=tar.extractfile(f'{event}.bin').read()
   assert sha(block)==meta['packed_record_sha256']
   raw=unpack(block,meta['record'],layout)['_x'];n=len(raw)
   wire=np.stack((np.floor(raw[:,0]).astype(np.int8).view(np.uint8),np.floor(raw[:,1]).astype(np.int8).view(np.uint8),raw[:,4].astype(np.uint8),np.searchsorted(cuts,raw[:,3].copy().view(np.uint32)&0x7fffffff,side='right').astype(np.uint8)),axis=1)
   embedded=encoder.reference(wire,tables);assert sha(embedded.tobytes())==prior['full_embeddings_sha256']
   old=next(e for e in cm['events'] if e['identity']==event)
   lm=old['landmark_ids'];assert lm==[j*n//128 for j in range(128)]
   priority=list(lm);seen=set(priority)
   for i in range(640):
    if i not in seen:priority.append(i);seen.add(i)
   selected_prefix=len(priority)
   for i in range(n):
    if len(priority)==8000:break
    if i not in seen:priority.append(i);seen.add(i)
   padding=8000-len(priority);ids=np.array(priority+[0xffffffff]*padding,dtype=np.uint32)
   words=np.zeros((8000,4),dtype=np.uint8);words[:len(priority)]=wire[priority]
   golden=encoder.reference(words,tables)
   by_id={int(v):i for i,v in enumerate(ids) if v!=0xffffffff}
   payload=golden[[by_id[i] for i in range(640)]].tobytes()+golden[[by_id[i] for i in lm]].tobytes()
   assert sha(payload)==old['payload_sha256']
   roles=np.zeros(((selected_prefix+63)//64)*64,dtype=np.uint32);lm_slot={i:j for j,i in enumerate(lm)}
   for slot,original in enumerate(priority[:selected_prefix]):
    if original<640:roles[slot]|=(1<<17)|original
    if original in lm_slot:roles[slot]|=(1<<18)|(lm_slot[original]<<10)
   out=a.output/f'event-{event:05d}';out.mkdir(exist_ok=True)
   mem(out/'wire.mem',words.view('<u4').reshape(-1),8);mem(out/'roles.mem',roles,8);mem(out/'original_ids.mem',ids,8);mem(out/'landmark_ids.mem',lm,8)
   mem(out/'expected.mem',golden.view('<u8').reshape(-1),16)
   (out/'wire.bin').write_bytes(words.tobytes());(out/'roles.bin').write_bytes(roles.astype('<u4').tobytes());(out/'payload.bin').write_bytes(payload)
   (out/'landmark_ids.bin').write_bytes(np.asarray(lm,dtype='<u4').tobytes())
   references={str(int(forced)):oracle.reference(payload,lm,forced) for forced in (False,True)}
   (out/'reference.json').write_text(json.dumps(references,indent=2)+'\n')
   mem(out/'payload.mem',np.frombuffer(payload,dtype='<u4'),8)
   tile_counts=[]
   hit_values=golden[[by_id[i] for i in range(640)]].astype(np.int64)
   lm_values=golden[[by_id[i] for i in lm]].astype(np.int64)
   for tile in range(32):
    d=((hit_values[tile*20:(tile+1)*20,None,:]-lm_values[None,:,:])**2).sum(2)
    counts=(d<=645).sum(0).astype(np.uint8)
    tile_counts.extend(counts.view('<u4').tolist())
   mem(out/'tile_counts.mem',tile_counts,8)
   for forced in (False,True):
    ref=references[str(int(forced))];seeds=ref['seed_slots'];seed_ids=ref['seed_hit_ids']
    packed_seeds=np.frombuffer(bytes(seeds+[0]*(64-len(seeds))),dtype='<u4').tolist()
    packed_labels=np.frombuffer(bytes(ref['labels']),dtype='<u4').tolist()
    cluster_words=ref['density']+[ref['seed_count'],int(ref['seed_overflow'])]+packed_seeds+seed_ids+[0]*(64-len(seed_ids))+packed_labels
    assert len(cluster_words)==370
    mem(out/('cluster_forced.mem' if forced else 'cluster_normal.mem'),cluster_words,8)
   events.append(dict(identity=event,full_event_hits=n,encoded_slots=8000,distinct_real_hits=len(priority),padding_slots=padding,priority_slots=selected_prefix,role_words=len(roles),aie_hits=640,landmarks=128,payload_sha256=sha(payload),raw_sha256=sha(words.tobytes()),expected_sha256=sha(golden.tobytes()),normal_seed_count=references['0']['seed_count']))
 manifest=dict(tables_sha256=encoder.SHA256,kind='8000 register-resident raw slots to 640-hit unchanged AIE clustering',raw_order='128 fixed full-event landmark IDs first, then remaining hits 0..639, then remaining original IDs; explicit zero padding for short events',sampling_scope='Fixed landmark selection and raw load ordering configured before release; all KAN computation and all transport after release',events=events)
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
if __name__=='__main__':main()

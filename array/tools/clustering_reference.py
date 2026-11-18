"""Independent scalar CPU oracle; no hardware scheduling or cached-layout logic."""
import argparse,json,random,struct
from pathlib import Path

def squared(a,b): return sum((int(x)-int(y))**2 for x,y in zip(a,b))
def select(landmarks,density,ids,force_64=False):
    order=sorted(range(128),key=lambda i:(-density[i],ids[i]))
    if force_64:return order[:64],64
    seeds=[]; overflow=0
    for i in order:
        if 5*density[i]<max(density): continue
        if all(squared(landmarks[i],landmarks[j])>=3267 for j in seeds):
            if len(seeds)<64:seeds.append(i)
            else:overflow+=1
    return seeds,overflow

def reference(frame,ids,force_64=False):
    values=struct.unpack('6144b',frame)
    hits=[values[i:i+8] for i in range(0,5120,8)]
    landmarks=[values[i:i+8] for i in range(5120,6144,8)]
    density=[sum(squared(h,r)<=645 for h in hits) for r in landmarks]
    seeds,overflow=select(landmarks,density,ids,force_64)
    labels=[min(range(len(seeds)),key=lambda s:squared(h,landmarks[seeds[s]])) for h in hits]
    return dict(density=density,seed_slots=seeds,seed_hit_ids=[ids[i] for i in seeds],
                seed_count=len(seeds),seed_overflow=bool(overflow),labels=labels)

def packed(values):
    return list(struct.unpack('<%dI'%(len(values)//4),bytes(values)))
def write_mem(path,values): path.write_text(''.join(f'{int(x)&0xffffffff:08x}\n' for x in values))
def prepare(data,out,force_64=False):
    out.mkdir(parents=True,exist_ok=True)
    frames=(data/'payloads.bin').read_bytes(); manifest=json.loads((data/'manifest.json').read_text())
    results=[];ids_words=[];golden=[]
    for e,event in enumerate(manifest['events']):
        ids=event['landmark_ids'];assert all(a<b for a,b in zip(ids,ids[1:]))
        result=reference(frames[e*6144:(e+1)*6144],ids,force_64);results.append(result);ids_words+=ids
        seeds=result['seed_slots'];hit_ids=result['seed_hit_ids']
        golden+=result['density']+[len(seeds),int(result['seed_overflow'])]+packed(seeds+[0]*(64-len(seeds)))+hit_ids+[0]*(64-len(seeds))+packed(result['labels'])
    suffix='-force64' if force_64 else ''
    (out/f'expected-clustering{suffix}.json').write_text(json.dumps(results,indent=2)+'\n')
    (out/'landmark_ids.bin').write_bytes(struct.pack('<%dI'%len(ids_words),*ids_words))
    write_mem(out/'landmark_ids.mem',ids_words);write_mem(out/f'cluster_expected{suffix}.mem',golden)
    # Deterministic boundary, duplicate, signed-extreme, all-zero, cap and random cases.
    rng=random.Random(20261118)
    cases=[]
    cases.append(([[0]*8 for _ in range(128)],[0]*128))
    fraction_lm=[[0]*8 for _ in range(128)]
    fraction_lm[1]=[127,0,0,0,0,0,0,0];fraction_lm[2]=[-128,0,0,0,0,0,0,0];fraction_lm[3]=[0,127,0,0,0,0,0,0]
    cases.append((fraction_lm,[640,127,128,129]+[0]*124))
    cases.append(([[127 if i>>d&1 else -128 for d in range(8)] for i in range(128)],[100]*128))
    # 57^2+4^2+1^2+1^2=3267; removing the last 1 gives 3266.
    lm=[[0]*8 for _ in range(128)];lm[1]=[57,4,1,1,0,0,0,0];lm[2]=[57,4,1,0,0,0,0,0]
    cases.append((lm,[100,99,98]+[0]*125))
    below=[[0]*8 for _ in range(128)];below[1]=[57,4,1,0,0,0,0,0]
    cases.append((below,[100,99]+[0]*126))
    for _ in range(11):
        cases.append(([[rng.randint(-128,127) for _ in range(8)] for _ in range(128)], [rng.randint(0,640) for _ in range(128)]))
    tests=[]
    for lm,rho in cases:
        ids=[i*61 for i in range(128)]
        raw=bytes(x&255 for row in lm for x in row)
        for forced in (False,True):
            seeds,overflow=select(lm,rho,ids,forced)
            tests+=[int(forced)]+rho+list(struct.unpack('<256I',raw))+ids+[len(seeds),int(bool(overflow))]+seeds+[0]*(64-len(seeds))+[ids[i] for i in seeds]+[0]*(64-len(seeds))
    write_mem(out/'seed_cases.mem',tests)
    print(json.dumps(dict(events=len(results),force_64=force_64,seed_counts=[r['seed_count'] for r in results],seed_unit_cases=2*len(cases),seed_case_words=643)))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('data',type=Path);p.add_argument('output',type=Path);p.add_argument('--force-64',action='store_true');a=p.parse_args();prepare(a.data,a.output,a.force_64)

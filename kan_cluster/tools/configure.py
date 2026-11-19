"""Reuse the qualified four-column routes with a new raw-input PL kernel."""
import argparse,json,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('build',type=Path);p.add_argument('--target',choices=('hw','hw_emu'),default='hw_emu');p.add_argument('--jobs',type=int,choices=(1,2),default=1);p.add_argument('--threads',type=int,choices=(1,2),default=2);a=p.parse_args()
source=Path(__file__).resolve().parents[2]
subprocess.run([sys.executable,str(source/'array/tools/configure.py'),str(a.build),'4'],check=True)
c=a.build/'config';s=(c/'array_pl.sv').read_text().replace('module array_pl','module kan_cluster_pl').replace('[15:0] s_axi_control_awaddr','[17:0] s_axi_control_awaddr').replace('[15:0] s_axi_control_araddr','[17:0] s_axi_control_araddr').replace('array_control #(.COLUMNS(4)) core','kan_cluster_control core')
(c/'kan_cluster_pl.sv').write_text(s)
p=c/'kernel.xml';s=p.read_text().replace('array_pl','kan_cluster_pl').replace('range="0x10000"','range="0x40000"');p.write_text(s)
p=c/'connectivity.cfg';p.write_text(p.read_text().replace('array_pl','kan_cluster_pl').replace('synth.jobs=2',f'synth.jobs={a.jobs}').replace('impl.jobs=2',f'impl.jobs={a.jobs}').replace('general.maxThreads=2',f'general.maxThreads={a.threads}'))
p=c/'experiment.json';r=json.loads(p.read_text());r.update(encoder_lanes=64,raw_hits=8000,aie_hits=640,role_prefix_slots=768,raw_storage='registers',capture_all_embeddings=True,streaming='per-bank availability; no event-wide embedding barrier',timer='raw release through final AIE label stored, includes all8000 encodings',landmark_sampling='fixed IDs configured before release; landmark embeddings computed inside timer');p.write_text(json.dumps(r,indent=2)+'\n')
r.update(build_target=a.target,vivado_jobs=a.jobs,vivado_threads=a.threads);p.write_text(json.dumps(r,indent=2)+'\n')

"""Verify the packaged graph and retain hashes of the measured system."""
import hashlib,json,subprocess,sys
import xml.etree.ElementTree as ET
from pathlib import Path
build=Path(sys.argv[1]).resolve()
experiment=json.loads((build/'config/experiment.json').read_text())
columns=experiment['columns']
metadata=build/'system/packaged-aie.json'
result=subprocess.run(['xclbinutil','--input',str(build/'system/array.xclbin'),
    '--dump-section','AIE_METADATA:JSON:'+str(metadata),'--force'],
    text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(build/'system/metadata.log').write_text(result.stdout)
result.check_returncode()
embedded=build/'system/embedded_metadata.xml'
subprocess.run(['xclbinutil','--input',str(build/'system/array.xclbin'),
    '--dump-section','EMBEDDED_METADATA:RAW:'+str(embedded),'--force'],
    check=True,stdout=subprocess.DEVNULL)
kernel=ET.parse(embedded).getroot().find(".//kernel[@name='array_pl']")
assert kernel is not None
port=kernel.find("port[@name='s_axi_control']")
segments=kernel.findall("instance/addrRemap[@port='s_axi_control']")
assert len(segments)==1 and int(port.get('range'),0)==65536
control_base=int(segments[0].get('base'),0);control_range=int(segments[0].get('range'),0)
assert control_base%65536==0 and control_range==65536,('Control aperture mismatch',control_base,control_range)
aie=json.loads(metadata.read_text())['aie_metadata']
graphs=list(aie['graphs'].values())
assert len(graphs)==1 and graphs[0]['name']=='array_graph'
graph=graphs[0]
cores=sorted(zip(map(int,graph['core_columns']),map(int,graph['core_rows'])))
assert cores==[(c,r) for c in range(24,24+columns) for r in range(8)],cores
codegen=json.loads((build/'aie/codegen.json').read_text())
assert codegen['status']=='passed' and codegen['columns']==columns
assert len(codegen['plio'])==2*columns
ports=sorted((port['logical_name'],int(port['shim_column']),int(port['slaveOrMaster']),int(port['stream_id']))
    for port in aie['PLIOs'].values())
assert ports==sorted((f'array_{direction}_{c}',24+c,mode,0)
    for c in range(columns) for direction,mode in [('input',0),('output',1)]),ports
def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()
record=dict(status='passed',columns=columns,cores=cores,interface=codegen['plio'],
    control_base=control_base,control_range=control_range,
    hashes={name:digest(build/name) for name in
        ['system/array.xsa','system/array.xclbin','libadf.a','array_pl.xo','array_host']})
(build/'system/package-interface.json').write_text(json.dumps(record,indent=2)+'\n')
print('Verified packaged graph:',columns,'columns,',len(cores),'workers')

"""Require an unchanged physical PL/AIE interface before reusing a linked XSA."""
import hashlib, json, subprocess, sys
from pathlib import Path

linked, build = map(Path,sys.argv[1:3])

def interface(path):
    report = json.loads(path.read_text())
    ports = []
    for key, value in report['mapping']['blockInstanceMapping'].items():
        if 'plioInfo' not in value:
            continue
        instance = report['blockInstances'][key]
        ports.append(dict(name=instance['logicalName'],width=instance['dataWidth'],
                          frequency_mhz=instance['plFreq'],**value['plioInfo']))
    assert len(ports)==2
    return sorted(ports,key=lambda port:port['name'])

original = interface(linked/'system/linked-aie-compiler-report.json')
current = interface(build/'aie/Work/reports/compiler_report.json')
assert current==original,('PL/AIE interface changed; link a new system',original,current)
def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''):
            result.update(chunk)
    return result.hexdigest()
record=dict(status='passed',interface=current,linked_build=str(linked.resolve()),
            linked_xsa_sha256=digest(linked/'system/column.xsa'),
            aie_archive_sha256=digest(build/'libadf.a'))
if '--packaged' in sys.argv[3:]:
    metadata=build/'system/packaged-aie.json'
    result=subprocess.run(['xclbinutil','--input',str(build/'system/column.xclbin'),
                           '--dump-section','AIE_METADATA:JSON:'+str(metadata),'--force'],
                          text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (build/'system/metadata.log').write_text(result.stdout)
    result.check_returncode()
    aie=json.loads(metadata.read_text())['aie_metadata']
    tiles=json.loads((build/'config/experiment.json').read_text())['tiles']
    graphs=list(aie['graphs'].values())
    assert len(graphs)==1 and graphs[0]['name']=='column_graph'
    assert list(map(int,graphs[0]['core_columns']))==[24]*tiles
    assert list(map(int,graphs[0]['core_rows']))==list(range(tiles))
    record.update(packaged_tiles=tiles,xclbin_sha256=digest(build/'system/column.xclbin'))
(build/'system/package-interface.json').write_text(json.dumps(record,indent=2)+'\n')
print('Verified unchanged PL/AIE interface for packaging')

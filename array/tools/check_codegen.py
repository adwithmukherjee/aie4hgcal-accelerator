"""Require local column routing and the qualified native kernel schedule."""
import json,re,sys
from pathlib import Path
from kernel_schedule import inspect_kernel
build=Path(sys.argv[1]).resolve()
experiment=json.loads((build/'config/experiment.json').read_text())
columns=experiment['columns'];wanted=set(range(24,24+columns))
compiler=json.loads((build/'aie/Work/reports/compiler_report.json').read_text())
cores=[v['coreInfo'] for v in compiler['mapping']['blockInstanceMapping'].values() if 'coreInfo' in v]
assert sorted((v['column'],v['row']) for v in cores)==[(c,r) for c in sorted(wanted) for r in range(8)]
for port in compiler['mapping']['portInstanceMapping'].values():
 for buf in port.get('bufferInfo',[]):assert buf['column'] in wanted and buf['row'] in range(8),buf
reports=[]
for col in sorted(wanted):
 for row in range(8):
  prefix=build/f'aie/Work/aie/{col}_{row}/Release/{col}_{row}'
  try:report=inspect_kernel(prefix.with_suffix('.lst').read_text(),prefix.with_suffix('.map').read_text())
  except AssertionError as error:raise AssertionError((col,row,str(error))) from error
  reports.append(dict(column=col,row=row,**report))
routes=json.loads((build/'aie/Work/temp/router_soln.json').read_text())
seen=set()
for name,net in routes.items():
 nodes={node for edge in net['tree'] for node in edge}
 cols={int(re.search(r'_C(\d+)',node)[1]) for node in nodes}
 assert len(cols)==1 and cols<=wanted,('Cross-column traffic',name,cols)
 seen|=cols
assert seen==wanted
ports=[]
for key,value in compiler['mapping']['blockInstanceMapping'].items():
 if 'plioInfo' in value:
  instance=compiler['blockInstances'][key]
  port=dict(name=instance['logicalName'],width=instance['dataWidth'],frequency_mhz=instance['plFreq'],**value['plioInfo'])
  assert port['width']==128 and port['frequency_mhz']==300 and port['column'] in wanted and port['channel']==0
  ports.append(port)
assert len(ports)==2*columns
result=dict(status='passed',columns=columns,physical_columns=sorted(wanted),
            independent_column_routes=True,tiles=reports,plio=ports)
(build/'aie/codegen.json').write_text(json.dumps(result,indent=2)+'\n')
print('Verified',len(reports),'workers, column-local routes and native loop schedules')

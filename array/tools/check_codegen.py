"""Require local column routing and the qualified native kernel schedule."""
import json,re,sys
from pathlib import Path
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
  text=(build/f'aie/Work/aie/{col}_{row}/Release/{col}_{row}.lst').read_text()
  assert not re.search(r'transpose_bits|zip_serial',text)
  symbols=[s for s in re.findall(r'^\.label (_Z\d+column_density\S*)$',text,re.M) if not s.endswith('__end')]
  assert len(symbols)==1
  symbol=symbols[0]
  kernel=text.split('.label '+symbol+'\n',1)[1].split('.label '+symbol+'__end',1)[0]
  assert not re.search(r'\bJAL\b',kernel)
  instructions=[line for line in kernel.splitlines() if re.match(r'\s+\d+\s+0x',line)]
  reads=[i for i,line in enumerate(instructions) if 'SS.' in line]
  headers=[i for i,line in enumerate(instructions) if 'PKTHD' in line]
  assert len(reads)>=3 and len(headers)==2 and headers[0]<reads[0]<headers[1]
  assert 'MS.' not in instructions[reads[0]]
  loops=[];assignment=[];label=None;body=[];at_end=False
  for line in kernel.splitlines():
   if line.startswith('.label ZLS_'):label=line.split()[1];body=[];at_end=False
   elif line.startswith('.label ZLE_') and label:at_end=True
   elif label and re.match(r'\s+\d+\s+0x',line):
    body.append(line)
    if at_end:
     if any('VMUL.48' in item for item in body) and any('VCMP' in item for item in body):
      loops.append(dict(scheduled_issue_bundles=len(body),explicit_spill_instructions=sum('SPIL' in item for item in body)))
     if not any('VMUL' in item for item in body) and any('VCMP' in item for item in body):
      assignment.append(dict(scheduled_issue_bundles=len(body),explicit_spill_instructions=sum('SPIL' in item for item in body)))
     label=None
  assert assignment and all(x['scheduled_issue_bundles']<=12 and x['explicit_spill_instructions']==0 for x in assignment),(col,row,assignment)
  assert len(loops)==2 and all(x['scheduled_issue_bundles']<=13 and x['explicit_spill_instructions']==0 for x in loops),(col,row,loops)
  reports.append(dict(column=col,row=row,distance_loops=loops,assignment_loops=assignment,density_before_seed_read_before_labels=True))
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

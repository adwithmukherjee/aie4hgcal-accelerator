"""Check every column worker's actual instruction schedule and placement."""
import json,re,sys
from pathlib import Path

build=Path(sys.argv[1]).resolve()
tiles=json.loads((build/'config/experiment.json').read_text())['tiles']
compiler=json.loads((build/'aie/Work/reports/compiler_report.json').read_text())
assert compiler['aie_driver_config']['aie_tile_num_rows']==8
cores=[v["coreInfo"] for v in compiler["mapping"]["blockInstanceMapping"].values() if "coreInfo" in v]
assert sorted((v["column"],v["row"]) for v in cores)==[(24,r) for r in range(tiles)], "Unexpected compute placement"
for port in compiler["mapping"]["portInstanceMapping"].values():
    for buffer in port.get("bufferInfo",[]):
        assert buffer["column"]==24 and buffer["row"] in range(tiles), buffer
reports=[]
for row in range(tiles):
    listing=build/f'aie/Work/aie/24_{row}/Release/24_{row}.lst'
    text=listing.read_text()
    assert not re.search(r'transpose_bits|zip_serial',text),(row,'Scalar reshape fallback')
    symbols=re.findall(r'^\.label (_Z\d+column_density\S*)$',text,re.M)
    symbols=[s for s in symbols if not s.endswith('__end')]
    assert len(symbols)==1,(row,symbols)
    symbol=symbols[0]
    kernel=text.split('.label '+symbol+'\n',1)[1].split('.label '+symbol+'__end',1)[0]
    assert not re.search(r'\bJAL\b',kernel),(row,'Out-of-line kernel call')
    instructions=[line for line in kernel.splitlines() if re.match(r'\s+\d+\s+0x',line)]
    reads=[i for i,line in enumerate(instructions) if 'SS.' in line]
    headers=[i for i,line in enumerate(instructions) if 'PKTHD' in line]
    assert len(reads)==1 and len(headers)==2,(row,reads,headers)
    assert headers[0]<reads[0]<headers[1],(row,'Matrix header moved before readback gate')
    assert 'MS.' not in instructions[reads[0]],(row,'Blocking read shares a stream-write issue bundle')
    loops=[];label=None;body=[];at_end=False
    for line in kernel.splitlines():
        if line.startswith('.label ZLS_'):
            label=line.split()[1];body=[];at_end=False
        elif line.startswith('.label ZLE_') and label:at_end=True
        elif label and re.match(r'\s+\d+\s+0x',line):
            body.append(line)
            if at_end:
                if any('VMUL.48' in item for item in body) and any('VCMP' in item for item in body):
                    loops.append(dict(label=label,scheduled_issue_bundles=len(body),
                                      explicit_spill_instructions=sum('SPIL' in item for item in body)))
                label=None
    assert len(loops)==2,(row,loops)
    assert all(loop['scheduled_issue_bundles']<=13 for loop in loops),(row,loops)
    assert all(loop['explicit_spill_instructions']==0 for loop in loops),(row,loops)
    reports.append(dict(column=24,row=row,distance_loops=loops,
                        density_before_gate_before_matrix=True))
configured=json.loads((build/'aie/Work/config/scsim_config.json').read_text())['SimulationConfig']
pl=[p for p in configured['pl_ip_block'] if p['name'] in ('column_input','column_output')]
assert len(pl)==2
for port in pl:
    assert port['pl_freq']==300000000
    assert all(x['column']==24 and x['bus_width']==128 for x in port['axi_stream']),port
routes=json.loads((build/"aie/Work/temp/router_soln.json").read_text())
route_nodes={node for net in routes.values() for edge in net["tree"] for node in edge}
route_columns=sorted({int(re.search(r"_C(\d+)",node)[1]) for node in route_nodes})
route_rows=sorted({int(m[1]) for node in route_nodes if (m:=re.search(r"_R(\d+)",node))})
assert route_columns==[24], ("Traffic left the measured column",route_columns)
assert route_rows==list(range(tiles)), ("Traffic left the active rows",route_rows)
result=dict(route_columns=route_columns,route_rows=route_rows,status='passed',tiles=reports,plio=pl,
            scope='Static compiler evidence; end-to-end latency requires the PL timer')
(build/'aie/codegen.json').write_text(json.dumps(result,indent=2)+'\n')
print('Passed native code and placement checks for',tiles,'workers')

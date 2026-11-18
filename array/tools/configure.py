"""Generate the physical ports and placement for parallel full columns."""
import json, sys
from pathlib import Path

build=Path(sys.argv[1]).resolve()
columns=int(sys.argv[2]);assert columns==4
config=build/'config';config.mkdir(parents=True,exist_ok=True)
(config/'experiment.json').write_text(json.dumps(dict(columns=columns,
    physical_columns=list(range(24,24+columns)),rows=list(range(8)),
    hits_per_tile=20,landmarks=128,dimensions=8,radius_squared=645,separation_squared=3267,density_fraction=[1,5],max_seeds=64,
    pl_hz=300000000,reduction_cycles=2 if columns==4 else 1),indent=2)+'\n')
(config/'constraints.json').write_text(json.dumps(dict(NodeConstraints={
    f'array_graph.worker[{c*8+r}]':dict(reserved_memory=dict(column=24+c,row=r,bankId=0,offset=256))
    for c in range(columns) for r in range(8)}),indent=2)+'\n')

control=[('input',1,'ap_clk'),('input',1,'ap_rst_n'),
 ('input',16,'s_axi_control_awaddr'),('input',1,'s_axi_control_awvalid'),('output',1,'s_axi_control_awready'),
 ('input',32,'s_axi_control_wdata'),('input',4,'s_axi_control_wstrb'),('input',1,'s_axi_control_wvalid'),('output',1,'s_axi_control_wready'),
 ('output',2,'s_axi_control_bresp'),('output',1,'s_axi_control_bvalid'),('input',1,'s_axi_control_bready'),
 ('input',16,'s_axi_control_araddr'),('input',1,'s_axi_control_arvalid'),('output',1,'s_axi_control_arready'),
 ('output',32,'s_axi_control_rdata'),('output',2,'s_axi_control_rresp'),('output',1,'s_axi_control_rvalid'),('input',1,'s_axi_control_rready')]
ports=list(control)
for c in range(columns):
 for direction,prefix in [('output',f'm_axis_tx_{c}'),('input',f's_axis_rx_{c}')]:
  for suffix,width in [('tdata',128),('tkeep',16),('tlast',1),('tvalid',1),('tready',1)]:
   mode=('input' if direction=='output' else 'output') if suffix=='tready' else direction
   ports.append((mode,width,prefix+'_'+suffix))
lines=['`timescale 1ns/1ps','module array_pl (',',\n'.join(
 f' {mode} wire '+(f'[{width-1}:0] ' if width>1 else '')+name for mode,width,name in ports),');']
for direction in ('tx','rx'):
 for suffix,width in [('data',128),('keep',16),('last',1),('valid',1),('ready',1)]:
  lines.append(f' wire [{columns*width-1}:0] {direction}_{suffix};')
  for c in range(columns):
   individual=f'{"m_axis_tx" if direction=="tx" else "s_axis_rx"}_{c}_t{suffix}'
   packed=f'{direction}_{suffix}[{c*width}+:{width}]'
   from_core=(direction=='tx') != (suffix=='ready')
   lines.append(f' assign {individual if from_core else packed}={packed if from_core else individual};')
connections=[f'.{name}({name})' for _,_,name in control]
connections += [f'.{d}_{s}({d}_{s})' for d in ('tx','rx') for s in ('data','keep','last','valid','ready')]
lines += [f' array_control #(.COLUMNS({columns})) core (',',\n'.join('  '+x for x in connections),');','endmodule']
(config/'array_pl.sv').write_text('\n'.join(lines)+'\n')

xml=['<?xml version="1.0" encoding="UTF-8"?>','<root versionMajor="1" versionMinor="9">',
'<kernel name="array_pl" language="ip" vlnv="hgcal.org:benchmark:array_pl:1.0" attributes="" preferredWorkGroupSizeMultiple="0" workGroupSize="1" hwControlProtocol="user_managed">','<ports>',
'<port name="s_axi_control" mode="slave" range="0x10000" dataWidth="32" portType="addressable" base="0x0"/>']
args=[]
for c in range(columns):
 for direction,prefix in [('write_only','m_axis_tx'),('read_only','s_axis_rx')]:
  port=f'{prefix}_{c}'
  xml.append(f'<port name="{port}" mode="{direction}" dataWidth="128" portType="stream"/>')
  args.append(f'<arg name="{port}" addressQualifier="4" id="{len(args)}" port="{port}" size="0x10" offset="0x0" hostOffset="0x0" hostSize="0x10" type="void*"/>')
args.append(f'<arg name="RELEASE" addressQualifier="0" id="{len(args)}" port="s_axi_control" size="0x4" offset="0x0" hostOffset="0x0" hostSize="0x4" type="unsigned int"/>')
xml += ['</ports>','<args>',*args,'</args>','</kernel>','</root>']
(config/'kernel.xml').write_text('\n'.join(xml)+'\n')
links=['[connectivity]','nk=array_pl:1:array_pl_1']
for c in range(columns):
 links += [f'stream_connect=array_pl_1.m_axis_tx_{c}:ai_engine_0.array_input_{c}',
           f'stream_connect=ai_engine_0.array_output_{c}:array_pl_1.s_axis_rx_{c}']
links+=['[vivado]','synth.jobs=2','impl.jobs=2','param=general.maxThreads=2']
(config/'connectivity.cfg').write_text('\n'.join(links)+'\n')

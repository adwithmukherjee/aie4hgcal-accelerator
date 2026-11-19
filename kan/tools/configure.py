"""Generate the fixed-lane user-managed VCK5000 benchmark kernel wrapper."""
import argparse,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('build',type=Path);p.add_argument('lanes',type=int);a=p.parse_args()
assert a.lanes in (1,2,4,8,16,32,64,128,256)
r=Path(__file__).resolve().parents[1];out=a.build/'config';out.mkdir(parents=True,exist_ok=True)
s=(r/'control.sv').read_text();ports=re.search(r'module kan_control.*?\((\n input wire ap_clk,.*?)\n\);',s,re.S).group(1)
(out/'kan_pl.sv').write_text('`timescale 1ns/1ps\nmodule kan_pl('+ports+'\n);\nkan_control #(.LANES('+str(a.lanes)+')) core(.*);\nendmodule\n')
(out/'kernel.xml').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<root versionMajor="1" versionMinor="9">
<kernel name="kan_pl" language="ip" vlnv="hgcal.org:benchmark:kan_pl:1.0" attributes="" preferredWorkGroupSizeMultiple="0" workGroupSize="1" hwControlProtocol="user_managed">
<ports><port name="s_axi_control" mode="slave" range="0x20000" dataWidth="32" portType="addressable" base="0x0"/></ports>
<args><arg name="RELEASE" addressQualifier="0" id="0" port="s_axi_control" size="0x4" offset="0x0" hostOffset="0x0" hostSize="0x4" type="unsigned int"/></args>
</kernel></root>
''')
(out/'connectivity.cfg').write_text('[connectivity]\nnk=kan_pl:1:kan_pl_1\n[vivado]\nsynth.jobs=2\nimpl.jobs=2\nparam=general.maxThreads=2\n')

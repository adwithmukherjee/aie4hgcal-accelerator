"""Reject scalar fallbacks and oversized scheduled loops before system linking."""
import json,re,sys
from pathlib import Path

build=Path(sys.argv[1])
listing=build/'aie/Work/aie/24_0/Release/24_0.lst'
text=listing.read_text()
assert not re.search(r'transpose_bits|zip_serial',text),'Scalar reshape fallback in generated code'
symbol='_Z16landmark_densityP12input_windowIiEP13output_streamIiE'
kernel=text.split('.label '+symbol+'\n',1)[1].split('.label '+symbol+'__end',1)[0]
assert not re.search(r'\bJAL\b',kernel),'Out-of-line call in the benchmark kernel'
loops=[];label=None;body=[];at_end=False
for line in kernel.splitlines():
    if line.startswith('.label ZLS_'):
        label=line.split()[1];body=[];at_end=False
    elif line.startswith('.label ZLE_') and label:
        # The hardware loop-end address is inclusive: its instruction bundle
        # still executes on every iteration, despite the preceding end label.
        at_end=True
    elif label and re.match(r'\s+\d+\s+0x',line):
        body.append(line)
        if at_end:
            if any('VMUL.48' in item for item in body) and any('VCMP' in item for item in body):
                loops.append(dict(label=label,scheduled_issue_bundles=len(body),
                                  explicit_spill_instructions=sum('SPIL' in item for item in body),
                                  stack_relative_loads=len(re.findall(
                                      r'\b(?:LDA|LDB|VLDA|VLDB)(?:\.\w+)?[^;\n]*\[sp[,\]]',
                                      '\n'.join(body)))))
            label=None
assert loops,'Distance loop not found in generated listing'
assert all(loop['scheduled_issue_bundles']<=13 for loop in loops),loops
assert all(loop['explicit_spill_instructions']==0 for loop in loops),loops
report=dict(status='passed',scalar_reshape_fallbacks=0,out_of_line_kernel_calls=0,
            distance_loops=loops,
            scope='Compiler issue schedule only; full event latency and runtime stalls require the PL timer')
(build/'aie/codegen.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))

"""Inspect the production density/assignment schedule, including one-tile probes."""
import re


def inspect_kernel(text, map_text):
    assert not re.search(r'transpose_bits|zip_serial', text), 'scalar shuffle helper'

    def function(pattern):
        names = [name for name in re.findall(r'^\.label (' + pattern + r')$', text, re.M)
                 if not name.endswith('__end')]
        assert len(names) == 1, (pattern, names)
        name = names[0]
        body = text.split('.label ' + name + '\n', 1)[1].split('.label ' + name + '__end', 1)[0]
        code = [line for line in body.splitlines() if re.match(r'\s+\d+\s+0x', line)]
        return name, body, code

    def calls(code):
        targets = []
        for line in code:
            if re.search(r'\bJAL\b', line):
                match = re.search(r'\bJAL #(\d+)', line)
                assert match, ('indirect/unrecognized call', line)
                targets.append(int(match[1]))
        return targets

    def loops(body):
        result = []
        active = None
        at_end = False
        for line in body.splitlines():
            if line.startswith('.label ZLS_'):
                active = []
                at_end = False
            # One-bundle hardware loops omit the separate ZLE label.
            elif (line.startswith('.label ZLE_') or line == '.end_of_loop') and active is not None:
                at_end = True
            elif active is not None and re.match(r'\s+\d+\s+0x', line):
                active.append(line)
                if at_end:
                    result.append(active)
                    active = None
        return result

    def describe(code):
        return dict(scheduled_issue_bundles=len(code),
                    explicit_spill_instructions=sum('SPIL' in line for line in code))

    kernel_name, kernel, instructions = function(r'_Z\d+column_density\S*')
    prepare_name, prepare, prepare_code = function(r'_ZN10assignmentL7prepare\S*')
    assign_name, assign, assign_code = function(r'_ZN10assignmentL6assign\S*')
    prepare_address = int(prepare_code[0].split()[0])
    assign_address = int(assign_code[0].split()[0])
    assert calls(instructions) == [prepare_address, assign_address], ('unexpected kernel calls', calls(instructions))
    assert not calls(assign_code) and not calls(prepare_code), 'assignment contains a helper call'
    reads = [i for i, line in enumerate(instructions) if 'SS.' in line]
    headers = [i for i, line in enumerate(instructions) if 'PKTHD' in line]
    preparation_call, assignment_call = [i for i, line in enumerate(instructions) if re.search(r'\bJAL\b', line)]
    assert len(reads) >= 3 and len(headers) == 2
    assert headers[0] < preparation_call < reads[0] <= reads[-1] < assignment_call < headers[1]
    assert 'MS.' not in instructions[reads[0]]

    density_loops = [code for code in loops(kernel)
                     if any('VMUL.48' in line for line in code)
                     and any('VCMP' in line for line in code)]
    assert len(density_loops) == 2, ('missing density loops', len(density_loops))
    assert all(len(code) <= 13 and not any('SPIL' in line for line in code)
               for code in density_loops), ('density schedule regression', list(map(describe, density_loops)))
    assignment_loops = [code for code in loops(assign)
                        if any('VCMP' in line for line in code)]
    assert len(assignment_loops) == 1, ('expected one 32-block scan loop', len(assignment_loops))
    scan = assignment_loops[0]
    assert len(scan) <= 4 and not any('SPIL' in line for line in scan), ('assignment schedule', describe(scan))
    assert sum('VCMP' in line for line in scan) >= 2, 'missing native key addition/minimum'
    preparation_loops = loops(prepare)
    assert len(preparation_loops) == 1, ('expected one distance scaling loop', len(preparation_loops))
    scaling = preparation_loops[0]
    assert len(scaling) == 1 and not any('SPIL' in line for line in scaling), ('scaling schedule', describe(scaling))
    assert any('UPSL' in line for line in scaling) and any('SRSL' in line for line in scaling), 'missing exact distance scaling'

    frames = {name: int(size) for name, size in re.findall(
        r'::(\S+) \(Function,[^\n]*stack frame size = (\d+)\)', map_text)}
    capacities = {int(end, 16) - int(start, 16) + 1 for start, end in re.findall(
        r'0x([0-9a-fA-F]+)\.\.0x([0-9a-fA-F]+) \([^\n]*\) : Stack', map_text)}
    assert len(capacities) == 1, capacities
    capacity = capacities.pop()
    # Sibling helpers are called sequentially; only the larger frame is live.
    path = ['_main', kernel_name, max((prepare_name,assign_name),key=lambda name:frames[name])]
    required = sum(frames[name] for name in path)
    assert required <= capacity, ('nested stack overflow', required, capacity)
    return dict(stack=dict(configured_bytes=capacity, maximum_call_path_bytes=required,
                           headroom_bytes=capacity-required,
                           call_path=[dict(function=name, frame_bytes=frames[name]) for name in path]),
                distance_loops=list(map(describe, density_loops)),
                assignment_loops=list(map(describe, assignment_loops)),
                scaling_loops=list(map(describe, preparation_loops)),
                assignment_function=describe(assign_code),
                scaling_function=describe(prepare_code),
                density_before_scaling_before_seed_read_before_assignment_before_labels=True)

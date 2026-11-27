"""Generate the 384 worker memory reservations for Vitis 2022.2."""
import json
import sys
from pathlib import Path

workers = {
    f'array_graph.worker[{8 * column + row}]': {
        'reserved_memory': {'column': column + 1, 'row': row, 'bankId': 0, 'offset': 256}
    }
    for column in range(48) for row in range(8)
}
Path(sys.argv[1]).write_text(json.dumps({'NodeConstraints': workers}))

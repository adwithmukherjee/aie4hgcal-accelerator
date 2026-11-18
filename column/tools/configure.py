"""Generate per-build AIE placement without editing source between tile counts."""
import json, sys
from pathlib import Path

build = Path(sys.argv[1]).resolve()
tiles = int(sys.argv[2])
assert tiles in (1, 2, 4, 8)
config = build/'config'
config.mkdir(parents=True, exist_ok=True)
(config/'constraints.json').write_text(json.dumps(dict(NodeConstraints={
    f'column_graph.worker[{r}]': dict(reserved_memory=dict(column=24,row=r,bankId=0,offset=256))
    for r in range(tiles)}), indent=2)+'\n')
(config/'experiment.json').write_text(json.dumps(dict(tiles=tiles,column=24,rows=list(range(tiles)),
    hits_per_tile=20,landmarks=128,radius_squared=645,pl_hz=300000000),indent=2)+'\n')

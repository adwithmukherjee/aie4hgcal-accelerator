"""Adversarial native-AIE qualification inputs, never performance fixtures."""
import random

SEED_COUNTS = (1,2,3,4,5,15,16,17,31,32,33,63,64)
ASSIGNMENT_CASE_COUNT = 5 + len(SEED_COUNTS)

def assignment_case(index):
    if index==0:
        hits=[[0]*8 for _ in range(640)]
        landmarks=[[i,0,0,0,0,0,0,0] for i in range(128)]
        seeds=list(range(127,63,-1))  # No selected seed in any top-32 list.
    elif index==1:
        hits=[[0]*8 for _ in range(640)]
        landmarks=[[0]*8 for _ in range(128)]
        seeds=[127]+list(range(63))  # Winning tie lies outside the shortlist.
    elif index==2:
        hits=[[0]*8 for _ in range(640)]
        landmarks=[[100]*8 for _ in range(128)]
        landmarks[3]=[0]*8;landmarks[7]=[0]*8
        seeds=[7,3]+list(range(64,126))  # Both tied winners are in the shortlist.
    elif index==3:
        rng=random.Random(20261118)
        hits=[[rng.choice([-128,127]) for _ in range(8)] for _ in range(640)]
        landmarks=[[rng.choice([-128,127]) for _ in range(8)] for _ in range(128)]
        seeds=rng.sample(range(128),64)
    elif index==4:
        # Unselected distance zero must lose to the maximum valid distance.
        hits=[[-128]*8 for _ in range(640)]
        landmarks=[[-128]*8 for _ in range(128)]
        seeds=list(range(127,63,-1))
        for slot in seeds:landmarks[slot]=[127]*8
    elif 5<=index<ASSIGNMENT_CASE_COUNT:
        rng=random.Random(20261118+index)
        hits=[[rng.randint(-128,127) for _ in range(8)] for _ in range(640)]
        landmarks=[[rng.randint(-128,127) for _ in range(8)] for _ in range(128)]
        seeds=rng.sample(range(128),SEED_COUNTS[index-5])
        if len(seeds)>1:
            landmarks[seeds[0]]=landmarks[seeds[-1]][:]
        for h in range(0,640,20):hits[h]=landmarks[seeds[0]][:]
    else:raise ValueError(index)
    frame=bytes(x&255 for row in hits+landmarks for x in row)
    return frame,seeds

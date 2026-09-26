#!/usr/bin/env python3
# GFS pruning for the Pterodactyl S3 backups.
# stdin : one backup timestamp per line (YYYYMMDDTHHMMSSZ)
# argv1 : "now" timestamp (the backup just taken)
# stdout: the timestamps that should be DELETED (caller runs `aws s3 rm` on each)
# env   : RETAIN_DAILY (def 7) / RETAIN_WEEKLY (def 5) / RETAIN_MONTHLY (def 6)
import os, sys
from datetime import datetime, timezone

now = datetime.strptime(sys.argv[1], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
D = int(os.environ.get("RETAIN_DAILY", "7"))
W = int(os.environ.get("RETAIN_WEEKLY", "5"))
M = int(os.environ.get("RETAIN_MONTHLY", "6"))

stamps = sorted({s.strip() for s in sys.stdin if s.strip()})
dts = sorted(
    ((datetime.strptime(s, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc), s) for s in stamps),
    reverse=True,
)
keep, seen_w, seen_m = set(), set(), set()
for dt, s in dts:
    age = (now - dt).days
    if age < D:                                   # recent: keep all
        keep.add(s)
    elif age < D + W * 7:                          # weekly tier
        wk = dt.isocalendar()[:2]
        if wk not in seen_w:
            seen_w.add(wk); keep.add(s)
    else:                                         # monthly tier (bounded by M)
        mo = (dt.year, dt.month)
        if mo not in seen_m and len(seen_m) < M:
            seen_m.add(mo); keep.add(s)
for _, s in dts:
    if s not in keep:
        print(s)

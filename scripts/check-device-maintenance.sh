#!/bin/sh
set -eu
# Input is the app preference plist exported after a Debug device run, not pairing data.
plutil -extract locationDebugEvents json -o - "$1" | python3 -c '
import json, sys, time
events = json.load(sys.stdin)
last_stop = max((i for i, event in enumerate(events) if " maintenanceStopped " in event), default=-1)
updates = [float(event.split()[0]) for event in events[last_stop + 1:] if " maintenanceSet " in event]
assert len(updates) >= 3, "Need three successful refreshes after the last stop"
assert all(3 <= b - a <= 8 for a, b in zip(updates, updates[1:])), "Refresh cadence interrupted"
assert abs(time.time() - updates[-1]) <= 12, "Refresh evidence is stale"
print("PASS: recent successful maintenance writes with no observed gap over 8 seconds; map position needs device confirmation")
'

#!/usr/bin/env python3
# Diagnose the latest SpringBoard crash report on a jailbroken device.
# Usage on the device:
#   sudo python3 /var/mobile/pp_diag.py
import json, sys, glob

paths = sorted(glob.glob('/var/mobile/Library/Logs/CrashReporter/SpringBoard-*.ips'))
if not paths:
    print("no SpringBoard crash logs in /var/mobile/Library/Logs/CrashReporter/")
    sys.exit(0)
path = paths[-1]
print("=== analyzing:", path)

raw = open(path).read()
parts = raw.split('\n', 1)
try:
    hdr = json.loads(parts[0])
except Exception:
    hdr = {}
body = json.loads(parts[1])

print("\n--- TERMINATION ---")
print(json.dumps(body.get('termination', {}), indent=2))

ps = body.get('stackshot', {}).get('processByPid', {})
print("\n--- TOP 12 BY RESIDENT MEMORY ---")
top = sorted(ps.values(), key=lambda p: -p.get('residentMemoryBytes', 0))[:12]
for p in top:
    mb = p.get('residentMemoryBytes', 0) // 1048576
    print(f"{mb:5d} MB  pid={p.get('pid'):5d}  {p.get('procname')}")

print("\n--- SpringBoard threads (main + high-prio) ---")
for pid, p in ps.items():
    if p.get('procname') != 'SpringBoard':
        continue
    print(f"SpringBoard pid={p.get('pid')} residentMB={p.get('residentMemoryBytes',0)//1048576}")
    threads = p.get('threadById', {})
    shown = 0
    for tid, t in threads.items():
        nm = t.get('name') or ''
        bp = t.get('basePriority', 0)
        sp = t.get('schedPriority', 0)
        if 'main' in nm.lower() or bp >= 46 or sp >= 46 or 'CA' in nm:
            print(f"\n  TID {tid} name={nm!r} basePri={bp} schedPri={sp} state={t.get('state')}")
            if t.get('waitInfo'): print("    waitInfo:", t['waitInfo'])
            if t.get('waitEvent'): print("    waitEvent:", t['waitEvent'])
            print("    userFrames:", t.get('userFrames', [])[:25])
            shown += 1
            if shown >= 8: break
    if shown == 0:
        for tid, t in list(threads.items())[:5]:
            print(f"\n  TID {tid} name={t.get('name')!r} state={t.get('state')}")
            print("    userFrames:", t.get('userFrames', [])[:15])
    break

print("\n--- BINARY IMAGES (looking for tweaks/dylibs) ---")
images = body.get('binaryImages') or body.get('binaryImageEntries') or []
if isinstance(images, dict):
    images = list(images.values())
hits = []
for img in images:
    if not isinstance(img, dict):
        continue
    name = img.get('name', '')
    p = img.get('path', '')
    blob = (name + ' ' + p).lower()
    if any(k in blob for k in ['pocket','liquid','glass','wallpaper','poster','substrate','elleekit','choicy','rocketbootstrap','dynamiclibraries']):
        hits.append((name, p))
for n, p in hits:
    print(f"  {n}  ({p})")
if not hits:
    print("  (no interesting dylibs in image list)")

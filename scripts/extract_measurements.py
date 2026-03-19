#!/usr/bin/env python3
"""Extract TDX measurements from a quote generated on this machine."""
import os

base = "/sys/kernel/config/tsm/report"
entry = os.path.join(base, "e2e-measure")
os.makedirs(entry, exist_ok=True)
with open(os.path.join(entry, "inblob"), "wb") as f:
    f.write(b"\x00" * 64)
with open(os.path.join(entry, "outblob"), "rb") as f:
    quote = f.read()
try:
    os.rmdir(entry)
except Exception:
    pass

body = 48
mrtd = quote[body + 136 : body + 184]
rtmr0 = quote[body + 328 : body + 376]
rtmr1 = quote[body + 376 : body + 424]
rtmr2 = quote[body + 424 : body + 472]

print(f"MRTD:{mrtd.hex()}")
print(f"RTMR0:{rtmr0.hex()}")
print(f"RTMR1:{rtmr1.hex()}")
print(f"RTMR2:{rtmr2.hex()}")

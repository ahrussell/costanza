#!/bin/bash
# Startup script for GCP TDX VM to generate a quote
apt-get update -qq && apt-get install -y -qq python3 2>/dev/null
python3 -c "
import os
base = '/sys/kernel/config/tsm/report'
if os.path.isdir(base):
    entry = os.path.join(base, 'fmspc-extract')
    os.makedirs(entry, exist_ok=True)
    with open(os.path.join(entry, 'inblob'), 'wb') as f:
        f.write(b'\x00' * 64)
    with open(os.path.join(entry, 'outblob'), 'rb') as f:
        quote = f.read()
    with open('/tmp/quote.hex', 'w') as f:
        f.write(quote.hex())
    try:
        os.rmdir(entry)
    except:
        pass
    print(f'Quote saved: {len(quote)} bytes')
else:
    print('No configfs-tsm found')
" > /tmp/quote_gen.log 2>&1

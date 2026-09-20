#!/usr/bin/env python3
"""Validate a RunPod key and store it locally without echoing it or renting compute."""
import getpass
import json
import os
from pathlib import Path
import re
import sys
import tempfile
if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def validate_key(key):
    # RunPod's edge rejects urllib's default Python-urllib User-Agent (1010).
    req = Request('https://rest.runpod.io/v1/pods', headers={
        'Authorization': 'Bearer ' + key,
        'User-Agent': 'costanza-research/1.0',
        'Accept': 'application/json',
    })
    try:
        with urlopen(req, timeout=30) as response:
            payload = json.load(response)
        if not isinstance(payload, list):
            raise ValueError('Unexpected Pods response')
    except HTTPError as error:
        # Inspect a bounded error body, but never print it or request headers:
        # upstream errors could echo sensitive information.
        body = error.read(4096).decode('utf-8', errors='replace')
        if error.code == 403 and 'error code: 1010' in body:
            message = 'RunPod blocked the HTTP client before key validation (edge error 1010). This does not indicate bad key permissions.'
        elif error.code == 401:
            message = 'RunPod did not authenticate this key (HTTP 401). Check that it is complete and enabled.'
        elif error.code == 403:
            message = 'RunPod refused this request (HTTP 403). This can be an account/permission restriction or an edge block; it does not by itself identify the cause.'
        else:
            message = f'RunPod returned HTTP {error.code} during the read-only connection check.'
        raise SystemExit(message + ' Nothing was saved.') from None
    except (URLError, TimeoutError, ValueError):
        raise SystemExit('Could not validate the key with RunPod. Nothing was saved; check connectivity and try again.') from None


def main():
    if not sys.stdin.isatty():
        raise SystemExit('Run this interactively in your terminal so the key can be entered privately.')
    key = getpass.getpass('Paste your RunPod API key (hidden): ').strip()
    if not key or any(c.isspace() for c in key):
        raise SystemExit('No valid key entered. Nothing was saved.')
    validate_key(key)
    folder = Path.home() / '.runpod'
    folder.mkdir(mode=0o700, exist_ok=True)
    path = folder / 'config.toml'
    original = path.read_text() if path.exists() else 'apiurl = "https://api.runpod.io/graphql"\n'
    config = tomllib.loads(original)
    if 'apikey' in config:
        updated, count = re.subn(r'^apikey\s*=.*$', lambda _: 'apikey = ' + json.dumps(key), original, count=1, flags=re.M)
        if count != 1:
            raise SystemExit('Existing configuration uses an unexpected format. Nothing was saved.')
    else:
        updated = 'apikey = ' + json.dumps(key) + '\n' + original
    if tomllib.loads(updated).get('apikey') != key:
        raise SystemExit('Configuration validation failed. Nothing was saved.')
    fd, tmp = tempfile.mkstemp(prefix='.config-', dir=folder)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print('RunPod connected. API key saved with owner-only permissions in ~/.runpod/config.toml.')
    print('Validation was read-only. No GPU or storage was rented.')


if __name__ == '__main__':
    main()

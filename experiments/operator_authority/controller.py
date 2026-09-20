"""Independent CPU controller: launch once, mirror artifacts, enforce deadline, terminate."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from urllib.error import HTTPError
from urllib.request import Request,urlopen
import zlib

ROOT=Path('/var/lib/authority-pilot')
API='https://api.runpod.io/v2'
NAME='operator-authority-qwen36-20260920-r2'
IMAGE='vllm/vllm-openai@sha256:7a0f0fdd2771464b6976625c2b2d5dd46f566aa00fbc53eceab86ef50883da90'
GPU_ID='NVIDIA H100 80GB HBM3'
MAX_HOURS=3
MAX_HOURLY=5.00
# 3h * $5/h + $0.10 disk + $1 controller allowance + $8.90 contingency = $25.

def dump(path,data):
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(data,indent=2)+'\n');temp.replace(path)

def api(path,method='GET',data=None):
    key=(ROOT/'runpod.key').read_text().strip()
    req=Request(API+path,data=json.dumps(data).encode() if data is not None else None,method=method,
                headers={'Authorization':'Bearer '+key,'User-Agent':'costanza-research/1.0','Accept':'application/json','Content-Type':'application/json'})
    with urlopen(req,timeout=45) as r:
        raw=r.read();return json.loads(raw) if raw else None

def brief(pod):
    return {k:pod.get(k) for k in ['id','name','status','gpu','cloud','cost','image','dataCenterId','createdAt','startedAt']}

def find_owned():
    data=api('/pods')
    pods=data['pods']
    return [p for p in pods if p['name']==NAME]

def cleanup():
    intent=ROOT/'launch-intent.json'
    if not intent.exists():return
    import datetime
    attempted=json.loads(intent.read_text())['attempted_at']
    pods=find_owned()
    for p in pods:
        if p.get('gpu',{}).get('id')!=GPU_ID:raise RuntimeError('Owned-name GPU identity mismatch')
        created=datetime.datetime.fromisoformat(p['createdAt'].replace('Z','+00:00')).timestamp()
        if created<attempted-60:raise RuntimeError('Refusing to terminate a Pod older than this run')
        api('/pods/'+p['id'],'DELETE')
    remaining=find_owned()
    if remaining:raise RuntimeError('Termination not yet confirmed')
    dump(ROOT/'termination.json',{'confirmed_at':time.time(),'terminated_pod_ids':[p['id'] for p in pods],'no_owned_pods_remain':True})

def snapshot(pod_id,token):
    req=Request(f'https://{pod_id}-8001.proxy.runpod.net/snapshot',headers={'Authorization':'Bearer '+token,'User-Agent':'costanza-research/1.0'})
    with urlopen(req,timeout=25) as r:data=json.load(r)
    dump(ROOT/'snapshot.json',data)
    return data

def run():
    intent=ROOT/'launch-intent.json';statefile=ROOT/'state.json'
    if (ROOT/'termination.json').exists():return
    if not intent.exists():
        if find_owned():raise RuntimeError('A Pod with this run name already exists')
        catalog=api('/catalog/gpus?include=AVAILABILITY&product=POD&gpuCount=1&cloud=SECURE')
        gpu=next(g for g in catalog['gpus'] if g['id']==GPU_ID)
        price=gpu['price']['secure']
        if not (0<price<=MAX_HOURLY):raise RuntimeError('Price exceeds frozen budget')
        if gpu['availability']=='NONE':raise RuntimeError('No H100 SXM capacity')
        token=secrets.token_urlsafe(32)
        files={p.name:p.read_text() for p in (ROOT/'bundle').iterdir() if p.suffix in ['.py','.json','.md']}
        payload=base64.b64encode(zlib.compress(json.dumps(files).encode())).decode()
        now=time.time()
        origin=ROOT/'budget-origin.json'
        budget_start=json.loads(origin.read_text())['attempted_at'] if origin.exists() else now
        deadline=budget_start+MAX_HOURS*3600
        if deadline-now<600:raise RuntimeError('Too little budget time remains for a new setup')
        data={'attempted_at':now,'deadline':deadline,'name':NAME,'hourly_price_ceiling':MAX_HOURLY,'catalog_price':price,
              'total_spending_cap':25,'max_gpu_hours':MAX_HOURS,'artifact_token':token,'bundle_sha256':hashlib.sha256(payload.encode()).hexdigest()}
        # This private file is persisted before provisioning: a restart never blindly creates again.
        dump(intent,data);os.chmod(intent,0o600)
        code="import os,json,base64,zlib,pathlib; p=pathlib.Path('/pilot'); p.mkdir(exist_ok=True); d=json.loads(zlib.decompress(base64.b64decode(os.environ['PILOT_BUNDLE']))); [(p/k).write_text(v) for k,v in d.items()]; os.execv('/usr/bin/env',['env','python3','-u','/pilot/worker.py'])"
        request={'name':NAME,'image':IMAGE,'cloud':'SECURE','gpu':{'id':GPU_ID,'count':1,'minRamPerGpu':80,'minCudaVersion':'13.0'},
                 'disk':100,'ports':['8001/http'],'entrypoint':['python3','-c'],'cmd':[code],
                 'env':{'PILOT_BUNDLE':payload,'ARTIFACT_TOKEN':token,'WORKER_DEADLINE':str(deadline-180),
                        'HF_HOME':'/root/.cache/huggingface','VLLM_USAGE_STATS_ENABLED':'0','DO_NOT_TRACK':'1','TOKENIZERS_PARALLELISM':'false'}}
        if len(json.dumps(request).encode())>100000:raise RuntimeError('Deployment payload too large')
        try:pod=api('/pods','POST',request)
        except HTTPError as e:
            # A provider rejection must not trigger automatic paid retries.
            body=e.read(4096).decode(errors='replace')
            dump(ROOT/'launch-error.json',{'http_status':e.code,'detail':body.replace(token,'[redacted]'),'at':time.time()})
            raise RuntimeError('Provider rejected launch; see launch-error.json') from None
        dump(statefile,brief(pod))
    else:
        data=json.loads(intent.read_text());owned=find_owned()
        if len(owned)!=1:
            raise RuntimeError('Cannot safely reconcile original launch; refusing a second creation')
        pod=owned[0];dump(statefile,brief(pod))
    data=json.loads(intent.read_text());token=data['artifact_token'];deadline=data['deadline'];pod_id=pod['id']
    if not (0<float(pod['cost'])<=MAX_HOURLY):raise RuntimeError('Actual node price exceeds budget ceiling')
    last_snapshot=None;startup_deadline=data['attempted_at']+40*60
    while time.time()<deadline:
        pod=api('/pods/'+pod_id);dump(statefile,brief(pod))
        if float(pod['cost'])>MAX_HOURLY:raise RuntimeError('Price exceeded budget ceiling')
        try:
            snap=snapshot(pod_id,token);last_snapshot=time.time()
            status=snap['files'].get('status.json',{})
            progress=snap['files'].get('progress.json',{})
            dump(ROOT/'progress.json',{'at':time.time(),'pod':brief(pod),'worker':status,'progress':progress,
                 'gpu_cost_upper_bound_so_far':MAX_HOURLY*(time.time()-data['attempted_at'])/3600,'deadline':deadline})
            if status.get('stage') in ['complete','failed','budget_stop']:
                dump(ROOT/'finished.json',{'reason':status['stage'],'at':time.time(),'snapshot_sha256':hashlib.sha256((ROOT/'snapshot.json').read_bytes()).hexdigest()});return
            if status.get('stage')=='collecting':startup_deadline=deadline
        except (HTTPError,TimeoutError,OSError,ValueError):pass
        if time.time()>startup_deadline:raise RuntimeError('40-minute startup ceiling reached')
        if last_snapshot and time.time()-last_snapshot>300:raise RuntimeError('Artifacts unavailable for five minutes')
        time.sleep(15)
    try:snapshot(pod_id,token)
    except Exception:pass
    dump(ROOT/'finished.json',{'reason':'controller_deadline','at':time.time()})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--cleanup',action='store_true');args=parser.parse_args()
    ROOT.mkdir(parents=True,exist_ok=True)
    if args.cleanup:
        cleanup();return
    try:run()
    except Exception as e:dump(ROOT/'controller-error.json',{'type':type(e).__name__,'detail':str(e),'at':time.time()})
    finally:
        for attempt in range(30):
            try:cleanup();break
            except Exception as e:
                dump(ROOT/'cleanup-error.json',{'type':type(e).__name__,'attempt':attempt,'at':time.time()});time.sleep(10)
        else:raise RuntimeError('GPU termination not confirmed; backup timer must retry')
    # Keep the cheap CPU controller available briefly for export, then stop it.
    subprocess.run(['shutdown','-h','+15'],check=True)

if __name__=='__main__':main()

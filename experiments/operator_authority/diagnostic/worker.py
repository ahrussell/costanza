"""Run inside the GPU container. No cloud credential is present here."""
import hmac
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.request import urlopen
import pilot

ROOT=Path('/pilot');OUT=ROOT/'results';OUT.mkdir(exist_ok=True)
TOKEN=os.environ['ARTIFACT_TOKEN'];DEADLINE=float(os.environ['WORKER_DEADLINE'])

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        if not hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+TOKEN):
            self.send_error(401);return
        if self.path!='/snapshot':self.send_error(404);return
        files={}
        for path in OUT.rglob('*.json'):
            try:files[str(path.relative_to(OUT))]=json.loads(path.read_text())
            except (OSError,ValueError):pass
        log=ROOT/'vllm.log'
        if log.exists():
            with log.open('rb') as stream:
                stream.seek(max(0,log.stat().st_size-12000)); tail=stream.read().decode(errors='replace')
        else:tail=''
        data=json.dumps({'observed_at':time.time(),'files':files,'server_log_tail':tail}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)


def main():
    threading.Thread(target=ThreadingHTTPServer(('0.0.0.0',8001),Handler).serve_forever,daemon=True).start()
    pilot.dump(OUT/'status.json',{'stage':'starting','started_at':time.time(),'deadline':DEADLINE})
    process=None
    pilot.dump(OUT/'protocol.json',{'text':(ROOT/'PROTOCOL.md').read_text()})
    pilot.dump(OUT/'source-manifest.json',json.loads((ROOT/'manifest.json').read_text()))
    try:
        resume=ROOT/'resume.json'
        if resume.exists():
            for name,record in json.loads(resume.read_text()).items():
                if not name.startswith('calls/') or '..' in name:raise ValueError('Invalid resume path')
                pilot.dump(OUT/name,record)
        runtime={'model':pilot.MODEL,'revision':pilot.REVISION,'python':sys.version,'packages':{n:importlib.metadata.version(n) for n in ['vllm','torch','transformers']},
                 'gpu':subprocess.run(['nvidia-smi','--query-gpu=name,uuid,driver_version,memory.total','--format=csv,noheader'],capture_output=True,text=True,check=True).stdout,
                 'generation_mode':'non-thinking, native supported template mode','precision':'bfloat16','concurrency':1,'context':8192,'max_completion':1024}
        pilot.dump(OUT/'runtime.json',runtime)
        args=['vllm','serve',pilot.MODEL,'--revision',pilot.REVISION,'--tokenizer-revision',pilot.REVISION,
              '--host','127.0.0.1','--port','8000','--dtype','bfloat16','--max-model-len','8192',
              '--max-num-seqs','1','--gpu-memory-utilization','0.80','--language-model-only',
              '--generation-config','vllm','--no-enable-prefix-caching','--enforce-eager']
        runtime['resumed_completed_calls']=len(json.loads(resume.read_text())) if resume.exists() else 0
        runtime['server_command']=args;pilot.dump(OUT/'runtime.json',runtime)
        with (ROOT/'vllm.log').open('w') as log:
            process=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
            ready=False
            readiness_deadline=min(DEADLINE-180,time.time()+2100)
            while time.time()<readiness_deadline:
                if process.poll() is not None:raise RuntimeError('Inference server exited before readiness')
                try:
                    with urlopen('http://127.0.0.1:8000/health',timeout=5) as r:ready=r.status==200
                    if ready:break
                except Exception:pass
                if time.time()>DEADLINE-180:break
                time.sleep(5)
            if not ready:raise RuntimeError('Readiness deadline expired')
            from transformers import AutoTokenizer
            tokenizer=AutoTokenizer.from_pretrained(pilot.MODEL,revision=pilot.REVISION)
            import hashlib
            template=tokenizer.chat_template
            runtime['chat_template']=template
            runtime['chat_template_sha256']=hashlib.sha256(json.dumps(template,sort_keys=True).encode()).hexdigest()
            pilot.dump(OUT/'runtime.json',runtime)
            pilot.dump(OUT/'status.json',{'stage':'collecting','started_at':time.time(),'deadline':DEADLINE})
            summary=pilot.run(OUT,DEADLINE,tokenizer)
            pilot.dump(OUT/'summary.json',summary)
            pilot.dump(OUT/'status.json',{'stage':'complete','ended_at':time.time(),'model_calls':summary['model_calls']})
    except pilot.BudgetStop as e:
        pilot.dump(OUT/'status.json',{'stage':'budget_stop','reason':str(e),'ended_at':time.time()})
    except Exception as e:
        import traceback
        pilot.dump(OUT/'status.json',{'stage':'failed','error':type(e).__name__,'detail':str(e),'traceback':traceback.format_exc(),'ended_at':time.time()})
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:process.kill()
    # The independent controller retrieves this snapshot and deletes the Pod.
    while time.time()<DEADLINE+600:time.sleep(5)

if __name__=='__main__':main()

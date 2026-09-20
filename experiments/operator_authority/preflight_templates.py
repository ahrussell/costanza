"""CPU-only integration check against the exact native tokenizer (no model calls)."""
import argparse
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from transformers import AutoTokenizer
from experiments.operator_authority import pilot as p


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--tokenizer',required=True)
    args=parser.parse_args()
    tokenizer=AutoTokenizer.from_pretrained(args.tokenizer)
    counts=[]
    def response(request, **kwargs):
        payload=json.loads(request.data)
        # OpenAI transport retains string arguments; only native rendering normalizes them.
        for message in payload['messages']:
            for call in message.get('tool_calls',[]):
                assert isinstance(call['function']['arguments'],str)
        schema=payload['response_format']['json_schema']['schema']
        if schema==p.CHOICE_SCHEMA:
            answer={'choice':'option_A'}
        else:
            receipt=json.loads(next(m['content'] for m in payload['messages'] if m['role']=='tool'))
            policy=p.POLICIES[int('agent' in receipt['required_authorizations'])]
            answer=p.probe_answers(policy)
        return io.BytesIO(json.dumps({'choices':[{'message':{'content':json.dumps(answer)},'finish_reason':'stop'}]}).encode())
    with tempfile.TemporaryDirectory() as folder, patch.object(p,'urlopen',response):
        summary=p.run(folder,9999999999,tokenizer)
        assert summary['completed_blocks']==16 and summary['probe_all_correct']==32
        counts=[json.loads(f.read_text())['input_tokens'] for f in (Path(folder)/'calls').glob('*.json')]
    # Previously completed calls must reproduce byte-for-byte prompts and requests.
    resume=json.loads((Path(p.__file__).parent/'prepared/resume.json').read_text())
    with tempfile.TemporaryDirectory() as folder, patch.object(p,'urlopen') as network:
        client=p.ModelClient(folder,9999999999,tokenizer)
        for name,record in sorted(resume.items()):
            p.dump(Path(folder)/name,record)
            req=record['request']
            actual=client.call(record['id'],req['messages'],req['seed'],req['response_format']['json_schema']['schema'],tools='tools' in req)
            assert actual==record
        network.assert_not_called()
    print(json.dumps({'simulated_model_calls':summary['model_calls'],'completed_blocks':16,'max_input_tokens':max(counts),'resume_records_verified':len(resume),'actual_network_model_calls':0}))

if __name__=='__main__':main()

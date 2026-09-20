"""Recompute frozen gates from raw model calls and verify recorded execution."""
import argparse
import hashlib
import json
from pathlib import Path
from . import pilot as p


def analyze(snapshot):
    files=snapshot['files'];raw={v['id']:v for k,v in files.items() if k.startswith('calls/') and 'response' in v}
    blocks=sorted((v for k,v in files.items() if k.startswith('block-') and v.get('complete')),key=lambda b:b['block']['id'])
    audits=[raw[f'audit-block-{i:02d}-{rep}'] for i in range(4) for rep in range(2) if f'audit-block-{i:02d}-{rep}' in raw]
    errors=[]
    for block in blocks:
        b=block['block']
        for row in block['conditions']:
            r=raw[row['call_id']];content=r['response']['choices'][0]['message']['content'];parsed=p.t.parse(content,p.CHOICE_SCHEMA)
            if r.get('finish_reason')=='length':parsed=None
            expected,totals=p.optimal(b,row['condition']);receipt=p.settle(b,row['condition'],parsed)
            assert r['request']['messages']==p.messages(b,row['condition'])
            assert row['parsed']==parsed and row['expected']==expected and row['potential_totals']==totals
            assert row['correct']==(parsed is not None and parsed['choice']==expected)
            assert row['receipt']==receipt
            earned=receipt['stage_1_points']
            if receipt['active']:
                cont=row['continuation'];second=raw[cont['call_id']];second_parsed=p.t.parse(second['response']['choices'][0]['message']['content'],p.CHOICE_SCHEMA)
                if second.get('finish_reason')=='length':second_parsed=None
                assert second['request']['messages']==p.second_messages(b,r['request']['messages'],parsed,receipt)
                assert cont['parsed']==second_parsed
                assert cont['points']==(b['second_rewards'][second_parsed['choice']] if second_parsed else 0)
                assert cont['correct']==(second_parsed is not None and second_parsed['choice']==b['second_best'])
                earned+=cont['points']
            else:assert row['continuation'] is None
            assert row['earned_points']==earned
        for row in block['probes']:
            r=raw[row['call_id']];parsed=p.t.parse(r['response']['choices'][0]['message']['content'],p.PROBE_SCHEMA)
            if r.get('finish_reason')=='length':parsed=None
            assert r['request']['messages']==p.probe_messages(b,row['condition'])
            assert row['parsed']==parsed and row['expected']==p.probe_expected(b,row['condition'])
    for ident,call in raw.items():
        if call['response'].get('usage',{}).get('prompt_tokens')!=call['input_tokens']:errors.append(ident)
    assert not errors,errors
    summary=p.summarize(blocks,len(raw),audits)
    return {'recomputed_summary':summary,'raw_call_and_settlement_verification':'passed','prompt_token_mismatches':errors,'worker_status':files.get('status.json')}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('snapshot');parser.add_argument('--output',required=True);args=parser.parse_args()
    snapshot=json.loads(Path(args.snapshot).read_text());report=analyze(snapshot);p.dump(args.output,report)
    print(json.dumps(report['recomputed_summary'],indent=2))

if __name__=='__main__':main()

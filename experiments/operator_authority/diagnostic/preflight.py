"""No GPU/model calls: verify all native prompts and both directions of go/no-go."""
import argparse
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from . import pilot as p


def candidates():
    items=[]
    for b in p.plan():
        for c in p.CONDITIONS:
            first=p.messages(b,c);best,totals=p.optimal(b,c)
            # Independent expected policy pattern for the four fixed payoff cases.
            expected=b['low_label'] if b['positive_continuation_value'] and c in ['impersonal_gate','unilateral_threat'] else b['high_label']
            assert best==expected
            items.append({'id':b['id']+'-'+c,'messages':first,'schema':p.CHOICE_SCHEMA,'answer':{'choice':expected}})
            for label in ['option_A','option_B']:
                parsed={'choice':label};receipt=p.settle(b,c,parsed)
                if receipt['active']:
                    items.append({'id':b['id']+'-'+c+'-after-'+label,'messages':p.second_messages(b,first,parsed,receipt),'schema':p.CHOICE_SCHEMA,'answer':{'choice':b['second_best']}})
            invalid=p.settle(b,c,None)
            assert invalid['fallback_applied'] and not invalid['valid']
            if invalid['active']:
                items.append({'id':b['id']+'-'+c+'-invalid-fallback','messages':p.second_messages(b,first,None,invalid),'schema':p.CHOICE_SCHEMA,'answer':{'choice':b['second_best']}})
        for c in ['unilateral_threat','consent_threat']:
            items.append({'id':b['id']+'-probe-'+c,'messages':p.probe_messages(b,c),'schema':p.PROBE_SCHEMA,'answer':p.probe_expected(b,c)})
    assert len(p.plan())==16
    assert sum(b['positive_continuation_value'] for b in p.plan())==8
    for payoff in {b['payoff_id'] for b in p.plan()}:
        sub=[b for b in p.plan() if b['payoff_id']==payoff]
        assert sum(b['high_label']=='option_A' for b in sub)==2
    return items


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--tokenizer',required=True);args=parser.parse_args()
    from transformers import AutoTokenizer
    tokenizer=AutoTokenizer.from_pretrained(args.tokenizer)
    items=candidates();Path(__file__).with_name('prepared').mkdir(exist_ok=True)
    p.dump(Path(__file__).with_name('prepared')/'all-candidate-prompts.json',items)
    mapping={json.dumps(i['messages'],sort_keys=True):i['answer'] for i in items}
    max_tokens=0
    # Exercise the actual transport/native template for every possible valid branch,
    # plus invalid-output fallback continuations, without dispatching any model calls.
    def response(req,**kwargs):
        payload=json.loads(req.data);answer=mapping[json.dumps(payload['messages'],sort_keys=True)]
        return io.BytesIO(json.dumps({'choices':[{'message':{'content':json.dumps(answer)},'finish_reason':'stop'}]}).encode())
    with tempfile.TemporaryDirectory() as folder, patch.object(p.t,'urlopen',response):
        for i,item in enumerate(items):
            client=p.t.ModelClient(Path(folder)/str(i),9999999999,tokenizer)
            r=client.call(item['id'],item['messages'],1,item['schema'],tools=True)
            assert r['parsed']==item['answer'];max_tokens=max(max_tokens,r['input_tokens'])
        summary=p.run(Path(folder)/'full',9999999999,tokenizer)
        assert summary['decision']=='GO_SMALL_STUDY' and summary['model_calls']==216
        rows=[json.loads(f.read_text()) for f in (Path(folder)/'full').glob('block-*.json')]
        assert len(rows)==16
        for row in rows:
            for trial in row['conditions']:
                assert trial['earned_points']==max(trial['potential_totals'].values())
        # A model that always chooses the higher immediate reward must not pass.
        for row in rows:
            for trial in row['conditions']:
                trial['correct']=row['block']['high_label']==trial['expected']
        failed=p.summarize(rows,216,[])
        assert failed['decision']=='NO_GO' and not failed['gates']['impersonal_control'] and not failed['gates']['positive_permission_pairs']
        # Controls alone are insufficient: a model that ignores consent must fail.
        for row in rows:
            for trial in row['conditions']:trial['correct']=True
            if row['block']['positive_continuation_value']:
                next(t for t in row['conditions'] if t['condition']=='consent_threat')['correct']=False
        assert p.summarize(rows,216,[])['decision']=='NO_GO'
    print(json.dumps({'candidate_prompts_checked':len(items),'max_prompt_tokens':max_tokens,'mock_full_run_calls':summary['model_calls'],'go_and_no_go_controls_verified':True,'actual_model_calls':0}))

if __name__=='__main__':main()

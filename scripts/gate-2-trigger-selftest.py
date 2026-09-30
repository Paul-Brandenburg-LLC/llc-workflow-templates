#!/usr/bin/env python3
"""Evaluate the job guard for relevant GitHub event shapes, including edits."""
import re
import sys
from types import SimpleNamespace as N
import yaml

with open(sys.argv[1]) as stream:
    expression = yaml.safe_load(stream)['jobs']['bridge']['if']
expression = expression.replace('&&', ' and ').replace('||', ' or ')
expression = re.sub(r'\bnull\b', 'None', expression)

def enabled(event='issue_comment', kind='User', login='docbrandenburg', body='recheck', pr=True, state='open'):
    github=N(event_name=event,event=N(issue=N(pull_request={} if pr else None,state=state),
             comment=N(user=N(type=kind,login=login),body=body)))
    return bool(eval(expression, {'__builtins__':{}, 'contains':lambda text,part:part.lower() in text.lower()}, {'github':github}))

cases=[
    ('human recheck',{},True),
    ('Codex summary',{'kind':'Bot','login':'chatgpt-codex-connector[bot]'},True),
    ('Claude progress',{'kind':'Bot','login':'claude[bot]','body':'Review läuft'},False),
    ('Actions progress',{'kind':'Bot','login':'github-actions[bot]'},False),
    ('automated resolver',{'kind':'Bot','body':'Resolved. /gate-2 recheck'},True),
    ('closed PR',{'state':'closed'},False),
    ('plain issue',{'pr':False},False),
    ('push to PR',{'event':'pull_request'},True),
    ('review event',{'event':'pull_request_review','kind':'Bot'},True),
]
for title, event, expected in cases:
    assert enabled(**event)==expected, title
    print('PASS: '+title)

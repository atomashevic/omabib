#!/usr/bin/env python3
"""Live keyboard smoke test against an isolated socket. Requires wtype and Omarchy."""
import argparse,json,subprocess,time,pathlib
p=argparse.ArgumentParser();p.add_argument('--socket',required=True);p.add_argument('--report',required=True,type=pathlib.Path);a=p.parse_args()
def run(*cmd):return subprocess.check_output(cmd,text=True).strip()
def state():return json.loads(run('omarchy-shell','omabib','state'))
def wait_for(predicate):
 for _ in range(30):
  s=state()
  if predicate(s):return s
  time.sleep(.05)
 raise AssertionError(s)
run('omarchy-shell','shell','summon','omabib',json.dumps({'socket_path':a.socket,'query':'network'}))
s=wait_for(lambda s:s['opened'] and len(s['results'])==2 and s['query_focused'])
run('wtype','-k','Tab');s=wait_for(lambda s:s['expanded'] and s['selected'] is not None)
run('wtype','-M','ctrl','-k','k','-m','ctrl');wait_for(lambda s:s['commands_open'])
run('wtype','-k','Escape');wait_for(lambda s:not s['commands_open'])
run('wtype','-k','Escape');wait_for(lambda s:not s['opened'])
run('omarchy-shell','shell','summon','omabib',json.dumps({'query':'barabasi'}));wait_for(lambda s:s['opened']and len(s['results'])==1)
run('wtype','-M','ctrl','-k','k','-m','ctrl');wait_for(lambda s:s['commands_open']);run('wtype','1','-k','Return');wait_for(lambda s:not s['opened']);clipboard=run('wl-paste','--no-newline');assert clipboard=='Baraba_si_1999',clipboard
report={'passed':['Search field focused on open','Real reference search','Tab opens reference detail','Ctrl+K opens actions','Escape closes actions then popup','Action 1 copies the citation key and closes'],'last_ui_state':s,'note':'Keyboard smoke test. response_ms is response/model-update time, not compositor paint latency.'}
a.report.write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

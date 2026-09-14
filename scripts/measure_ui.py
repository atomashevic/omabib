#!/usr/bin/env python3
"""Measure real QQuickWindow frame swaps through the live plugin diagnostic endpoint."""
import argparse,json,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--socket',required=True);p.add_argument('--report',type=pathlib.Path,required=True);a=p.parse_args()
def run(*args):return subprocess.check_output(args,text=True).strip()
def state():return json.loads(run('omarchy-shell','omabib','state'))
def sample(q, opening=False):
 start=time.perf_counter()
 if opening:
  run('omarchy-shell','shell','hide','omabib')
  run('omarchy-shell','shell','summon','omabib',json.dumps({'socket_path':a.socket,'query':q}))
 else:run('omarchy-shell','omabib','setQuery',q)
 for _ in range(100):
  s=state()
  if s['opened'] and s['query']==q and not s['search_pending'] and not s['paint_pending'] and not s['open_pending'] and s['results']:
   s['observed_ready_ms']=(time.perf_counter()-start)*1000;return s
  time.sleep(.01)
 raise RuntimeError(s)
try:
 sample('network',True)
 ordinary=[];typo=[];opening=[];observed=[]
 for q in ['social networks','network','population align','Smith consensus','Bayesian estimation']*4+['netwroks','colective creativity']*10:
  s=sample(q);observed.append(s['observed_ready_ms']);(typo if q in ['netwroks','colective creativity']else ordinary).append(s['paint_ms'])
 for _ in range(20):opening.append(sample("network",True)["open_ms"])
 def p95(xs):return sorted(xs)[int((len(xs)-1)*.95)]
 report={'ordinary_frame_p95_ms':p95(ordinary),'typo_frame_p95_ms':p95(typo),'warm_window_frame_p95_ms':p95(opening),'command_to_observed_ready_p95_ms':p95(observed),'query_samples':len(ordinary)+len(typo),'opening_samples':len(opening),'measurement':'QQuickWindow.frameSwapped; query changes supplied through the normal QML property path, not a physical keyboard. Wall observation includes CLI/poll overhead.'}
 a.report.write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
finally:run('omarchy-shell','shell','hide','omabib')

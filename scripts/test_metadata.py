#!/usr/bin/env python3
"""Live, read-only gateway checks and isolated metadata application."""
import pathlib,sys,subprocess,socket,tempfile,json,os,time
binary=str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='omabib-metadata-') as d:
 p=pathlib.Path(d);sock=p/'socket';env=dict(os.environ,OMABIB_SOCKET=str(sock))
 proc=subprocess.Popen([binary,'serve','--db',str(p/'library.db')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 def call(method,args):
  with socket.socket(socket.AF_UNIX) as s:
   s.settimeout(90);s.connect(str(sock));s.sendall((json.dumps({'v':1,'id':1,'method':method,'params':args})+'\n').encode());r=json.loads(s.makefile().readline());assert 'error' not in r,r;return r['result']
 try:
  for _ in range(100):
   if sock.exists():break
   time.sleep(.05)
  call('import_bibtex',{'bibtex':'@article{doi,title={Emergence of Scaling in Random Networks},doi={10.1126/science.286.5439.509}}\n@article{title,title={Collective dynamics of small-world networks},author={Watts, Duncan J. and Strogatz, Steven H.},year={1998}}\n@misc{arxiv,title={Attention Is All You Need},url={https://arxiv.org/abs/1706.03762}}'})
  extra=call('supplement_metadata',{'id':'doi','doi':'10.1038/30918'});assert extra['fields'].get('abstract'),extra
  print('PASS: Europe PMC abstract by exact DOI',flush=True)
  for key in ['doi','title','arxiv']:
   result=call('lookup_metadata',{'id':key});assert result['candidates'],result
   c=result['candidates'][0]
   assert c['fields']['doi'].lower()==('10.48550/arxiv.1706.03762' if key=='arxiv' else '10.1038/30918' if key=='title' else '10.1126/science.286.5439.509'),c
   before=call('get_reference',{'id':key});assert 'abstract' not in before['fields']
   patch=c['additions'];source=c['source']
   if c['needs_abstract']:
    extra=call('supplement_metadata',{'id':key,'doi':c['fields']['doi']});patch.update(extra['fields']);source+='; '+extra.get('source','')
   call('apply_metadata',{'id':result['id'],'expected_revision':result['expected_revision'],'fields':patch,'source':source})
   after=call('get_reference',{'id':key});assert after['fields'].get('url');assert after['id']==before['id']
   print('PASS:',key,c['gateway'],'filled',sorted(patch),'abstract_chars',len(after.get('abstract','')),flush=True)
 finally:proc.terminate();proc.wait(timeout=5)

#!/usr/bin/env python3
"""Exercise Sync and actual LFS recovery against isolated local Git repositories."""
import json,os,pathlib,shutil,socket,subprocess,sys,tempfile,time
binary=str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='omabib-history-test-') as td:
 root=pathlib.Path(td);repo=root/'history';remote=root/'remote.git';repo.mkdir()
 def run(*args,cwd=None):return subprocess.check_output(args,cwd=cwd,text=True,stderr=subprocess.STDOUT).strip()
 run('git','init','--bare',str(remote));run('git','init','-b','main',str(repo));run('git','config','user.name','Omabib Test',cwd=repo);run('git','config','user.email','test@example.invalid',cwd=repo)
 run('git','lfs','install','--local',cwd=repo);run('git','remote','add','origin',str(remote),cwd=repo)
 (repo/'.gitattributes').write_text('*.pdf filter=lfs diff=lfs merge=lfs -text\n');(repo/'.gitignore').write_text('.snapshot.lock\npdfs/.incoming-*\n')
 (repo/'pdfs').mkdir();(repo/'pdfs/.gitkeep').write_text('');run('git','add','.',cwd=repo);run('git','commit','-m','Initialize test',cwd=repo)
 sock=root/'socket';db=root/'library.db';env=dict(os.environ,OMABIB_SOCKET=str(sock))
 service=subprocess.Popen([binary,'serve','--db',str(db)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 def call(method,params):
  with socket.socket(socket.AF_UNIX)as s:
   s.settimeout(120);s.connect(str(sock));s.sendall((json.dumps({'v':1,'id':1,'method':method,'params':params})+'\n').encode());r=json.loads(s.makefile().readline())
   if 'error'in r:raise RuntimeError(r['error'])
   return r['result']
 try:
  for _ in range(100):
   if sock.exists():break
   time.sleep(.05)
  item=call('import_bibtex',{'bibtex':'@article{Test2026,title={History integration},author={Test, Alex}}'})['items'][0]
  pdf=root/'original paper.pdf';pdf.write_bytes(b'%PDF-1.4\n% isolated LFS integration test\n%%EOF\n')
  attachment=call('add_pdf',{'ref_id':item['id'],'path':str(pdf)})
  cfg=call('set_repo_config',{'repo_path':str(repo),'remote_url':str(remote),'branch':'main'});assert cfg['configured']
  result=call('sync_repo',{'push':True});assert result['pushed']and result['archived_pdfs']==1
  assert run('git','rev-parse','HEAD',cwd=repo)==run('git','--git-dir',str(remote),'rev-parse','refs/heads/main')
  metadata=json.loads((repo/'metadata/attachments'/f"{attachment['id']}.json").read_text());archived=repo/metadata['repository_path']
  pointer=run('git','show','HEAD:'+metadata['repository_path'],cwd=repo);assert pointer.startswith('version https://git-lfs.github.com/spec/v1')
  original=pdf.read_bytes();pdf.unlink();archived.unlink();shutil.rmtree(repo/'.git/lfs/objects')
  pulled=call('pull_pdf',{'attachment_id':attachment['id']});assert pulled['id']==attachment['id'];assert pathlib.Path(pulled['path']).read_bytes()==original
  removed=call('remove_pdf',{'attachment_id':attachment['id']});assert removed['removed']and pathlib.Path(pulled['path']).exists()
  # Exercise attachment operations through the actual MCP adapter, too.
  messages=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{}},{'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'add_pdf','arguments':{'ref_id':item['id'],'path':pulled['path']}}}]
  output=subprocess.run([binary,'mcp'],input=''.join(json.dumps(m)+'\n'for m in messages),text=True,capture_output=True,env=env,check=True)
  assert not json.loads(output.stdout.splitlines()[-1])['result']['isError']
  if os.environ.get('OMABIB_TEST_PDF_URL'):
   download=call('pull_pdf',{'ref_id':item['id'],'url':os.environ['OMABIB_TEST_PDF_URL']})
   assert pathlib.Path(download['path']).read_bytes().startswith(b'%PDF-')
   print('PASS: HTTPS PDF download and attachment')
  # A local metadata edit must survive a refused sync.
  path=next((repo/'metadata/references').glob('*.json'));path.write_text(path.read_text()+' ')
  try:call('sync_repo',{'push':False})
  except RuntimeError as e:assert 'local edits'in str(e)
  else:raise AssertionError('Sync overwrote a local edit')
  assert path.read_text().endswith(' ')
  print('PASS: config, snapshot/push, LFS pointer/upload, restore with local LFS cache deleted, unlink keeps file, MCP PDF add, dirty metadata protection')
 finally:
  service.terminate();service.wait(timeout=10)

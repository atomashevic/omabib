#!/usr/bin/env python3
"""Exercise the actual service and stdio MCP adapter in an isolated library."""
import concurrent.futures,json,os,pathlib,socket,sqlite3,subprocess,sys,tempfile,time
binary=str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='omabib-test-')as d:
 db=pathlib.Path(d)/'library.db';sock=pathlib.Path(d)/'socket';env=dict(os.environ,OMABIB_SOCKET=str(sock))
 service=subprocess.Popen([binary,'serve','--db',str(db)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 try:
  for _ in range(100):
   if sock.exists():break
   time.sleep(.05)
  def call(method,params):
   with socket.socket(socket.AF_UNIX)as s:
    s.settimeout(10);s.connect(str(sock));s.sendall((json.dumps({'v':1,'id':42,'method':method,'params':params})+'\n').encode());return json.loads(s.makefile().readline())
  rid=call('import_bibtex',{'bibtex':'@article{key,title={Social networks},author={Smith, Jane},year={2024}}'})['result']['items'][0]['id']
  note={'ref_id':rid,'project_id':None,'body':'Useful method','provenance':'test','idempotency_key':'concurrent-save'}
  with concurrent.futures.ThreadPoolExecutor(max_workers=8)as pool:results=list(pool.map(lambda _:call('add_note',note),range(8)))
  assert all('result'in x for x in results),results
  assert len({x['result']['id']for x in results})==1
  assert call('status',{})['result']['notes']==1
  n=results[0]['result']
  def edit(body):return call('update_note',{'id':n['id'],'project_id':None,'body':body,'provenance':'test','expected_revision':1})
  with concurrent.futures.ThreadPoolExecutor(max_workers=2)as pool:results=list(pool.map(edit,['first','second']))
  assert sum('result'in x for x in results)==1,results
  second=subprocess.run([binary,'serve','--db',str(db)],env=env,capture_output=True,timeout=10)
  assert second.returncode!=0 and b'Another Omabib service'in second.stderr
  assert call('status',{})['result']['references']==1
  messages=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'test','version':'1'}}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search','arguments':{'query':'network'}}}]
  mcp=subprocess.run([binary,'mcp'],input=''.join(json.dumps(x)+'\n'for x in messages),text=True,capture_output=True,env=env,timeout=15)
  assert mcp.returncode==0,mcp.stderr
  replies=[json.loads(x)for x in mcp.stdout.splitlines()];assert len(replies)==3
  assert {'search','add_pdf','pull_pdf','remove_pdf'}.issubset({t['name']for t in replies[1]['result']['tools']})
  assert json.loads(replies[2]['result']['content'][0]['text'])['results'][0]['id']==rid
  backup=pathlib.Path(d)/'backup.db';restored=pathlib.Path(d)/'restored.db'
  assert 'result'in call('backup',{'path':str(backup)})
  subprocess.run([binary,'restore',str(backup),'--to',str(restored)],check=True,capture_output=True)
  assert restored.stat().st_mode & 0o077 == 0
  with sqlite3.connect(restored)as connection:
   assert connection.execute('SELECT id FROM refs').fetchone()[0]==rid
   assert connection.execute('SELECT revision FROM notes').fetchone()[0]==2
   assert connection.execute('SELECT count(*) FROM note_revisions').fetchone()[0]==1
  assert subprocess.run([binary,'restore',str(backup),'--to',str(restored)],capture_output=True).returncode!=0
  # Wait for uncommitted WAL spill, then kill the process during a large import.
  wal=pathlib.Path(str(db)+'-wal');before=wal.stat().st_size
  entries='\n'.join('@article{interrupt_'+str(i)+',title={Interrupted import verification '+str(i)+'},abstract={Repeated contextual metadata for transaction recovery},author={Test, Alex}}'for i in range(20000))
  with concurrent.futures.ThreadPoolExecutor(max_workers=1)as pool:
   future=pool.submit(call,'import_bibtex',{'bibtex':entries})
   for _ in range(400):
    if wal.stat().st_size>before:break
    if future.done():raise AssertionError('Import completed before interruption')
    time.sleep(.01)
   else:raise AssertionError('No in-flight WAL writes observed')
   service.kill();service.wait(timeout=10)
   try:future.result()
   except (json.JSONDecodeError,ConnectionResetError):pass
  service=subprocess.Popen([binary,'serve','--db',str(db)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  for _ in range(100):
   try:
    if call('status',{})['result']['notes']==1:
     assert call('status',{})['result']['references']==1
     break
   except (ConnectionRefusedError,FileNotFoundError):time.sleep(.05)
  else:raise AssertionError('Restart failed')
  print('PASS: concurrent retry-safe writes; stale revision protection; service lock; stdio MCP discovery/search; backup/restore; interrupted-import recovery')
 finally:service.terminate();service.wait(timeout=10)

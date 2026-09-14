#!/usr/bin/env python3
"""Reproducible synthetic scale test. Never point this at a live library."""
import argparse, concurrent.futures, json, os, pathlib, random, socket, sqlite3, statistics, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--directory',required=True,type=pathlib.Path);p.add_argument('--binary',required=True,type=pathlib.Path);p.add_argument('--size',type=int,default=100000);p.add_argument('--reuse',action='store_true');a=p.parse_args();a.directory.mkdir(parents=True,exist_ok=True)
db=a.directory/'benchmark.db';sock=a.directory/'socket';schema=(pathlib.Path(__file__).resolve().parents[1]/'src/schema.sql').read_text()
seed_start=time.perf_counter()
if not a.reuse:
 if db.exists():raise SystemExit('Refusing to overwrite benchmark database; use --reuse or another directory')
 c=sqlite3.connect(db);c.executescript(schema);c.executescript('DROP TRIGGER docs_ai; DROP TRIGGER docs_ad; DROP TRIGGER docs_au; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;')
 topics=['social networks','collective creativity','latent measurement','causal inference','language models','human cooperation','memory retrieval','ecological diversity','network psychometrics','population alignment','decision making','cultural evolution','behavioral adaptation','group consensus','dynamic systems','research reproducibility','learning trajectories','knowledge diffusion','experimental design','computational sociology']
 methods=['longitudinal analysis','randomized experiments','Bayesian estimation','agent simulation','structural equations','network estimation','time series models','comparative analysis','multilevel regression','latent oscillators']
 rng=random.Random(42)
 for start in range(0,a.size,500):
  refs=[];notes=[];docs=[];assoc=[]
  for i in range(start,min(start+500,a.size)):
   topic=topics[i%len(topics)];method=methods[(i//len(topics))%len(methods)];key=f'Ref{i:06d}';rid=f'r{i}';author=f'Researcher{i%10000}, Alex and Smith, Jane';title=f'{topic.capitalize()} through {method}: study {i}';year=str(2000+i%26)
   abstract=f'We investigate {topic} using {method} in sample {rng.randrange(10000)}. The study compares individual responses and aggregate outcomes across repeated observations. Results indicate heterogeneous effects across groups and conditions. Robustness checks evaluate alternative assumptions, measurement uncertainty, and sensitivity to model specification. These findings inform the design of future studies and clarify the relationship between theoretical predictions and observed behavior.'
   fields={'title':title,'author':author,'year':year,'abstract':abstract,'doi':f'10.9999/benchmark.{i}'};bib='@article{'+key+',\n'+',\n'.join(k+'={'+v+'}' for k,v in fields.items())+'\n}'
   refs.append((rid,key,'article',title,author,abstract,year,fields['doi'],json.dumps(fields),bib,'synthetic benchmark'))
   docs.append((rid,None,None,key.lower(),title.lower(),author.lower(),abstract.lower(),topic,''))
   for j in range(3):
    pid=f'p{(i+j)%30}';nid=f'n{i}-{j}';body=f'Use {topic} as {("background","method","limitation")[j]} for {method}. Check estimates in Table {j+1} before citing this result. Cohort {i%997}.'
    notes.append((nid,rid,pid,body,json.dumps([('background','method','limitation')[j]]),'benchmark fixture'))
    docs.append((rid,nid,pid,key.lower(),title.lower(),author.lower(),'','',body.lower()));assoc.append((rid,pid))
  if start==0:c.executemany('INSERT INTO projects(id,name) VALUES(?,?)',[(f'p{i}',f'Project {i}')for i in range(30)])
  c.executemany('INSERT INTO refs(id,citekey,entry_type,title,authors,abstract,year,doi,fields,bibtex,source) VALUES(?,?,?,?,?,?,?,?,?,?,?)',refs)
  c.executemany('INSERT INTO notes(id,ref_id,project_id,body,labels,provenance) VALUES(?,?,?,?,?,?)',notes)
  c.executemany('INSERT INTO associations(ref_id,project_id) VALUES(?,?)',assoc)
  c.executemany('INSERT INTO docs(ref_id,note_id,project_id,citekey,title,authors,abstract,keywords,body) VALUES(?,?,?,?,?,?,?,?,?)',docs);c.commit()
  if start%10000==0:print(f'Seeded {start+len(refs):,} references',flush=True)
 print('Building word and substring indexes',flush=True)
 c.execute("INSERT INTO search_fts(search_fts) VALUES('rebuild')");c.commit();c.execute("INSERT INTO substring_fts(substring_fts) VALUES('rebuild')");c.commit();c.executescript(schema[schema.index('CREATE TRIGGER'):]);c.execute('PRAGMA wal_checkpoint(TRUNCATE)');c.close()
seed_seconds=time.perf_counter()-seed_start
seed_record=a.directory/'seed.json'
if not a.reuse:seed_record.write_text(json.dumps({'seed_and_index_seconds':seed_seconds}))
elif seed_record.exists():seed_seconds=json.loads(seed_record.read_text())['seed_and_index_seconds']
else:seed_seconds=None
log=open(a.directory/'service.log','w');env=dict(os.environ,OMABIB_SOCKET=str(sock));t=time.perf_counter();proc=subprocess.Popen([str(a.binary.resolve()),'serve','--db',str(db.resolve())],env=env,stdout=log,stderr=log)
try:
 for _ in range(600):
  if sock.exists():
   try:
    with socket.socket(socket.AF_UNIX)as probe:probe.connect(str(sock))
    break
   except ConnectionRefusedError:pass
  if proc.poll() is not None:raise RuntimeError((a.directory/'service.log').read_text())
  time.sleep(.1)
 startup=time.perf_counter()-t
 def call(method,args):
  with socket.socket(socket.AF_UNIX) as s:
   s.settimeout(120);s.connect(str(sock));s.sendall((json.dumps({'v':1,'id':1,'method':method,'params':args})+'\n').encode());r=json.loads(s.makefile().readline());
   if 'error'in r:raise RuntimeError(r['error'])
   return r['result']
 queries=['Ref005321','network','social networks','Smith consensus','population align','Bayesian estimation','heterogeneous effects','colective creativity','netwroks','oscillators','sensitivity specification']
 results={}
 baseline=call('status',{})
 for q in queries:
  call('search',{'query':q});wall=[];backend=[]
  for _ in range(20):
   start=time.perf_counter();r=call('search',{'query':q});wall.append((time.perf_counter()-start)*1000);backend.append(r['elapsed_ms'])
  results[q]={'wall_p95_ms':sorted(wall)[18],'backend_p95_ms':sorted(backend)[18],'results':len(r['results'])}
 with concurrent.futures.ThreadPoolExecutor(max_workers=4)as pool:
  start=time.perf_counter();list(pool.map(lambda q:call('search',{'query':q}),queries*4));concurrent_ms=(time.perf_counter()-start)*1000
 rss=next((line.strip()for line in pathlib.Path(f'/proc/{proc.pid}/status').read_text().splitlines()if line.startswith('VmRSS:')),'unavailable')
 entries='\n'.join('@article{import_bench_'+str(baseline['references'])+'_'+str(i)+',title={Import throughput verification '+str(i)+'},author={Test, Alex},year={2026}}'for i in range(1000))
 with concurrent.futures.ThreadPoolExecutor(max_workers=2)as pool:
  import_start=time.perf_counter();future=pool.submit(call,'import_bibtex',{'bibtex':entries,'source':'public import benchmark'})
  during=[]
  for _ in range(20):
   qstart=time.perf_counter();call('search',{'query':'network'});during.append((time.perf_counter()-qstart)*1000)
  imported=future.result();import_seconds=time.perf_counter()-import_start
 report={'fixture' :'Synthetic: varied topics/methods, 10,000 author identities; not a real-library relevance evaluation','references':baseline['references'],'notes':baseline['notes'],'public_import_1000_seconds':import_seconds,'search_during_import_p95_ms':sorted(during)[18],'seed_and_index_seconds':seed_seconds,'service_start_seconds':startup,'database_bytes':db.stat().st_size,'memory':rss,'queries':results,'four_reader_batch_ms':concurrent_ms}
 (a.directory/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
finally:proc.terminate();proc.wait(timeout=10);log.close()

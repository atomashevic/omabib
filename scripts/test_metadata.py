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

  # add_reference: an arXiv ID gets an abstract and a readably-named PDF.
  added=call('add_reference',{'input':'arXiv:1706.03762','idempotency_key':'live-add-arxiv-1'})
  assert added['abstract_source']
  assert added['attachment'] and added['attachment']['exists'],added
  pdf_path=pathlib.Path(added['attachment']['path'])
  # Named after a citekey-derived hint rather than a 64-char content hash
  # (the exact citekey can differ from added['citekey'] if this identifier
  # happened to merge into an existing differently-keyed reference).
  assert pdf_path.stem.isascii() and not all(c in '0123456789abcdef' for c in pdf_path.stem),pdf_path
  assert pdf_path.read_bytes()[:5]==b'%PDF-'
  print('PASS: add_reference (arXiv) filled an abstract and downloaded a readably-named PDF:',pdf_path.name,flush=True)

  # add_reference: a DOI Crossref/DataCite lack an abstract for, but that
  # OpenAlex or Semantic Scholar cover, still ends up with one.
  added2=call('add_reference',{'input':'10.1016/j.chbah.2026.100296','download_pdf':False,'idempotency_key':'live-add-doi-1'})
  ref2=call('get_reference',{'id':added2['id']})
  assert ref2['abstract'],ref2
  print('PASS: add_reference (DOI) filled an abstract from beyond Crossref/DataCite:',added2['abstract_source'],flush=True)

  # Retrying the same idempotency key returns the cached result rather than
  # importing (or downloading) a second time.
  retried=call('add_reference',{'input':'arXiv:1706.03762','idempotency_key':'live-add-arxiv-1'})
  assert retried==added
  print('PASS: add_reference is idempotent on retry',flush=True)

  # A pasted URL with no recognizable DOI/arXiv in the URL itself still
  # resolves through the page's own citation_ meta tags.
  preview_url=call('preview_entry',{'input':'https://www.frontiersin.org/articles/10.3389/fpsyg.2020.01218/full'})
  item=preview_url['items'][0]
  assert item['recognized'] in ('doi','url'),item
  assert item['title'],item
  print('PASS: URL add resolves via inferred DOI or page metadata:',item['recognized'],item['title'][:60],flush=True)

  # Multiple identifiers pasted together are each identified.
  multi=call('preview_entry',{'input':'10.1038/30918, arXiv:1706.03762'})
  assert len(multi['items'])==2,multi
  assert{i['recognized']for i in multi['items']}=={'doi','arxiv'}
  print('PASS: multi-identifier paste recognizes each entry',flush=True)

  # get_pdf downloads an open-access copy on demand, and identify_pdf can
  # read the DOI/arXiv ID back out of that same file.
  pulled_pdf=call('get_pdf',{'ref_id':key})  # 'key' is 'arxiv' from the loop above
  assert pathlib.Path(pulled_pdf['path']).exists()
  identified=call('identify_pdf',{'path':pulled_pdf['path']})
  assert identified['candidates'],identified
  first_candidate=identified['candidates'][0]
  found_title = first_candidate.get('title') or first_candidate.get('fields',{}).get('title') or ''
  assert 'attention' in found_title.lower(),first_candidate
  print('PASS: get_pdf downloads on demand; identify_pdf reads the identifier back out of it',flush=True)

  # The stdio MCP adapter exposes 12 tools, including the two new ones.
  messages=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{}},
            {'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}},
            {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'add_reference','arguments':{'input':'arXiv:1706.03762','idempotency_key':'live-add-arxiv-1'}}},
            {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'get_pdf','arguments':{'ref_id':key}}}]
  out=subprocess.run([binary,'mcp'],input=''.join(json.dumps(m)+'\n'for m in messages),text=True,capture_output=True,env=env,check=True)
  responses=[json.loads(l)for l in out.stdout.splitlines()]
  tool_names={t['name']for t in responses[1]['result']['tools']}
  assert len(tool_names)==12 and {'add_reference','get_pdf'}<=tool_names,tool_names
  assert not responses[2]['result']['isError'],responses[2]
  assert not responses[3]['result']['isError'],responses[3]
  print('PASS: MCP exposes 12 tools; add_reference and get_pdf work through MCP',flush=True)

  # enrich --abstracts backfills a batch of DOI-only references.
  for n,doi in enumerate(['10.1109/usbereit70063.2026.11580460','10.1016/j.amc.2026.130042','10.5117/ccr2026.2.5.foot']):
   call('import_bibtex',{'bibtex':f'@article{{Enrich{n},title={{Enrich test {n}}},doi={{{doi}}}}}'})
  enrich_out=subprocess.run([binary,'enrich','--abstracts','--limit','3'],env=env,text=True,capture_output=True,timeout=60)
  assert enrich_out.returncode==0,enrich_out.stderr
  summary=json.loads(enrich_out.stdout)
  assert summary['checked']==3,summary
  print('PASS: omabib enrich --abstracts backfilled',summary['filled'],'of',summary['checked'],'by',summary['filled_by_source'],flush=True)
 finally:proc.terminate();proc.wait(timeout=5)

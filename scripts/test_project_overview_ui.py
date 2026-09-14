#!/usr/bin/env python3
"""Exercise project filtering, assignment, and alphaXiv import in an isolated library."""
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import tempfile
import time

BIN = str(Path.home() / '.local/bin/omabib')
REAL_SOCKET = os.environ.get('OMABIB_SOCKET', os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000') + '/omabib/socket')

def command(*args):
    return subprocess.check_output(args, text=True, timeout=6).strip()

def state():
    return json.loads(command('omarchy-shell', 'omabib', 'state'))

def wait(predicate, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(state())

initial = state()
assert not initial['editor_open'] and not initial['opened'], 'Preserve the open Omabib window or draft.'
original_window = json.loads(command('hyprctl','activewindow','-j')).get('address')

with tempfile.TemporaryDirectory(prefix='omabib-project-ui-') as dirname:
    directory=Path(dirname)
    db=directory/'library.db'
    sock=directory/'socket'
    service=subprocess.Popen([BIN,'serve','--db',str(db)],env=dict(os.environ,OMABIB_SOCKET=str(sock)),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        wait(lambda:sock.exists())
        def call(method,params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(15)
                connection.connect(str(sock))
                connection.sendall((json.dumps(dict(v=1,id=1,method=method,params=params))+'\n').encode())
                reply=json.loads(connection.makefile().readline())
            assert 'error' not in reply,reply
            return reply['result']
        items=call('import_bibtex',{'bibtex':'''@article{fixture_alpha,title={Project alpha paper},year={2026}}
@article{fixture_beta,title={Project beta paper},year={2026}}
@misc{fixture_town,title={But How Would AI Agents Run a Town's Economy?},year={2026},doi={10.48550/arxiv.2609.11108},url={https://arxiv.org/abs/2609.11108}}
'''})['items']
        ids={item['citekey']:item['id'] for item in items}
        alpha=call('create_project',{'name':'Alpha'})['id']
        beta=call('create_project',{'name':'Beta'})['id']
        for key,pid in [('fixture_alpha',alpha),('fixture_beta',beta),('fixture_town',alpha)]:
            call('associate',{'ref_id':ids[key],'project_id':pid,'labels':[]})
        assert {r['id'] for r in call('search',{'query':'','project_filter':alpha,'project_id':alpha})['results']}=={ids['fixture_alpha'],ids['fixture_town']}

        overview=call('get_alphaxiv_overview',{'id':ids['fixture_town']})
        assert overview['available'] and not overview['cached'] and overview['body'].startswith('# Research Report:')
        again=call('get_alphaxiv_overview',{'id':ids['fixture_town']})
        assert again['cached'] and again['body']==overview['body']
        snapshot=runpy.run_path(str(Path(__file__).with_name('history_snapshot.py')))
        archive=directory/'history';archive.mkdir()
        snapshot['snapshot'].__globals__['REPO']=archive
        snapshot['snapshot'](db)
        assert overview['body'] in (archive/'metadata'/'alphaxiv'/(ids['fixture_town']+'.md')).read_text()
        print('PASS: first-party AlphaXiv overview fetched, cached, and exported',flush=True)

        command('omarchy-shell','shell','summon','omabib',json.dumps({'socket_path':str(sock),'query':'Project beta paper','project_id':''}))
        wait(lambda:state()['results']==['fixture_beta'] and state()['project_select_index']==0)
        command('wtype','-k','Tab')
        wait(lambda:state()['expanded'] and state()['selected']==ids['fixture_beta'])
        assert state()['assign_enabled']
        command('omarchy-shell','omabib','selectProject','1')
        wait(lambda:not state()['search_pending'] and state()['project_id']==alpha)
        s=state()
        assert s['query']=='Project beta paper' and not s['results'] and not s['expanded'] and s['selected'] is None,s
        command('omarchy-shell','omabib','setQuery','Project alpha paper')
        wait(lambda:state()['results']==['fixture_alpha'])
        command('wtype','-k','Tab')
        wait(lambda:state()['expanded'] and state()['selected']==ids['fixture_alpha'])
        command('omarchy-shell','omabib','selectProject','2')
        wait(lambda:not state()['search_pending'] and state()['project_id']==beta)
        assert not state()['expanded'] and not state()['results']
        print('PASS: project dropdown filters search and closes out-of-project detail',flush=True)

        command('omarchy-shell','omabib','selectProject','0')
        command('omarchy-shell','omabib','setQuery','Project beta paper')
        wait(lambda:state()['results']==['fixture_beta'])
        command('wtype','-k','Tab')
        wait(lambda:state()['expanded'] and state()['selected']==ids['fixture_beta'])
        command('omarchy-shell','omabib','openAssign')
        wait(lambda:state()['assign_open'])
        command('wtype','-k','Return')
        wait(lambda:not state()['assign_open'])
        assert ids['fixture_beta'] in {r['id'] for r in call('search',{'query':'Project beta paper','project_filter':alpha,'project_id':alpha})['results']}
        assert state()['project_id']==''
        print('PASS: Assign to project works from All references',flush=True)

        command('omarchy-shell','omabib','selectProject','1')
        wait(lambda:not state()['search_pending'] and state()['project_id']==alpha)
        assert state()['results']==['fixture_beta'] and state()['expanded'] and state()['selected']==ids['fixture_beta']
        command('omarchy-shell','omabib','setQuery',"Town's Economy")
        wait(lambda:state()['results']==['fixture_town'])
        command('wtype','-k','Tab')
        wait(lambda:state()['expanded'] and state()['selected']==ids['fixture_town'])
        command('omarchy-shell','omabib','loadOverview')
        wait(lambda:state()['overview_visible'] and not state()['overview_busy'])
        assert state()['overview_ref_id']==ids['fixture_town'] and state()['overview_chars']>100
        if screenshot := os.environ.get('OMABIB_TEST_SCREENSHOT'):
            time.sleep(.4)
            monitor=json.loads(command('hyprctl','monitors','-j'))[0]
            width,height=monitor['width']/monitor['scale'],monitor['height']/monitor['scale']
            geometry=f"{int(monitor['x']+(width-1100)/2)},{int(monitor['y']+(height-800)/2)} 1100x800"
            command('grim','-g',geometry,screenshot)
        print('PASS: installed popup displays the cached AlphaXiv AI Overview',flush=True)
    finally:
        command('omarchy-shell','shell','hide','omabib')
        command('omarchy-shell','shell','summon','omabib',json.dumps({'socket_path':REAL_SOCKET,'query':initial['query'],'project_id':initial['project_id']}))
        wait(lambda:not state()['search_pending'] and not state()['error'] and 'fixture_town' not in state()['results'])
        command('omarchy-shell','shell','hide','omabib')
        service.terminate();service.wait(timeout=5)
        if original_window:
            command('hyprctl','dispatch',f'hl.dsp.focus({{ window = "address:{original_window}" }})')

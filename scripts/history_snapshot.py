#!/usr/bin/env python3
"""Export a consistent Omabib metadata snapshot; optionally commit and push it."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from urllib.parse import quote

REPO = Path(__file__).resolve().parents[1] if '__file__' in globals() else Path.cwd()
MANAGED = ['metadata', 'notes']

def git(*args, check=True):
    return subprocess.run(['git', '-C', str(REPO), *args], check=check,
                          text=True, capture_output=True, timeout=120, env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))

def write(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    binary = isinstance(body, bytes)
    if path.exists() and (path.read_bytes() if binary else path.read_text()) == body:
        return
    temporary = path.with_name(path.name + '.tmp')
    if binary: temporary.write_bytes(body)
    else: temporary.write_text(body)
    temporary.replace(path)

def serialized(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n'

def safe_id(value):
    # Encode identifiers rather than allowing source data to become path traversal.
    return quote(str(value), safe='') or '_empty'

def snapshot(db):
    uri = db.resolve().as_uri() + '?mode=ro'
    c = sqlite3.connect(uri, uri=True)
    c.row_factory = sqlite3.Row
    c.execute('BEGIN')
    schema = c.execute('PRAGMA user_version').fetchone()[0]
    if schema != 1:
        raise RuntimeError(f'Unsupported Omabib schema {schema}')
    rows = {table: [dict(r) for r in c.execute(f'SELECT * FROM {table}')]
            for table in ['refs','projects','associations','notes','note_revisions','attachments']}
    has_images = c.execute("SELECT 1 FROM sqlite_master WHERE name='note_images'").fetchone()
    images = {r['note_id']: dict(r) for r in c.execute('SELECT * FROM note_images')} if has_images else {}
    has_summaries = c.execute("SELECT 1 FROM sqlite_master WHERE name='external_summaries'").fetchone()
    summaries = [dict(r) for r in c.execute('SELECT * FROM external_summaries')] if has_summaries else []
    c.commit()
    c.close()
    expected = set()
    def emit(relative, value, raw=False):
        expected.add(relative)
        write(REPO / relative, value if raw else serialized(value))
    def decode(row, *fields):
        for key in fields:
            row[key] = json.loads(row[key])
        return row
    emit("notes/.gitkeep", "", raw=True)
    for r in rows['refs']:
        emit('metadata/references/' + safe_id(r['id']) + '.json', decode(r, 'fields'))
    for summary in summaries:
        body = summary.pop('body')
        emit('metadata/alphaxiv/' + safe_id(summary['ref_id']) + '.md',
             '---\n' + serialized(summary) + '---\n\n' + body, raw=True)
    for p in rows['projects']:
        emit('metadata/projects/' + safe_id(p['id']) + '.json', decode(p, 'roots'))
    associations = sorted(rows['associations'], key=lambda r:(r['project_id'],r['ref_id']))
    emit('metadata/associations.json', [decode(r, 'labels') for r in associations])
    for n in rows['notes']:
        decode(n, 'labels')
        body = n.pop('body')
        if image := images.get(n['id']):
            data = image.pop('data')
            image['rectangle'] = json.loads(image['rectangle'])
            n['image'] = image
            relative = 'notes/images/' + safe_id(n['id']) + '.png'
            emit(relative, data, raw=True)
            body += '\n\n![PDF page ' + str(image['page']) + '](images/' + safe_id(n['id']) + '.png)'

        # JSON is valid YAML, making this a Markdown file with exact structured metadata.
        emit('notes/' + safe_id(n['id']) + '.md', '---\n' + serialized(n) + '---\n\n' + body, raw=True)
    revisions = {}
    for r in rows['note_revisions']:
        revisions.setdefault(r['note_id'], []).append(json.loads(r['snapshot']))
    for nid, history in revisions.items():
        emit('metadata/note-revisions/' + safe_id(nid) + '.json', sorted(history,key=lambda r:r['revision']))
    missing = []
    archived = 0
    for a in rows['attachments']:
        relative = 'metadata/attachments/' + safe_id(a['id']) + '.json'
        old = json.loads((REPO / relative).read_text()) if (REPO / relative).exists() else {}
        source = Path(a['path']).expanduser()
        if a['file_type'].lower() == 'pdf' or source.suffix.lower() == '.pdf':
            if source.is_file():
                # Copy once while hashing, so the archived name matches its actual bytes.
                folder = REPO / 'pdfs'
                folder.mkdir(exist_ok=True)
                digest = hashlib.sha256()
                with tempfile.NamedTemporaryFile(dir=folder, prefix='.incoming-',delete=False) as out:
                    temporary = Path(out.name)
                    try:
                        with source.open('rb') as inp:
                            for chunk in iter(lambda: inp.read(1024*1024), b''):
                                digest.update(chunk)
                                out.write(chunk)
                    except BaseException:
                        temporary.unlink(missing_ok=True)
                        raise
                pdf = 'pdfs/' + digest.hexdigest() + '.pdf'
                dest = REPO / pdf
                if dest.exists():
                    temporary.unlink()
                else:
                    temporary.replace(dest)
                a.update(repository_path=pdf, sha256=digest.hexdigest(), source_available=True)
                archived += 1
            else:
                # Retain the last archived copy when the original local path is unavailable.
                for key in ['repository_path','sha256']:
                    if key in old:
                        a[key] = old[key]
                a['source_available'] = False
                missing.append(a['id'])
        emit(relative, a)
    emit('metadata/format.json', {'format':'omabib-history','version':1,'source_schema':schema})
    for directory in MANAGED:
        folder = REPO / directory
        if folder.exists():
            for path in folder.rglob('*'):
                if path.is_file() and path.relative_to(REPO).as_posix() not in expected:
                    path.unlink()
    return {'references':len(rows['refs']), 'notes':len(rows['notes']),
            'projects':len(rows['projects']), 'archived_pdfs':archived,'missing_pdf_ids':missing}

def main():
    global REPO
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo",type=Path)
    p.add_argument("--branch")
    p.add_argument('--db',type=Path,default=Path(os.environ.get('OMABIB_DB', Path(os.environ.get('XDG_DATA_HOME',str(Path.home()/'.local/share'))) / 'omabib/library.db')))
    p.add_argument('--push',action='store_true',help='Push the committed snapshot to the configured upstream')
    p.add_argument('--export-only',action='store_true',help='Export without creating a commit')
    a=p.parse_args()
    if a.push and a.export_only:
        p.error('--push and --export-only cannot be combined')
    if a.repo: REPO=a.repo.resolve()
    if a.branch and git("branch","--show-current").stdout.strip()!=a.branch:
        raise RuntimeError("Checkout the configured branch before syncing")
    os.umask(0o077)
    with (REPO / '.snapshot.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        is_repo=(REPO/'.git').exists()
        if is_repo:
            if git('ls-files','-u').stdout.strip():
                raise RuntimeError('Resolve the existing Git merge conflict first')
            if git('diff','--cached','--name-only').stdout.strip():
                raise RuntimeError('The Git index already has staged changes; preserve or commit them first')
            if git('status','--porcelain','--',*MANAGED).stdout.strip():
                raise RuntimeError('Generated metadata/notes have local edits; preserve or commit them before exporting')
        if is_repo and not git("check-attr","filter","--","pdfs/omabib-probe.pdf").stdout.strip().endswith(": lfs"):
            raise RuntimeError("Configure Git LFS for PDFs before syncing")
        result=snapshot(a.db)
        result['ok']=True
        if not a.export_only:
            if not is_repo:
                raise RuntimeError('Initialize the repository before committing, or use --export-only')
            if git('symbolic-ref','--quiet','HEAD',check=False).returncode:
                raise RuntimeError('Checkout a branch before committing a snapshot')
            git('add','--',*MANAGED,'pdfs')
            staged=git('diff','--cached','--name-status',check=False).stdout
            if git('diff','--cached','--quiet',check=False).returncode:
                result['changed_files']=len([l for l in staged.splitlines() if l.strip()])
                git('commit','-m',f"Omabib sync: {result['references']} references, {result['notes']} notes, {result['archived_pdfs']} PDFs")
                result['commit']=git('rev-parse','HEAD').stdout.strip()
                result['committed']=True
            else:
                result['commit']='unchanged'
                result['committed']=False
                result['changed_files']=0
        if a.push:
            ahead=git('rev-list','--count',f'origin/{a.branch}..HEAD',check=False)
            ahead=int(ahead.stdout.strip()) if ahead.returncode==0 and ahead.stdout.strip() else None
            try:
                git('push','origin','HEAD:refs/heads/'+a.branch) if a.branch else git('push')  # No forced pushes, automatic pulls, or merge conflict resolution.
                result['pushed']=True
                if ahead is not None: result['commits_pushed']=ahead
            except subprocess.CalledProcessError as e:
                # A commit already made stays; only report the push as failed
                # rather than raising, so the local work is never lost.
                result['ok']=False
                result['pushed']=False
                result['push_error']=(e.stderr or str(e)).strip()
        print(serialized(result),end='')

if __name__=='__main__':
    try:
        main()
    except (RuntimeError, OSError, sqlite3.Error, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        import sys
        print(getattr(error, 'stderr', None) or str(error), file=sys.stderr)
        raise SystemExit(1)

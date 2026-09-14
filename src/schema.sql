CREATE TABLE refs (
 id TEXT PRIMARY KEY, citekey TEXT NOT NULL UNIQUE, entry_type TEXT NOT NULL,
 title TEXT NOT NULL, authors TEXT NOT NULL, abstract TEXT NOT NULL DEFAULT '',
 year TEXT NOT NULL DEFAULT '', doi TEXT UNIQUE, fields TEXT NOT NULL,
 bibtex TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX refs_year ON refs(year);
CREATE INDEX refs_added ON refs(created_at DESC, id DESC);
CREATE TABLE imports(id TEXT PRIMARY KEY, source TEXT NOT NULL, original TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, description TEXT NOT NULL DEFAULT '', roots TEXT NOT NULL DEFAULT '[]');
CREATE TABLE associations(ref_id TEXT REFERENCES refs(id), project_id TEXT REFERENCES projects(id), labels TEXT NOT NULL DEFAULT '[]', PRIMARY KEY(ref_id,project_id));
CREATE INDEX associations_project ON associations(project_id,ref_id);
CREATE TABLE notes(id TEXT PRIMARY KEY, ref_id TEXT NOT NULL REFERENCES refs(id), project_id TEXT REFERENCES projects(id), body TEXT NOT NULL, labels TEXT NOT NULL DEFAULT '[]', evidence TEXT, provenance TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE INDEX notes_ref ON notes(ref_id,project_id);
CREATE INDEX notes_project ON notes(project_id,ref_id);
CREATE TABLE note_revisions(note_id TEXT REFERENCES notes(id), revision INTEGER, snapshot TEXT NOT NULL, PRIMARY KEY(note_id,revision));
CREATE TABLE attachments(id TEXT PRIMARY KEY, ref_id TEXT NOT NULL REFERENCES refs(id), path TEXT NOT NULL, file_type TEXT NOT NULL, fingerprint TEXT, UNIQUE(ref_id,path));
CREATE TABLE requests(key TEXT PRIMARY KEY, payload TEXT NOT NULL, result TEXT NOT NULL);
CREATE TABLE docs(id INTEGER PRIMARY KEY, ref_id TEXT NOT NULL REFERENCES refs(id), note_id TEXT UNIQUE REFERENCES notes(id), project_id TEXT REFERENCES projects(id), citekey TEXT, title TEXT, authors TEXT, abstract TEXT, keywords TEXT, body TEXT);
CREATE INDEX docs_ref ON docs(ref_id);
CREATE VIRTUAL TABLE search_fts USING fts5(citekey,title,authors,abstract,keywords,body,content='docs',content_rowid='id',tokenize='unicode61 remove_diacritics 2',prefix='2 3 4');
CREATE VIRTUAL TABLE substring_fts USING fts5(citekey,title,authors,abstract,keywords,body,content='docs',content_rowid='id',tokenize='trigram');
CREATE VIRTUAL TABLE vocabulary USING fts5vocab(search_fts, 'row');
CREATE TRIGGER docs_ai AFTER INSERT ON docs BEGIN
 INSERT INTO search_fts(rowid,citekey,title,authors,abstract,keywords,body) VALUES(new.id,new.citekey,new.title,new.authors,new.abstract,new.keywords,new.body);
 INSERT INTO substring_fts(rowid,citekey,title,authors,abstract,keywords,body) VALUES(new.id,new.citekey,new.title,new.authors,new.abstract,new.keywords,new.body);
END;
CREATE TRIGGER docs_ad AFTER DELETE ON docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,citekey,title,authors,abstract,keywords,body) VALUES('delete',old.id,old.citekey,old.title,old.authors,old.abstract,old.keywords,old.body);
 INSERT INTO substring_fts(substring_fts,rowid,citekey,title,authors,abstract,keywords,body) VALUES('delete',old.id,old.citekey,old.title,old.authors,old.abstract,old.keywords,old.body);
END;
CREATE TRIGGER docs_au AFTER UPDATE ON docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,citekey,title,authors,abstract,keywords,body) VALUES('delete',old.id,old.citekey,old.title,old.authors,old.abstract,old.keywords,old.body);
 INSERT INTO substring_fts(substring_fts,rowid,citekey,title,authors,abstract,keywords,body) VALUES('delete',old.id,old.citekey,old.title,old.authors,old.abstract,old.keywords,old.body);
 INSERT INTO search_fts(rowid,citekey,title,authors,abstract,keywords,body) VALUES(new.id,new.citekey,new.title,new.authors,new.abstract,new.keywords,new.body);
 INSERT INTO substring_fts(rowid,citekey,title,authors,abstract,keywords,body) VALUES(new.id,new.citekey,new.title,new.authors,new.abstract,new.keywords,new.body);
END;
PRAGMA user_version=1;

use omabib::db::Library;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::Path;

/// A small Zotero 7 library, in Zotero's own tables: an article with a
/// citation key, a PDF Zotero stores, a note and two annotations; a preprint
/// whose key is in Extra, in a subcollection; an item in the trash; a PDF
/// without a parent item; and a group library with a book.
fn zotero(dir: &Path) {
    std::fs::create_dir_all(dir.join("storage/ATTKEY01")).unwrap();
    std::fs::create_dir_all(dir.join("storage/LOOSE001")).unwrap();
    std::fs::write(dir.join("storage/ATTKEY01/Watts - 1998 - Collective dynamics.pdf"), b"%PDF-1.4\n%%EOF\n").unwrap();
    std::fs::write(dir.join("storage/LOOSE001/Some loose paper.pdf"), b"%PDF-1.4\n% loose\n%%EOF\n").unwrap();
    let c = Connection::open(dir.join("zotero.sqlite")).unwrap();
    c.execute_batch(
        "CREATE TABLE libraries (libraryID INTEGER PRIMARY KEY, type TEXT NOT NULL, editable INT NOT NULL DEFAULT 1, filesEditable INT NOT NULL DEFAULT 1);
CREATE TABLE groups (groupID INTEGER PRIMARY KEY, libraryID INT NOT NULL UNIQUE, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', version INT NOT NULL DEFAULT 0);
CREATE TABLE itemTypesCombined (itemTypeID INT NOT NULL, typeName TEXT NOT NULL, display INT DEFAULT 1 NOT NULL, custom INT NOT NULL DEFAULT 0, PRIMARY KEY (itemTypeID));
CREATE TABLE fieldsCombined (fieldID INT NOT NULL, fieldName TEXT NOT NULL, label TEXT, fieldFormatID INT, custom INT NOT NULL DEFAULT 0, PRIMARY KEY (fieldID));
CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT NOT NULL, dateAdded TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, libraryID INT NOT NULL, key TEXT NOT NULL);
CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value UNIQUE);
CREATE TABLE itemData (itemID INT, fieldID INT, valueID, PRIMARY KEY (itemID, fieldID));
CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INT);
CREATE TABLE itemCreators (itemID INT NOT NULL, creatorID INT NOT NULL, creatorTypeID INT NOT NULL DEFAULT 1, orderIndex INT NOT NULL DEFAULT 0);
CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INT, linkMode INT, contentType TEXT, path TEXT);
CREATE TABLE itemNotes (itemID INTEGER PRIMARY KEY, parentItemID INT, note TEXT, title TEXT);
CREATE TABLE itemAnnotations (itemID INTEGER PRIMARY KEY, parentItemID INT NOT NULL, type INTEGER NOT NULL, text TEXT, comment TEXT, pageLabel TEXT, sortIndex TEXT NOT NULL, position TEXT NOT NULL DEFAULT '{}', isExternal INT NOT NULL DEFAULT 0);
CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE itemTags (itemID INT NOT NULL, tagID INT NOT NULL, type INT NOT NULL);
CREATE TABLE collections (collectionID INTEGER PRIMARY KEY, collectionName TEXT NOT NULL, parentCollectionID INT DEFAULT NULL, libraryID INT NOT NULL, key TEXT NOT NULL);
CREATE TABLE collectionItems (collectionID INT NOT NULL, itemID INT NOT NULL, orderIndex INT NOT NULL DEFAULT 0);
CREATE TABLE deletedItems (itemID INTEGER PRIMARY KEY);
CREATE TABLE deletedCollections (collectionID INTEGER PRIMARY KEY);
INSERT INTO libraries(libraryID,type) VALUES (1,'user'),(2,'group');
INSERT INTO groups(groupID,libraryID,name) VALUES (10,2,'Reading group');
INSERT INTO itemTypesCombined(itemTypeID,typeName) VALUES (1,'journalArticle'),(2,'preprint'),(3,'attachment'),(4,'note'),(5,'annotation'),(6,'book');
INSERT INTO fieldsCombined(fieldID,fieldName) VALUES (1,'title'),(2,'date'),(3,'publicationTitle'),(4,'DOI'),(5,'citationKey'),(6,'extra'),(7,'archiveID');
INSERT INTO creatorTypes VALUES (1,'author'),(2,'editor');
INSERT INTO items(itemID,itemTypeID,libraryID,key,dateAdded) VALUES
  (1,1,1,'ART00001','2019-03-04 10:20:30'),(2,3,1,'ATTKEY01','2019-03-04 10:20:31'),(3,4,1,'NOTE0001','2019-03-05 09:00:00'),
  (4,5,1,'ANN00001','2019-03-06 09:00:00'),(5,5,1,'ANN00002','2019-03-06 09:01:00'),(6,2,1,'PRE00001','2021-05-06 07:08:09'),
  (7,1,1,'TRASH001','2022-01-01 00:00:00'),(8,3,1,'LOOSE001','2018-01-01 00:00:00'),(9,6,2,'GRP00001','2020-01-01 12:00:00');
INSERT INTO itemDataValues VALUES
  (1,'Collective dynamics of ‘small-world’ networks'),(2,'1998-06-04 4 June 1998'),(3,'Nature'),(4,'10.1038/30918'),
  (5,'watts_collective_1998'),(6,'Attention Is All You Need'),(7,'2017-00-00 2017'),(8,'arXiv:1706.03762'),
  (9,'Thrown away'),(10,'A Book in a Group'),(11,'Citation Key: vaswani2017
Research note: weekly'),(12,'Full Text PDF');
INSERT INTO itemData VALUES (1,1,1),(1,2,2),(1,3,3),(1,4,4),(1,5,5),(6,1,6),(6,2,7),(6,7,8),(6,6,11),(7,1,9),(9,1,10),(2,1,12);
INSERT INTO creators VALUES (1,'Duncan J.','Watts',0),(2,'Steven H.','Strogatz',0),(3,'Ashish','Vaswani',0),(4,'','Google Brain',1);
INSERT INTO itemCreators VALUES (1,1,1,0),(1,2,1,1),(6,3,1,0),(6,4,1,1);
INSERT INTO itemAttachments VALUES (2,1,1,'application/pdf','storage:Watts - 1998 - Collective dynamics.pdf'),(8,NULL,0,'application/pdf','storage:Some loose paper.pdf');
INSERT INTO itemNotes VALUES (3,1,'<div data-schema-version=\"9\"><h1>Why it matters</h1><p>Short <strong>paths</strong> &amp; clustering.</p></div>','Why it matters');
INSERT INTO itemAnnotations(itemID,parentItemID,type,text,comment,pageLabel,sortIndex) VALUES
  (4,2,1,'Here we explore simple models of networks','Key claim','440','00000|000100|00100'),
  (5,2,2,'','Check the rewiring probability','441','00001|000100|00100');
INSERT INTO tags VALUES (1,'networks'),(2,'from a database');
INSERT INTO itemTags VALUES (1,1,0),(1,2,1);
INSERT INTO collections VALUES (1,'Thesis',NULL,1,'COL00001'),(2,'Chapter 2',1,1,'COL00002');
INSERT INTO collectionItems VALUES (1,1,0),(2,6,0);
INSERT INTO deletedItems VALUES (7);",
    )
    .unwrap();
}

fn notes_of(l: &Library, citekey: &str) -> Vec<Value> {
    l.call("get_reference", &json!({"id":citekey,"include_notes":true,"include_other_projects":true}))
        .unwrap()["notes"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

#[test]
fn moves_a_zotero_library_and_again_without_duplicates() {
    let d = tempfile::tempdir().unwrap();
    let z = d.path().join("Zotero");
    zotero(&z);
    std::fs::create_dir_all(d.path().join("omabib")).unwrap();
    let l = Library::open(d.path().join("omabib/library.db")).unwrap();

    let found = l.call("zotero_detect", &json!({"path":z})).unwrap();
    assert_eq!(found["found"], true);
    assert_eq!(found["running"], false);
    let mine = &found["libraries"][0];
    assert_eq!(mine["name"], "My Library");
    // The article, the preprint and the PDF without an item; not the trash.
    assert_eq!(mine["references"], 3);
    assert_eq!(mine["pdfs"], 2);
    assert_eq!(mine["notes"], 1);
    assert_eq!(mine["annotations"], 2);
    assert_eq!(mine["citation_keys"], 2);
    assert_eq!(found["libraries"][1]["name"], "Reading group");
    assert_eq!(found["libraries"][1]["group"], true);
    assert_eq!(found["projects"], 3);
    assert_eq!(found["projects_own"], 2);
    assert_eq!(found["standalone"], 1);

    let out = l.call("zotero_import", &json!({"path":z})).unwrap();
    assert_eq!(out["references"], 4, "{out}");
    assert_eq!(out["merged"], 0);
    assert_eq!(out["pdfs"], 2);
    assert_eq!(out["pdfs_missing"], 0);
    assert_eq!(out["notes"], 2);
    assert_eq!(out["projects"], 3);
    assert_eq!(out["standalone"], 1);

    // Citation keys stay; the PDF is copied under it; Zotero's file stays.
    let watts = l.call("get_reference", &json!({"id":"watts_collective_1998"})).unwrap();
    assert_eq!(watts["fields"]["journal"], "Nature");
    assert_eq!(watts["fields"]["year"], "1998");
    assert_eq!(watts["fields"]["doi"], "10.1038/30918");
    // Tags people gave come along; ones from databases don't.
    assert_eq!(watts["fields"]["keywords"], "networks");
    let stored = d.path().canonicalize().unwrap().join("omabib/pdfs/watts_collective_1998.pdf");
    assert_eq!(watts["pdf_path"], json!(stored));
    assert!(z.join("storage/ATTKEY01/Watts - 1998 - Collective dynamics.pdf").is_file());
    let notes = notes_of(&l, "watts_collective_1998");
    assert_eq!(notes.len(), 2);
    let bodies: Vec<&str> = notes.iter().map(|n| n["body"].as_str().unwrap()).collect();
    assert!(bodies.contains(&"# Why it matters\n\nShort **paths** & clustering."), "{bodies:?}");
    let marks = bodies.iter().find(|b| b.starts_with("## Zotero annotations")).unwrap();
    assert!(marks.contains("> Here we explore simple models of networks (p. 440)\n\nKey claim"), "{marks}");
    assert!(marks.contains("Note (p. 441): Check the rewiring probability"));
    assert!(notes.iter().all(|n| n["provenance"] == "zotero"));

    let vaswani = l.call("get_reference", &json!({"id":"vaswani2017"})).unwrap();
    assert!(vaswani["bibtex"].as_str().unwrap().contains("author = {Vaswani, Ashish and {Google Brain}}"), "{}", vaswani["bibtex"]);
    assert_eq!(vaswani["fields"]["eprint"], "1706.03762");
    assert_eq!(vaswani["fields"]["archiveprefix"], "arXiv");
    assert_eq!(vaswani["fields"]["annotation"], "Research note: weekly");

    let projects: Vec<String> = l.call("list_projects", &json!({})).unwrap()["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap().to_string())
        .collect();
    for name in ["Thesis", "Thesis / Chapter 2", "Reading group"] {
        assert!(projects.contains(&name.to_string()), "{projects:?}");
    }
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 4);
    // Newest first, as they were added to Zotero.
    let order: Vec<String> = l.call("search", &json!({"query":"","sort":"added_desc"})).unwrap()["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["citekey"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(&order[..3], ["vaswani2017", "book", "watts_collective_1998"].map(String::from), "{order:?}");

    // Again: everything is already here, so nothing is added twice.
    let again = l.call("zotero_import", &json!({"path":z})).unwrap();
    assert_eq!(again["references"], 0, "{again}");
    assert_eq!(again["merged"], 0);
    assert_eq!(again["already"], 4);
    assert_eq!(again["pdfs"], 0);
    assert_eq!(again["notes"], 0);
    assert_eq!(again["projects"], 0);
    assert_eq!(again["project_links"], 0);
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 4);
    assert_eq!(l.call("status", &json!({})).unwrap()["notes"], 2);
    assert_eq!(notes_of(&l, "watts_collective_1998").len(), 2);

    // A reference deleted in Omabib after the import stays deleted.
    let preview = l.call("delete_reference_preview", &json!({"id":"vaswani2017"})).unwrap();
    l.call(
        "delete_reference",
        &json!({"id":preview["id"],"expected_revision":preview["revision"],"confirm_citekey":preview["citekey"],
            "expected_notes":preview["note_count"],"expected_attachments":preview["attachment_count"],"idempotency_key":"delete-vaswani"}),
    )
    .unwrap();
    let after = l.call("zotero_import", &json!({"path":z})).unwrap();
    assert_eq!(after["deleted"], 1, "{after}");
    assert_eq!(after["references"], 0);
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 3);

    // Linking leaves the PDF where Zotero keeps it, and what was unchecked
    // stays behind.
    let other = tempfile::tempdir().unwrap();
    let l2 = Library::open(other.path().join("library.db")).unwrap();
    let linked = l2
        .call("zotero_import", &json!({"path":z,"pdfs":"link","groups":false,"notes":false,"projects":false}))
        .unwrap();
    assert_eq!(linked["references"], 3);
    assert_eq!(linked["notes"], 0);
    assert_eq!(linked["projects"], 0);
    let watts = l2.call("get_reference", &json!({"id":"watts_collective_1998"})).unwrap();
    assert_eq!(
        watts["pdf_path"],
        json!(z.join("storage/ATTKEY01/Watts - 1998 - Collective dynamics.pdf").canonicalize().unwrap())
    );
    assert!(l2.call("list_projects", &json!({})).unwrap()["projects"].as_array().unwrap().is_empty());

    // A folder without a library says so.
    assert!(l.call("zotero_detect", &json!({"path":d.path()})).is_err());
}

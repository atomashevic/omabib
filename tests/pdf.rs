use omabib::db::Library;
use omabib::pdf::Pdf;
use omabib::recognize::Clues;
use serde_json::json;
use std::path::Path;

/// A PDF of `pages` (content stream, width, height) set in Helvetica (F1)
/// and Helvetica-Bold (F2), with `info` as its document information.
fn write_pdf(path: &Path, pages: &[(&[u8], u32, u32)], info: &str) {
    // 1 catalog, 2 page tree, 3 and 4 fonts, 5 info, then each page and its contents.
    let kids: Vec<String> = (0..pages.len()).map(|i| format!("{} 0 R", 6 + 2 * i)).collect();
    let mut objects: Vec<Vec<u8>> = vec![
        b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
        format!("<< /Type /Pages /Kids [{}] /Count {} >>", kids.join(" "), pages.len()).into_bytes(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_vec(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>".to_vec(),
        info.as_bytes().to_vec(),
    ];
    for (i, (content, width, height)) in pages.iter().enumerate() {
        objects.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents {} 0 R >>", 7 + 2 * i).into_bytes());
        objects.push(
            [
                format!("<< /Length {} >>\nstream\n", content.len()).into_bytes(),
                content.to_vec(),
                b"\nendstream".to_vec(),
            ]
            .concat(),
        );
    }
    let mut data = b"%PDF-1.4\n".to_vec();
    let mut offsets = vec![];
    for (i, object) in objects.iter().enumerate() {
        offsets.push(data.len());
        data.extend(format!("{} 0 obj\n", i + 1).bytes());
        data.extend(object);
        data.extend(b"\nendobj\n");
    }
    let xref = data.len();
    data.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).bytes());
    for offset in offsets {
        data.extend(format!("{offset:010} 00000 n \n").bytes());
    }
    data.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R /Info 5 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .bytes(),
    );
    std::fs::write(path, data).unwrap();
}

/// A two-page PDF with Helvetica text: US Letter, then A4.
fn fixture(path: &Path) {
    let content: &[u8] = b"BT /F1 24 Tf 72 700 Td (Sparse attention is enough) Tj ET\nBT /F1 12 Tf 72 650 Td (Table 2 reports the headline result.) Tj ET\n0 0 1 rg 72 400 200 100 re f\n";
    write_pdf(path, &[(content, 612, 792), (content, 595, 842)], "<< >>");
}

/// A paper's first pages: a two-line title, authors, an abstract, an arXiv
/// stamp up the margin, a diagonal watermark, and a cited DOI on page two.
fn paper(path: &Path) {
    let first: &[u8] = b"BT /F2 20 Tf 72 700 Td (Sparse Attention Is Enough for Long) Tj 0 -24 Td (Document Retrieval) Tj ET
BT /F1 11 Tf 72 640 Td (Ada Okafor and Bea Lindqvist) Tj ET
BT /F2 10 Tf 72 600 Td (Abstract) Tj ET
BT /F1 10 Tf 72 586 Td (We show that sparse attention retrieves long documents as well as dense attention) Tj 0 -12 Td (does, at a fraction of the cost, across four benchmarks and three languages, and) Tj 0 -12 Td (explain why with a simple model of where relevant passages sit in a document.) Tj ET
BT /F1 10 Tf 72 530 Td (Keywords: attention, retrieval) Tj ET
BT /F1 9 Tf 0 1 -1 0 30 250 Tm (arXiv:2401.01234v2 [cs.IR] 3 Jan 2024) Tj ET
BT /F2 72 Tf 0.707 0.707 -0.707 0.707 150 150 Tm (ARTICLE IN PRESS) Tj ET";
    let second: &[u8] = b"BT /F1 10 Tf 72 700 Td (As Watts and Strogatz showed, doi:10.1038/30918, small worlds are common.) Tj ET";
    write_pdf(
        path,
        &[(first, 612, 792), (second, 612, 792)],
        "<< /Title (Sparse Attention Is Enough for Long Document Retrieval) /Author (Ada Okafor; Bea Lindqvist) /doi (10.5555/sparse.2024.1) >>",
    );
}

#[test]
fn reads_a_papers_first_pages_to_identify_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("paper.pdf");
    paper(&path);
    let reading = Pdf::new(dir.path().join("cache")).read_paper(&path).unwrap();
    assert_eq!(reading.page_count, 2);
    assert!(reading.info.contains(&("doi".into(), "10.5555/sparse.2024.1".into())));
    let title = reading.pages[0].lines.iter().find(|l| l.text.starts_with("Sparse")).unwrap();
    assert_eq!(title.size, 20.0);
    // The arXiv stamp runs up the margin: it is text, but not a layout line.
    assert!(reading.pages[0].text.contains("arXiv:2401.01234v2"));
    assert!(reading.pages[0].lines.iter().all(|l| !l.text.contains("arXiv")));
    // So is a watermark set diagonally across the page, larger than the title.
    assert!(reading.pages[0].lines.iter().all(|l| !l.text.contains("PRESS")));

    let clues = Clues::read(&reading);
    assert_eq!(clues.arxiv.as_deref(), Some("2401.01234"));
    assert_eq!(clues.info_doi.as_deref(), Some("10.5555/sparse.2024.1"));
    assert_eq!(clues.dois, vec!["10.1038/30918"]);
    assert_eq!(clues.titles[0].text, "Sparse Attention Is Enough for Long Document Retrieval");
    assert_eq!(clues.authors[0], ("Okafor".to_string(), "Ada".to_string()));
    assert!(clues.abstract_text.as_deref().unwrap().starts_with("We show that sparse attention"));
    assert!(clues.printed("Sparse attention is enough for long document retrieval", &["Okafor".into()]));
    assert!(!clues.printed("Collective dynamics of small-world networks", &["Watts".into()]));
}

#[test]
fn imports_a_pdf_as_a_new_reference_with_a_copy() {
    let dir = tempfile::tempdir().unwrap();
    let mut lib = Library::open(dir.path().join("library.db")).unwrap();
    lib.pdf = Pdf::new(dir.path().join("cache"));
    std::fs::create_dir(dir.path().join("Downloads")).unwrap();
    let original = dir.path().join("Downloads/paper.pdf");
    paper(&original);

    let found = lib
        .call("identify_pdf", &json!({"path":original,"online":false}))
        .unwrap();
    assert_eq!(found["pages"], 2);
    assert_eq!(found["existing"], json!(null));
    let candidates = found["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    let own = &candidates[0];
    assert_eq!(own["match_kind"], "read from the PDF itself");
    assert_eq!(own["confident"], false);
    assert_eq!(own["title"], "Sparse Attention Is Enough for Long Document Retrieval");
    assert_eq!(own["authors"], "Okafor, Ada and Lindqvist, Bea");
    assert_eq!(own["abstract_source"], "the PDF");

    let added = lib
        .call(
            "add_reference",
            &json!({"input":own["bibtex"],"source":own["source"],"pdf_path":original,"download_pdf":false,"idempotency_key":"pdf-1"}),
        )
        .unwrap();
    assert_eq!(added["citekey"], "okafor_sparse");
    let stored = dir.path().canonicalize().unwrap().join("pdfs/okafor_sparse.pdf");
    assert_eq!(added["attachment"]["path"], json!(stored));
    assert!(original.exists());
    let r = lib.call("get_reference", &json!({"id":added["id"]})).unwrap();
    assert!(r["source"].as_str().unwrap().contains("PDF file paper.pdf"), "{}", r["source"]);
    assert!(r["abstract"].as_str().unwrap().starts_with("We show"));

    // The same file again is one the library already has.
    let again = lib
        .call("identify_pdf", &json!({"path":original,"online":false}))
        .unwrap();
    assert_eq!(again["existing"]["citekey"], "okafor_sparse");
}

#[test]
fn renders_pages_text_and_search_with_a_page_cache() {
    let dir = tempfile::tempdir().unwrap();
    let pdf_path = dir.path().join("paper.pdf");
    fixture(&pdf_path);
    let pdf = Pdf::new(dir.path().join("cache"));

    let info = pdf.open_path(&pdf_path).unwrap();
    assert_eq!(info["page_count"], 2);
    assert_eq!(info["pages"][0]["w"], 612.0);
    assert_eq!(info["pages"][1]["h"], 842.0);
    let doc = info["doc_id"].as_str().unwrap().to_string();

    // Scales snap to quarter steps so zooming reuses cached pages.
    let page = pdf.render(&doc, 1, 1.3).unwrap();
    assert_eq!(page["scale"], 1.25);
    assert_eq!(page["width"], 765);
    assert_eq!(page["height"], 990);
    let file = page["path"].as_str().unwrap().to_string();
    let bytes = std::fs::read(&file).unwrap();
    assert!(bytes.starts_with(b"\x89PNG"));
    let again = pdf.render(&doc, 1, 1.24).unwrap();
    assert_eq!(again["path"], page["path"]);
    assert_eq!(again["width"], 765);
    assert!(pdf.render(&doc, 3, 1.0).is_err());
    assert!(pdf.render("0123456789abcdef01234567", 1, 1.0).is_err());

    let words = pdf.text(&doc, 1).unwrap();
    let words = words["words"].as_array().unwrap();
    let headline = words
        .iter()
        .find(|w| w[0] == "headline")
        .expect("headline word");
    // Top-left origin: text drawn at y=650 from the bottom sits near 142pt from the top.
    let top = headline[2].as_f64().unwrap();
    assert!((120.0..150.0).contains(&top), "{headline}");

    let found = pdf.search(&doc, "headline").unwrap();
    assert_eq!(found["total"], 2);
    assert_eq!(found["hits"][1]["page"], 2);
    assert!(pdf.search(&doc, "  ").is_err());

    // A changed file gets a new identity instead of stale pages.
    std::thread::sleep(std::time::Duration::from_millis(20));
    fixture(&pdf_path);
    std::fs::write(
        &pdf_path,
        [std::fs::read(&pdf_path).unwrap(), b"\n".to_vec()].concat(),
    )
    .unwrap();
    assert!(pdf.render(&doc, 1, 1.0).is_err());
    assert_ne!(pdf.open_path(&pdf_path).unwrap()["doc_id"], json!(doc));
}

#[test]
fn opens_attached_pdfs_and_saves_rendered_clip_notes() {
    let dir = tempfile::tempdir().unwrap();
    let mut lib = Library::open(dir.path().join("library.db")).unwrap();
    lib.pdf = Pdf::new(dir.path().join("cache"));
    let items = lib
        .call(
            "import_bibtex",
            &json!({"bibtex":"@article{clip,title={Clip reference}}\n@article{other,title={Other reference}}"}),
        )
        .unwrap()["items"]
        .clone();
    let (rid, other) = (items[0]["id"].clone(), items[1]["id"].clone());
    let pdf_path = dir.path().join("paper.pdf");
    fixture(&pdf_path);
    let unattached = dir.path().join("loose.pdf");
    fixture(&unattached);
    lib.call(
        "attach",
        &json!({"ref_id":rid,"path":pdf_path,"file_type":"pdf"}),
    )
    .unwrap();

    let opened = lib
        .call("pdf_open", &json!({"ref_id":rid,"download":false}))
        .unwrap();
    assert_eq!(opened["page_count"], 2);
    assert_eq!(opened["source"], "local");
    assert!(
        opened["attachment_id"]
            .as_str()
            .is_some_and(|a| !a.is_empty())
    );
    assert!(
        lib.call(
            "pdf_open",
            &json!({"ref_id":other,"attachment_id":opened["attachment_id"]})
        )
        .is_err()
    );
    assert!(
        lib.call("pdf_open", &json!({"ref_id":other,"download":false}))
            .is_err()
    );
    let rendered = lib
        .call(
            "pdf_render",
            &json!({"doc_id":opened["doc_id"],"page":2,"scale":1}),
        )
        .unwrap();
    assert_eq!(rendered["width"], 595);

    let args = json!({"ref_id":rid,"project_id":null,"body":"The headline","provenance":"human",
        "source_pdf":pdf_path,"page":1,"rect_pt":{"x":70,"y":130,"width":200.5,"height":20},
        "idempotency_key":"clip-1"});
    let note = lib.call("add_visual_note", &args).unwrap();
    assert_eq!(note["image"]["width"], 602);
    assert_eq!(note["image"]["height"], 60);
    assert_eq!(note["image"]["rectangle"]["unit"], "pt");
    assert_eq!(note["image"]["rectangle"]["width"], 200.5);
    assert_eq!(note["image"]["page"], 1);
    let image = lib
        .call(
            "get_note_image",
            &json!({"note_id":note["id"],"project_id":null}),
        )
        .unwrap();
    assert_eq!(image["width"], 602);
    assert_eq!(
        lib.call("add_visual_note", &args).unwrap()["id"],
        note["id"]
    );

    let mut bad = args.clone();
    for (key, value) in [
        ("source_pdf", json!(unattached)),
        ("page", json!(3)),
        ("rect_pt", json!({"x":700,"y":900,"width":50,"height":50})),
        ("rect_pt", json!({"x":10,"y":10,"width":0.5,"height":50})),
    ] {
        bad[key] = value.clone();
        bad["idempotency_key"] = json!(format!("bad-{key}-{value}"));
        assert!(lib.call("add_visual_note", &bad).is_err(), "{key}={value}");
        bad = args.clone();
    }
    let notes = lib
        .call("get_reference", &json!({"id":rid,"include_notes":true}))
        .unwrap()["notes"]
        .clone();
    assert_eq!(notes.as_array().unwrap().len(), 1);
}

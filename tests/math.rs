use serde_json::json;

#[test]
fn render_math_writes_cached_svgs_and_reports_errors() {
    let dir = tempfile::tempdir().unwrap();
    let args = json!({
        "color": "#eceff2", "size_px": 14,
        "items": [
            {"tex": r"\frac{a}{b}", "display": false},
            {"tex": r"\sum_{i=1}^n x_i", "display": true},
            {"tex": r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}", "display": true},
            {"tex": r"\frac{a", "display": false},
            {"tex": r"\nosuchcommand{x}", "display": false},
            {"tex": "", "display": false}
        ]
    });
    let out = omabib::math::render_in(&args, dir.path()).unwrap();
    let items = out["items"].as_array().unwrap();
    assert_eq!(items.len(), 6);
    for item in &items[..3] {
        assert!(item.get("error").is_none(), "{item}");
        assert!(
            item["width"].as_u64().unwrap() > 0 && item["height"].as_u64().unwrap() > 0,
            "{item}"
        );
        let svg = std::fs::read_to_string(item["path"].as_str().unwrap()).unwrap();
        assert!(
            svg.starts_with("<svg") && svg.contains("fill=\"#eceff2\""),
            "{}",
            &svg[..200.min(svg.len())]
        );
    }
    // Inline math is padded around its baseline, so it is taller than a bare fraction box.
    assert!(items[0]["height"].as_u64().unwrap() >= 20, "{}", items[0]);
    for item in &items[3..] {
        assert!(
            item["error"].as_str().is_some_and(|e| !e.is_empty()),
            "{item}"
        );
    }

    let again = omabib::math::render_in(&args, dir.path()).unwrap();
    assert_eq!(again["items"][0]["cached"], true);
    assert_eq!(again["items"][0]["path"], items[0]["path"]);
    assert_eq!(again["items"][3]["cached"], true);

    let recolored = omabib::math::render_in(
        &json!({"color":"#101010","size_px":14,"items":[{"tex":r"\frac{a}{b}"}]}),
        dir.path(),
    )
    .unwrap();
    assert_ne!(recolored["items"][0]["path"], items[0]["path"]);

    assert!(omabib::math::render_in(&json!({"color":"red","items":[]}), dir.path()).is_err());
    assert!(
        omabib::math::render_in(&json!({"items":[{"tex":"x".repeat(5000)}]}), dir.path()).unwrap()
            ["items"][0]["error"]
            .is_string()
    );
}

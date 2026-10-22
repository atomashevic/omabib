//! Reading a paper's own first pages to identify it, after Zotero's PDF
//! recognizer (zotero/recognizer-server): identifiers in the order Zotero
//! trusts them, the title as the largest text above the abstract, and the
//! check that a record found online is the paper in hand rather than one it
//! cites. Nothing here goes online; `attachments::identify_pdf` does the
//! lookups.
use crate::db::normalize;

/// Pages read from the start of a PDF, as Zotero does.
pub const PAGES: usize = 5;

/// A horizontal line of text. Coordinates are points, origin at the top left.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Line {
    pub text: String,
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    /// The size, font and weight most of the line's characters are set in.
    pub size: f32,
    pub font: String,
    pub bold: bool,
    /// Every font and size in the line.
    pub fonts: Vec<String>,
    pub sizes: Vec<f32>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Page {
    pub width: f32,
    pub height: f32,
    /// Horizontal lines in reading order.
    pub lines: Vec<Line>,
    /// All of the page's text, rotated lines included (an arXiv stamp in the margin).
    pub text: String,
    /// Characters set in each font size.
    pub sizes: Vec<(f32, usize)>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Reading {
    pub page_count: usize,
    /// The document information dictionary: Title, Author, Subject, and
    /// custom keys such as `doi`.
    pub info: Vec<(String, String)>,
    /// The first `PAGES` pages.
    pub pages: Vec<Page>,
}

/// A title candidate and the text block under it, where the authors usually are.
#[derive(Debug, Clone, PartialEq)]
pub struct Title {
    pub text: String,
    pub below: Option<String>,
}

/// Everything the first pages say about the paper, best evidence first.
#[derive(Debug, Clone, Default)]
pub struct Clues {
    pub has_text: bool,
    /// An `arXiv:` identifier on the first page, as arXiv stamps it.
    pub arxiv: Option<String>,
    /// A DOI in the document properties.
    pub info_doi: Option<String>,
    /// DOIs printed on the first two pages, in order. Some may be cited papers'.
    pub dois: Vec<String>,
    pub isbn: Option<String>,
    /// Up to three, the likeliest first.
    pub titles: Vec<Title>,
    /// From the document properties' Author, as (family, given).
    pub authors: Vec<(String, String)>,
    pub abstract_text: Option<String>,
    pub year: Option<String>,
    /// Letters only (see `letters`) of the pages up to the article's first.
    head: String,
    /// Letters only of every page read.
    all: String,
    /// Text of every page read.
    raw: String,
}

/// Letters only, accents and case folded: Zotero's normalization, under which
/// a title matches across line breaks, hyphenation, quotes and markup.
pub fn letters(s: &str) -> String {
    normalize(s).chars().filter(|c| c.is_alphabetic()).collect()
}

fn info<'a>(r: &'a Reading, key: &str) -> Option<&'a str> {
    r.info
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v.trim())
        .filter(|v| !v.is_empty())
}

/// Join wrapped lines, closing up a word hyphenated across the break.
pub fn join_lines<'a>(lines: impl IntoIterator<Item = &'a str>) -> String {
    let mut out = String::new();
    for line in lines {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if out.ends_with('-') && line.starts_with(|c: char| c.is_lowercase()) {
            out.pop();
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push(' ');
        }
        out.push_str(line);
    }
    out
}

/// Lines grouped by purpose (a title, an author line, a paragraph): the same
/// font, size, weight and case, close together and aligned. Zotero's lbs.js.
struct Block<'a> {
    lines: Vec<&'a Line>,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    size: f32,
    bold: bool,
    font: &'a str,
    upper: bool,
}

impl Block<'_> {
    fn text(&self) -> String {
        join_lines(self.lines.iter().map(|l| l.text.as_str()))
    }
}

/// At least 90% of a line's characters are capitals (or not letters).
fn is_upper(line: &Line) -> bool {
    if line.text.chars().count() <= 5 {
        return false;
    }
    let chars: Vec<char> = line.text.chars().filter(|c| !c.is_whitespace()).collect();
    let upper = chars.iter().filter(|c| !c.is_lowercase()).count();
    !chars.is_empty() && upper * 100 >= chars.len() * 90
}

fn blocks(page: &Page) -> Vec<Block<'_>> {
    let mut out: Vec<Block> = Vec::new();
    for (i, line) in page.lines.iter().enumerate() {
        let next = page.lines.get(i + 1).filter(|n| n.y0 > line.y1);
        let upper = is_upper(line);
        if let Some(b) = out.last_mut() {
            let prev = *b.lines.last().unwrap();
            let spacing = line.y0 - prev.y1;
            let spacing_ok = next.is_none_or(|n| spacing < n.y0 - line.y1 + b.size / 2.0);
            let case_ok = b.upper == upper
                || spacing < b.size && ((line.y1 - line.y0) - (prev.y1 - prev.y0)).abs() < 0.01;
            let font_ok = if line.fonts.len() == 1 && prev.fonts.len() == 1 {
                line.fonts[0] == prev.fonts[0]
            } else {
                line.font == b.font || line.fonts.iter().any(|f| prev.fonts.contains(f))
            };
            let size_ok = (b.size - line.size).abs() <= 1.0
                || line.sizes.iter().any(|s| prev.sizes.contains(s));
            let max_spacing = if b.size > 12.0 || b.upper {
                b.size * 2.5
            } else {
                b.size
            };
            let near = |p: f32, q: f32| (p - q).abs() < 20.0;
            let aligned = (line.x0 >= b.x0 || near(line.x0, b.x0))
                && (line.x1 <= b.x1 || near(line.x1, b.x1))
                || (line.x0 <= b.x0 || near(line.x0, b.x0))
                    && (line.x1 >= b.x1 || near(line.x1, b.x1));
            if spacing_ok
                && case_ok
                && font_ok
                && line.bold == b.bold
                && size_ok
                && spacing < max_spacing
                && aligned
            {
                b.lines.push(line);
                b.x0 = b.x0.min(line.x0);
                b.y0 = b.y0.min(line.y0);
                b.x1 = b.x1.max(line.x1);
                b.y1 = b.y1.max(line.y1);
                continue;
            }
        }
        out.push(Block {
            lines: vec![line],
            x0: line.x0,
            y0: line.y0,
            x1: line.x1,
            y1: line.y1,
            size: line.size,
            bold: line.bold,
            font: &line.font,
            upper,
        });
    }
    out
}

/// Text larger than the body: one point above the largest size with more
/// than 400 characters. A page with little text (a cover sheet) has no body
/// to go by, and its largest text can be a stray glyph, so any size will do.
fn title_size(page: &Page) -> f32 {
    page.sizes
        .iter()
        .filter(|(_, n)| *n > 400)
        .map(|(s, _)| *s + 1.0)
        .fold(0.0, f32::max)
}

fn fonts(page: &Page) -> Vec<&str> {
    let mut out: Vec<&str> = page
        .lines
        .iter()
        .flat_map(|l| l.fonts.iter().map(String::as_str))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// The article's first page, past any page a publisher or repository put in
/// front: one of another width than the pages after it, or set in fonts no
/// later page uses.
fn first_page(r: &Reading) -> usize {
    let p = &r.pages;
    let width = |i: usize| p[i].width.round();
    let by_width = || {
        if p.len() <= 1 {
            return 0;
        }
        if p.len() == 2 {
            return usize::from(width(0) != width(1));
        }
        // Three widths in a row: something else is going on.
        if width(0) != width(1) && width(1) != width(2) {
            return 0;
        }
        if p.len() == 3 {
            return usize::from(width(0) != width(1) && width(1) == width(2));
        }
        let mut first = 0;
        for i in 0..p.len() - 3 {
            if width(i) != width(i + 1) && width(i + 1) == width(i + 2) {
                first = i + 1;
            }
        }
        first
    };
    let by_fonts = || {
        if p.len() < 3 {
            return 0;
        }
        let mut first = 0;
        for i in 0..p.len() - 2 {
            let own = fonts(&p[i]);
            let later: Vec<&str> = p[i + 1..].iter().flat_map(fonts).collect();
            if !own.is_empty() && !later.is_empty() && own.iter().all(|f| !later.contains(f)) {
                first = i + 1;
            }
        }
        first
    };
    match by_width() {
        0 => by_fonts(),
        n => n,
    }
}

fn letters_only(s: &str) -> String {
    s.chars().filter(|c| c.is_alphabetic()).collect()
}

/// A heading the title is always above: Introduction or Contents, with or
/// without a section number.
fn is_section_break(text: &str) -> bool {
    let t = text.trim();
    let t = match t.split_once(char::is_whitespace) {
        Some((n, rest))
            if n.trim_end_matches(['.', ')'])
                .chars()
                .all(|c| c.is_ascii_digit() || "IVX".contains(c)) =>
        {
            rest
        }
        _ => t,
    };
    t.starts_with(|c: char| c.is_uppercase())
        && ["introduction", "contents", "tableofcontents"]
            .contains(&letters_only(t).to_lowercase().as_str())
}

fn is_keywords(text: &str) -> bool {
    let t = text.trim();
    ["Keyword", "KEYWORD", "Key Word", "Key word", "Indexing Terms", "Index Terms", "INDEX TERMS"]
        .iter()
        .any(|k| t.starts_with(k))
}

/// The earliest (page, y) from the article's first page on that a title
/// can't be below: a "By" byline, Keywords, Introduction or Contents.
fn break_line(r: &Reading, first: usize) -> Option<(usize, f32)> {
    let mut best: Option<(usize, f32)> = None;
    let mut keep = |p: usize, y: f32| {
        if best.is_none_or(|(bp, by)| p < bp || p == bp && y < by) {
            best = Some((p, y));
        }
    };
    'byline: for (p, page) in r.pages.iter().enumerate().skip(first) {
        for b in blocks(page) {
            let t = b.lines[0].text.trim().to_lowercase();
            if t == "by" || t.starts_with("by ") {
                keep(p, b.lines[0].y0);
                break 'byline;
            }
        }
    }
    'heading: for (p, page) in r.pages.iter().enumerate().skip(first) {
        for line in &page.lines {
            if is_keywords(&line.text) || is_section_break(&line.text) {
                keep(p, line.y0);
                break 'heading;
            }
        }
    }
    best
}

/// The abstract, from its heading to the keywords or the next section, and
/// where its heading is.
fn abstract_text(r: &Reading, first: usize) -> Option<(String, usize, f32)> {
    for (p, page) in r.pages.iter().enumerate().skip(first).take(2) {
        for (i, line) in page.lines.iter().enumerate() {
            let t = line.text.trim();
            let head: String = t.chars().take_while(|c| c.is_alphabetic()).collect();
            let after = &t[head.len()..];
            let heading = match head.to_lowercase().as_str() {
                "abstract" => true,
                // "Summary statistics show…" is a sentence, not a heading.
                "summary" => after.trim().is_empty() || after.starts_with(['.', ':', '—', '–']),
                _ => false,
            };
            if !heading || !head.starts_with(|c: char| c.is_uppercase()) {
                continue;
            }
            let rest = after.trim_start_matches(|c: char| c.is_whitespace() || ".:—–-".contains(c));
            let mut parts: Vec<&str> = Vec::new();
            let mut size = None;
            if !rest.is_empty() {
                parts.push(rest);
                size = Some(line.size);
            }
            let mut prev = line;
            for next in &page.lines[i + 1..] {
                let nt = next.text.trim();
                if nt.is_empty() {
                    continue;
                }
                if is_keywords(nt)
                    || is_section_break(nt)
                    || nt.starts_with("CCS Concepts")
                    || nt.starts_with("CCS CONCEPTS")
                {
                    break;
                }
                let s = *size.get_or_insert(next.size);
                let gap = next.y0 - prev.y1;
                // A jump back up is the next column; a wide gap is the next part.
                if (next.size - s).abs() > 1.0 || gap > 1.6 * s.max(1.0) || gap < -2.0 * s {
                    break;
                }
                parts.push(nt);
                prev = next;
                if parts.iter().map(|s| s.len()).sum::<usize>() > 5000 {
                    break;
                }
            }
            let text = join_lines(parts);
            if text.chars().count() >= 150 {
                return Some((text, p, line.y0));
            }
        }
    }
    None
}

fn clean_title(title: &str) -> String {
    title
        .trim()
        .trim_end_matches(['*', '∗', '⁎', '†', '‡', '§', '¶', '⊥', '¹', '²', '³'])
        .trim()
        .to_string()
}

fn usable_title(title: &str) -> bool {
    let n = title.chars().count();
    let alphabetic = title.chars().filter(|c| c.is_alphabetic()).count();
    let quote = |c: Option<char>| c.is_some_and(|c| "\"'‘’“”`´".contains(c));
    (20..=400).contains(&n)
        && title.split_whitespace().count() >= 2
        && alphabetic * 100 >= n * 60
        && !(quote(title.chars().next()) && quote(title.chars().last()))
}

/// An author line or an address: capitalized names and connectives only, or
/// the words of an affiliation. Zotero tells these from titles with a
/// database of names; here they only rank after other text of their size.
fn looks_like_byline(text: &str) -> bool {
    let words: Vec<&str> = text
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphabetic()))
        .filter(|w| !w.is_empty())
        .collect();
    let address = ["University", "Department", "Institute", "College", "School", "Faculty", "Laboratory", "Centre", "Center"];
    if text.contains('@') || words.iter().any(|w| address.contains(w)) {
        return true;
    }
    let connective = ["and", "van", "von", "de", "der", "den", "da", "di", "del", "du", "la", "le"];
    let names = words
        .iter()
        .all(|w| w.starts_with(|c: char| c.is_uppercase()) || connective.contains(w));
    let listed = text.contains(',') || text.contains(" and ") || text.contains('&');
    names && (2..=16).contains(&words.len()) && (listed || words.len() <= 3)
}

/// Free space above or below a block, as a heading has.
fn separated(blocks: &[Block], i: usize) -> bool {
    let b = &blocks[i];
    let before = i
        .checked_sub(1)
        .map(|j| &blocks[j])
        .is_none_or(|p| b.y0 - p.y1 > b.size.max(p.size));
    let after = blocks
        .get(i + 1)
        .is_none_or(|n| n.y0 - b.y1 > b.size.max(n.size));
    before || after
}

/// The largest text above the break line that reads like a title, on the
/// article's first page and, when that is the PDF's first, the second; then
/// on any cover page before it, which often repeats the title.
fn layout_titles(r: &Reading, first: usize, stop: Option<(usize, f32)>) -> Vec<Title> {
    let mut out = Vec::new();
    let mut pages = if first == 0 && r.pages.len() >= 2 {
        vec![0, 1]
    } else {
        vec![first]
    };
    pages.extend(0..first);
    for p in pages {
        let Some(page) = r.pages.get(p) else { continue };
        if p >= first && stop.is_some_and(|(sp, _)| p > sp) {
            continue;
        }
        let limit = stop.filter(|(sp, _)| *sp == p).map(|(_, y)| y);
        let bs = blocks(page);
        // A running head or foot is the journal's or a short title, never the title.
        let above = |b: &Block| {
            limit.is_none_or(|y| b.y0 < y) && !b.lines.iter().all(|l| running(r, p, l))
        };
        let threshold = title_size(page);
        let below = |i: usize| bs.get(i + 1).map(Block::text).filter(|t| !t.is_empty());
        // A manuscript's title page can label it, at the size of everything
        // else, wrapped onto the lines after it in the same font.
        if let Some(i) = page.lines.iter().position(|l| l.text.starts_with("Title:"))
            && limit.is_none_or(|y| page.lines[i].y0 < y)
        {
            let start = &page.lines[i];
            let mut parts = vec![start.text["Title:".len()..].trim()];
            let mut prev = start;
            for next in page.lines[i + 1..].iter().take(3) {
                if next.font != start.font
                    || (next.size - start.size).abs() > 0.5
                    || next.y0 - prev.y1 > 2.5 * start.size
                {
                    break;
                }
                parts.push(next.text.as_str());
                prev = next;
            }
            let text = clean_title(&join_lines(parts));
            if usable_title(&text) {
                out.push(Title { text, below: None });
            }
        }
        // Largest first; at the same size, author lines and addresses last.
        let mut order: Vec<usize> = (0..bs.len()).collect();
        let byline: Vec<bool> = bs.iter().map(|b| looks_like_byline(&b.text())).collect();
        order.sort_by(|&a, &b| bs[b].size.total_cmp(&bs[a].size).then(byline[a].cmp(&byline[b])));
        let mut found = 0;
        for i in order {
            let b = &bs[i];
            if !above(b) || b.size < threshold {
                continue;
            }
            let text = clean_title(&b.text());
            if usable_title(&text) {
                out.push(Title { text, below: below(i) });
                found += 1;
                if found == 2 {
                    break;
                }
            }
        }
        // Titles set in capitals at body size, with space around them.
        if found == 0 {
            for (i, b) in bs.iter().enumerate() {
                let text = clean_title(&b.text());
                if b.upper && above(b) && usable_title(&text) && separated(&bs, i) {
                    out.push(Title { text, below: below(i) });
                    break;
                }
            }
        }
    }
    out
}

/// A name written given name first ("Ashish Vaswani", "Ludwig van Beethoven")
/// as (family, given).
pub fn split_name(name: &str) -> Option<(String, String)> {
    let words: Vec<&str> = name
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphabetic() && c != '.' && c != '-' && c != '\''))
        .filter(|w| !w.is_empty())
        .collect();
    let (&last, rest) = words.split_last()?;
    let mut family = vec![last];
    let mut given = rest.to_vec();
    while let Some(&w) = given.last() {
        if ["van", "von", "de", "der", "den", "da", "di", "del", "della", "du", "dos", "la", "le"]
            .contains(&w)
        {
            family.insert(0, given.pop().unwrap());
        } else {
            break;
        }
    }
    Some((family.join(" "), given.join(" ")))
}

/// Authors from the document properties, which PDF makers fill with anything
/// from a full author list to "Administrator".
fn info_authors(s: &str) -> Vec<(String, String)> {
    let s = s.trim();
    if s.is_empty() || s.contains('@') || s.chars().any(|c| c.is_ascii_digit()) {
        return Vec::new();
    }
    let junk = ["administrator", "admin", "user", "author", "unknown", "owner", "microsoft", "default", "editor"];
    if s.split(|c: char| !c.is_alphabetic())
        .any(|w| junk.contains(&w.to_lowercase().as_str()))
    {
        return Vec::new();
    }
    let given_first = |parts: Vec<&str>| -> Vec<(String, String)> {
        parts
            .into_iter()
            .map(str::trim)
            .filter(|p| p.split_whitespace().count() >= 2)
            .filter_map(split_name)
            .collect()
    };
    if s.contains(';') {
        return given_first(s.split(';').collect());
    }
    let parts: Vec<&str> = s
        .split(" and ")
        .flat_map(|p| p.split('&'))
        .flat_map(|p| p.split(','))
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect();
    if parts.iter().all(|p| p.split_whitespace().count() >= 2) {
        return given_first(parts);
    }
    // "Smith, John" or "Smith, John, Doe, Jane": family names first.
    if !s.contains(" and ") && parts.len().is_multiple_of(2) {
        return parts
            .chunks(2)
            .map(|c| (c[0].to_string(), c[1].to_string()))
            .collect();
    }
    Vec::new()
}

/// Authors as BibTeX writes them: `Family, Given and Family, Given`.
pub fn bibtex_authors(authors: &[(String, String)]) -> String {
    authors
        .iter()
        .map(|(family, given)| {
            if given.is_empty() {
                family.clone()
            } else {
                format!("{family}, {given}")
            }
        })
        .collect::<Vec<_>>()
        .join(" and ")
}

/// Family names out of a BibTeX author list.
pub fn surnames(authors: &str) -> Vec<String> {
    authors
        .split(" and ")
        .map(|a| a.trim().trim_matches(['{', '}']))
        .filter(|a| !a.is_empty())
        .map(|a| match a.split_once(',') {
            Some((family, _)) => family.trim().to_string(),
            None => split_name(a).map(|(f, _)| f).unwrap_or_default(),
        })
        .collect()
}

/// An `arXiv:` identifier as arXiv stamps it in the margin of page one.
pub fn arxiv_id(text: &str) -> Option<String> {
    text.match_indices("arXiv:").find_map(|(i, m)| {
        let rest = text[i + m.len()..].strip_prefix(' ').unwrap_or(&text[i + m.len()..]);
        let token: String = rest
            .chars()
            .take_while(|c| !c.is_whitespace() && !"[](),;".contains(*c))
            .collect();
        crate::ingest::arxiv_id_from_text(&token)
    })
}

/// Cut a DOI at the bracket that closes around it, as in
/// "(10.1016/s1474-5151(03)00108-7)".
fn balance(doi: &str) -> &str {
    let mut depth = 0i32;
    for (i, c) in doi.char_indices() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => {
                depth -= 1;
                if depth < 0 {
                    return &doi[..i];
                }
            }
            _ => {}
        }
    }
    doi
}

/// DOIs in text, in order: `10.` and a 4–9 digit registrant, a slash and a suffix.
pub fn dois(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut from = 0;
    while let Some(at) = text[from..].find("10.") {
        let start = from + at;
        from = start + 3;
        if text[..start].chars().next_back().is_some_and(|c| c.is_alphanumeric()) {
            continue;
        }
        let digits = text[start + 3..].bytes().take_while(u8::is_ascii_digit).count();
        if !(4..=9).contains(&digits) || text.as_bytes().get(start + 3 + digits) != Some(&b'/') {
            continue;
        }
        let end = start + 4 + digits;
        let suffix = text[end..].split(char::is_whitespace).next().unwrap_or("");
        from = end + suffix.len();
        let doi = balance(&text[start..end + suffix.len()])
            .trim_end_matches(['.', ',', ';', ':', '"', '\'', '>', '’', '”']);
        if doi.len() > end - start {
            let doi = doi.to_ascii_lowercase();
            if !out.contains(&doi) {
                out.push(doi);
            }
        }
    }
    out
}

fn isbn_valid(isbn: &str) -> bool {
    let d: Vec<u32> = isbn
        .chars()
        .map(|c| if c == 'X' || c == 'x' { 10 } else { c.to_digit(10).unwrap_or(99) })
        .collect();
    match d.len() {
        10 => {
            d[..9].iter().all(|&x| x < 10)
                && d.iter().enumerate().map(|(i, x)| (10 - i as u32) * x).sum::<u32>() % 11 == 0
        }
        13 => {
            d.iter().all(|&x| x < 10)
                && d.iter()
                    .enumerate()
                    .map(|(i, x)| if i % 2 == 1 { 3 * x } else { *x })
                    .sum::<u32>()
                    % 10
                    == 0
        }
        _ => false,
    }
}

/// ISBNs labelled as such. More than three means a book citing other books.
pub fn isbn(text: &str) -> Option<String> {
    let mut found: Vec<String> = Vec::new();
    for (i, m) in text.match_indices("SBN").chain(text.match_indices("sbn")) {
        let mut rest = &text[i + m.len()..];
        rest = rest.strip_prefix([' ', '—', '–', '‒', '-']).unwrap_or(rest);
        rest = rest.strip_prefix("13").or_else(|| rest.strip_prefix("10")).unwrap_or(rest);
        rest = rest.trim_start_matches([':', ' ']);
        if !rest.starts_with(|c: char| c.is_ascii_digit() || c == 'X') {
            continue;
        }
        let run: String = rest
            .chars()
            .take_while(|c| c.is_ascii_digit() || "X —–‒-".contains(*c))
            .filter(|c| c.is_ascii_digit() || *c == 'X')
            .collect();
        let mut keep = |s: &str| {
            if isbn_valid(s) && !found.iter().any(|f| f == s) {
                found.push(s.to_string());
            }
        };
        match run.len() {
            10 | 13 => keep(&run),
            20 | 26 => keep(&run[..run.len() / 2]),
            23 => {
                keep(&run[..13]);
                keep(&run[..10]);
            }
            _ => {}
        }
    }
    (1..=3).contains(&found.len()).then(|| found.swap_remove(0))
}

/// A line repeated at the same place on a page or two before or after: a
/// running head or foot. Springer repeats the title as one, elsewhere.
fn running(r: &Reading, p: usize, a: &Line) -> bool {
    let page = &r.pages[p];
    if a.y0 < 5.0 || a.y1 > page.height - 5.0 {
        return false;
    }
    r.pages
        .iter()
        .enumerate()
        .filter(|(q, _)| *q != p && q.abs_diff(p) <= 2)
        .any(|(_, other)| {
            other.lines.iter().any(|b| {
                (a.x0 - b.x0).abs() < 10.0
                    && (a.y0 - b.y0).abs() < 10.0
                    && ((a.x1 - a.x0) - (b.x1 - b.x0)).abs() < 10.0
                    && ((a.y1 - a.y0) - (b.y1 - b.y0)).abs() < 10.0
                    && a.text == b.text
            })
        })
}

/// Running heads and feet, where journals print the year.
fn running_text(r: &Reading) -> String {
    let mut out: Vec<&str> = Vec::new();
    for (p, page) in r.pages.iter().enumerate() {
        for a in &page.lines {
            let skip = a.text.to_lowercase().contains("download") || a.text.contains("http");
            if !skip && !out.contains(&a.text.as_str()) && running(r, p, a) {
                out.push(&a.text);
            }
        }
    }
    out.join("\n")
}

/// The first plausible year standing on its own in `text`.
fn year_in(text: &str) -> Option<String> {
    let now = 1970
        + std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() / 31_556_952)
            .unwrap_or(56) as i64;
    text.split(|c: char| c.is_whitespace() || "(),".contains(c))
        .filter(|w| w.len() == 4 && w.bytes().all(|b| b.is_ascii_digit()))
        .filter_map(|w| w.parse::<i64>().ok())
        .find(|y| (1800..=now + 1).contains(y))
        .map(|y| y.to_string())
}

impl Clues {
    pub fn read(r: &Reading) -> Self {
        let raw: String = r.pages.iter().map(|p| p.text.as_str()).collect::<Vec<_>>().join("\n");
        let all = letters(&raw);
        let first = first_page(r);
        let mut head = String::new();
        for (i, page) in r.pages.iter().enumerate() {
            // The page after the first too when the first has almost nothing on it.
            if i > first && (i > first + 1 || head.len() >= 300) {
                break;
            }
            head.push_str(&letters(&page.text));
        }
        let abstract_found = abstract_text(r, first);
        let mut stop = break_line(r, first);
        if let Some((_, p, y)) = &abstract_found
            && stop.is_none_or(|(sp, sy)| *p < sp || *p == sp && *y < sy)
        {
            stop = Some((*p, *y));
        }

        // The document properties' title counts only when it is printed in the PDF.
        let mut titles: Vec<Title> = Vec::new();
        if let Some(t) = info(r, "Title")
            && letters(t).len() >= 15
            && all.contains(&letters(t))
        {
            titles.push(Title { text: clean_title(t), below: None });
        }
        for t in layout_titles(r, first, stop) {
            if !titles.iter().any(|o| letters(&o.text) == letters(&t.text)) {
                titles.push(t);
            }
        }
        titles.truncate(3);

        let info_doi = r
            .info
            .iter()
            .filter(|(k, _)| ["doi", "wps-articledoi", "subject"].contains(&k.to_lowercase().as_str()))
            .find_map(|(_, v)| dois(v).into_iter().next());
        let mut found_dois = Vec::new();
        if let Some(first_text) = r.pages.first().map(|p| p.text.as_str()) {
            // JSTOR cover pages give a stable URL; JSTOR's DOIs are 10.2307/ and its number.
            if let Some((_, rest)) = first_text.split_once("jstor.org/stable/") {
                let id: String = rest.chars().take_while(char::is_ascii_digit).collect();
                if !id.is_empty() {
                    found_dois.push(format!("10.2307/{id}"));
                }
            }
        }
        for doi in r.pages.iter().take(2).flat_map(|p| dois(&p.text)) {
            if !found_dois.contains(&doi) {
                found_dois.push(doi);
            }
        }
        let isbn = info(r, "isbn")
            .map(|s| s.chars().filter(|c| c.is_ascii_digit() || *c == 'X').collect::<String>())
            .filter(|s| isbn_valid(s))
            .or_else(|| isbn(&raw));

        Clues {
            has_text: !all.is_empty(),
            arxiv: r.pages.first().and_then(|p| arxiv_id(&p.text)),
            info_doi,
            dois: found_dois,
            isbn,
            titles,
            authors: info(r, "Author").map(info_authors).unwrap_or_default(),
            abstract_text: abstract_found.map(|(t, _, _)| t),
            year: year_in(&running_text(r)),
            head,
            all,
            raw,
        }
    }

    /// Whether a record found online is the paper in hand: its title printed
    /// on the first pages and, for a shorter title, its first or first two
    /// authors' surnames printed too. Zotero's rule for matching titles to
    /// DOIs; surnames under four letters match too much to count.
    pub fn printed(&self, title: &str, surnames: &[String]) -> bool {
        // Indexes add a note the paper doesn't print: "… (Short Paper)".
        let bare = title
            .trim_end()
            .strip_suffix(')')
            .and_then(|t| t.rsplit_once('('))
            .map(|(t, _)| t);
        self.printed_as(title, surnames) || bare.is_some_and(|t| self.printed_as(t, surnames))
    }

    fn printed_as(&self, title: &str, surnames: &[String]) -> bool {
        let t = letters(title);
        let n = t.chars().count();
        if n < 10 || !self.head.contains(&t) {
            return false;
        }
        let names: Vec<String> = surnames.iter().take(2).map(|s| letters(s)).collect();
        let long = |s: &String| s.chars().count() >= 4;
        let found = |i: usize| names.get(i).is_some_and(|s| long(s) && self.all.contains(s.as_str()));
        let short = |i: usize| names.get(i).is_none_or(|s| !long(s));
        match n {
            50.. => true,
            30..50 => found(0) || found(1),
            _ => found(0) && (short(1) || found(1)),
        }
    }

    /// Whether `phrase` (a book title, a journal name) appears anywhere in the pages read.
    pub fn mentions(&self, phrase: &str) -> bool {
        let p = letters(phrase);
        p.len() >= 6 && self.all.contains(&p)
    }

    /// Whether `year` is printed in the pages read.
    pub fn has_year(&self, year: &str) -> bool {
        year.len() == 4 && self.raw.contains(year)
    }

    /// A first author for narrowing a title search: from the document
    /// properties, or the first two capitalized words under the title.
    pub fn author_hint(&self, title: &Title) -> Option<String> {
        if let Some((family, _)) = self.authors.first() {
            return Some(family.clone());
        }
        let below = title.below.as_deref()?;
        let skip = ["University", "Department", "Institute", "School", "College", "Center", "Centre", "Laboratory", "The", "And"];
        let words: Vec<&str> = below
            .split(|c: char| c.is_whitespace() || c == ',')
            .map(|w| w.trim_matches(|c: char| !c.is_alphabetic()))
            .take_while(|w| {
                w.chars().next().is_some_and(char::is_uppercase)
                    && w.chars().skip(1).all(|c| c.is_lowercase() || c == '-' || c == '\'')
                    && w.chars().count() >= 2
                    && !skip.contains(w)
            })
            .take(2)
            .collect();
        (words.len() == 2).then(|| words.join(" "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, y: f32, size: f32, font: &str) -> Line {
        Line {
            text: text.into(),
            x0: 72.0,
            y0: y,
            x1: 72.0 + text.len() as f32 * size * 0.5,
            y1: y + size,
            size,
            font: font.into(),
            bold: false,
            fonts: vec![font.into()],
            sizes: vec![size],
        }
    }

    fn page(lines: Vec<Line>) -> Page {
        let text = lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join("\n");
        let mut sizes: Vec<(f32, usize)> = Vec::new();
        for l in &lines {
            match sizes.iter_mut().find(|(s, _)| *s == l.size) {
                Some((_, n)) => *n += l.text.len(),
                None => sizes.push((l.size, l.text.len())),
            }
        }
        Page { width: 612.0, height: 792.0, lines, text, sizes }
    }

    fn body(y: f32) -> Vec<Line> {
        (0..12)
            .map(|i| line("Body text of the paper goes on at length about methods and results here.", y + i as f32 * 12.0, 10.0, "Times"))
            .collect()
    }

    fn paper() -> Reading {
        let mut lines = vec![
            line("Journal of Network Science 12 (2024) 1–20", 30.0, 8.0, "Times"),
            line("Sparse Attention Is Enough for Long-Docu-", 80.0, 18.0, "TimesBold"),
            line("ment Retrieval", 102.0, 18.0, "TimesBold"),
            line("Ada Okafor, Bea Lindqvist", 140.0, 11.0, "Times"),
            line("Abstract", 180.0, 10.0, "TimesBold"),
            line("We show that sparse attention retrieves long documents as well as dense attention", 194.0, 10.0, "Times"),
            line("does, at a fraction of the cost, across four benchmarks and three languages, and", 206.0, 10.0, "Times"),
            line("explain why with a simple model of where relevant passages sit in a document.", 218.0, 10.0, "Times"),
            line("Keywords: attention, retrieval", 240.0, 10.0, "Times"),
            line("1 Introduction", 270.0, 12.0, "TimesBold"),
        ];
        lines.extend(body(290.0));
        let mut second = vec![line("Journal of Network Science 12 (2024) 1–20", 30.0, 8.0, "Times")];
        second.extend(body(60.0));
        second.push(line("See also 10.1038/30918 and arXiv:2401.01234.", 500.0, 10.0, "Times"));
        Reading {
            page_count: 2,
            info: vec![("Author".into(), "Ada Okafor; Bea Lindqvist".into()), ("doi".into(), "10.5555/sparse.2024.1".into())],
            pages: vec![page(lines), page(second)],
        }
    }

    #[test]
    fn title_is_the_largest_text_joined_across_lines() {
        let c = Clues::read(&paper());
        assert_eq!(c.titles[0].text, "Sparse Attention Is Enough for Long-Document Retrieval");
        assert_eq!(c.titles[0].below.as_deref(), Some("Ada Okafor, Bea Lindqvist"));
        assert_eq!(c.authors, vec![("Okafor".into(), "Ada".into()), ("Lindqvist".into(), "Bea".into())]);
        assert_eq!(c.author_hint(&c.titles[0]).as_deref(), Some("Okafor"));
        assert!(c.abstract_text.as_deref().unwrap().starts_with("We show that sparse attention"));
        assert!(c.abstract_text.as_deref().unwrap().ends_with("in a document."));
        assert_eq!(c.year.as_deref(), Some("2024"));
        assert_eq!(c.info_doi.as_deref(), Some("10.5555/sparse.2024.1"));
        assert_eq!(c.dois, vec!["10.1038/30918"]);
        // arXiv IDs count on page one only, where arXiv stamps them.
        assert_eq!(c.arxiv, None);
    }

    #[test]
    fn a_title_beats_an_author_line_set_as_large() {
        let mut lines = vec![
            line("Cas Mudde and Cristobal Rovira Kaltwasser", 60.0, 14.0, "Times"),
            line("Exclusionary vs. Inclusionary Populism:", 90.0, 14.0, "Times"),
            line("Comparing Contemporary Europe and", 108.0, 14.0, "Times"),
            line("Latin America", 126.0, 14.0, "Times"),
        ];
        lines.extend(body(170.0));
        let r = Reading { page_count: 1, info: vec![], pages: vec![page(lines)] };
        let c = Clues::read(&r);
        assert_eq!(c.titles[0].text, "Exclusionary vs. Inclusionary Populism: Comparing Contemporary Europe and Latin America");
    }

    #[test]
    fn an_affiliation_set_like_the_title_comes_after_it() {
        let mut lines = vec![
            line("Post-postfeminism? New feminist visibilities in postfeminist times", 120.0, 12.0, "TimesBold"),
            line("Department of Sociology, City University London, Northampton Square, London", 300.0, 12.0, "TimesBold"),
        ];
        lines.extend(body(400.0));
        let r = Reading { page_count: 1, info: vec![], pages: vec![page(lines)] };
        assert_eq!(Clues::read(&r).titles[0].text, "Post-postfeminism? New feminist visibilities in postfeminist times");
        assert!(looks_like_byline("Ian Hawkins, Niels G. Mede & Sedona Chinn"));
        assert!(looks_like_byline("Rosalind Gill"));
        assert!(!looks_like_byline("Attention Is All You Need"));
        assert!(!looks_like_byline("Deep Residual Learning for Image Recognition"));
    }

    #[test]
    fn a_running_head_is_not_a_title_and_a_cover_page_can_give_one() {
        // A publisher's cover with the title, then the manuscript, whose first
        // page has only the running head above its abstract.
        let mut cover = page(vec![
            line("Fertile ground to problematic views? How dark and", 155.0, 28.0, "Myriad"),
            line("mainstream social media relate to conspiracy beliefs", 185.0, 28.0, "Myriad"),
        ]);
        cover.width = 595.0;
        let manuscript = |abstract_too: bool| {
            let mut lines = vec![line("ONLINE PLATFORMS & PROBLEMATIC VIEWS", 76.0, 11.0, "Arial")];
            if abstract_too {
                lines.push(line("Abstract", 112.0, 12.0, "TimesBold"));
            }
            lines.extend(body(140.0));
            page(lines)
        };
        let r = Reading {
            page_count: 4,
            info: vec![],
            pages: vec![cover, manuscript(true), manuscript(false), manuscript(false)],
        };
        assert_eq!(first_page(&r), 1);
        let c = Clues::read(&r);
        assert_eq!(c.titles.len(), 1, "{:?}", c.titles);
        assert_eq!(c.titles[0].text, "Fertile ground to problematic views? How dark and mainstream social media relate to conspiracy beliefs");
    }

    #[test]
    fn a_title_repeated_as_a_running_head_elsewhere_is_still_the_title() {
        let head = |title: &str| line(title, 30.0, 8.0, "Myriad");
        let mut first = vec![line("The Epistemic Costs of Super-Persuasive AI", 90.0, 13.0, "MyriadBold")];
        first.extend(body(200.0));
        let mut later = vec![head("The Epistemic Costs of Super-Persuasive AI")];
        later.extend(body(60.0));
        let r = Reading { page_count: 3, info: vec![], pages: vec![page(first), page(later.clone()), page(later)] };
        assert_eq!(Clues::read(&r).titles[0].text, "The Epistemic Costs of Super-Persuasive AI");
    }

    #[test]
    fn a_labelled_title_on_a_manuscript_title_page() {
        let mut lines = vec![
            line("Title: The (anti-)conformity strategy space: How flexible is social learning", 233.0, 12.0, "Bold"),
            line("when group membership and incentive alignment vary?", 257.0, 12.0, "Bold"),
        ];
        lines.extend(body(300.0).into_iter().map(|mut l| { l.size = 12.0; l.sizes = vec![12.0]; l }));
        let r = Reading { page_count: 1, info: vec![], pages: vec![page(lines)] };
        assert_eq!(
            Clues::read(&r).titles[0].text,
            "The (anti-)conformity strategy space: How flexible is social learning when group membership and incentive alignment vary?"
        );
    }

    #[test]
    fn a_cover_sheet_saying_keywords_does_not_hide_the_title() {
        let mut r = paper();
        let mut cover = page(vec![line("Keywords: none given on this repository cover sheet", 100.0, 12.0, "Arial")]);
        cover.width = 595.0;
        r.pages.insert(0, cover);
        r.pages.push(page(body(60.0)));
        let c = Clues::read(&r);
        assert_eq!(c.titles[0].text, "Sparse Attention Is Enough for Long-Document Retrieval");
    }

    #[test]
    fn titles_stop_at_the_abstract() {
        let mut r = paper();
        // A larger line under the abstract, e.g. a pull quote, is not the title.
        r.pages[0].lines.push(line("A Pull Quote Set Very Large Indeed Here", 600.0, 30.0, "TimesBold"));
        let c = Clues::read(&r);
        assert!(c.titles.iter().all(|t| !t.text.contains("Pull Quote")), "{:?}", c.titles);
    }

    #[test]
    fn a_cover_page_of_another_width_is_skipped() {
        let mut r = paper();
        let mut cover = page(vec![
            line("Downloaded from the Repository of Everything Online", 100.0, 20.0, "Arial"),
            line("This copy is provided for personal research use only", 140.0, 12.0, "Arial"),
        ]);
        cover.width = 595.0;
        r.pages.insert(0, cover);
        r.pages.push(page(body(60.0)));
        assert_eq!(first_page(&r), 1);
        let c = Clues::read(&r);
        assert_eq!(c.titles[0].text, "Sparse Attention Is Enough for Long-Document Retrieval");
    }

    #[test]
    fn printed_follows_zoteros_title_and_author_rule() {
        let mut r = paper();
        r.pages[0].text.push_str("\nA very long subtitle that is printed on the first page of this paper too");
        let c = Clues::read(&r);
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        // 50 letters or more printed on the page are enough on their own.
        assert!(c.printed("A very long subtitle that is printed on the first page of this paper", &[]));
        // A title that isn't printed never matches, whoever wrote it.
        assert!(!c.printed("Dense attention is required", &s(&["Okafor"])));
        // 30 to 49 letters need either of the first two surnames on the page.
        let title = "Sparse attention is enough for long‐document retrieval";
        assert!(c.printed(title, &s(&["Smith", "Lindqvist"])));
        assert!(!c.printed(title, &s(&["Smith", "Jones"])));
        // A note an index adds to the title doesn't have to be printed.
        assert!(c.printed(&format!("{title} (Short Paper)"), &s(&["Smith", "Lindqvist"])));
        assert!(!c.printed("Dense attention is required (Short Paper)", &s(&["Okafor"])));
        // Fewer need both, unless there is only one author.
        assert!(c.printed("Sparse Attention", &s(&["Okafor", "Lindqvist"])));
        assert!(c.printed("Sparse Attention", &s(&["Okafor"])));
        assert!(!c.printed("Sparse Attention", &s(&["Okafor", "Jones"])));
    }

    #[test]
    fn arxiv_stamp_doi_and_isbn_forms() {
        assert_eq!(arxiv_id("arXiv:1706.03762v7  [cs.CL]  2 Aug 2023").as_deref(), Some("1706.03762"));
        assert_eq!(arxiv_id("arXiv: hep-th/9901001v2").as_deref(), Some("hep-th/9901001"));
        assert_eq!(arxiv_id("see 1706.03762"), None);
        assert_eq!(
            dois("(doi:10.1016/s1474-5151(03)00108-7). https://doi.org/10.1145/3292500.3330701, x210.1234/no"),
            vec!["10.1016/s1474-5151(03)00108-7", "10.1145/3292500.3330701"]
        );
        assert_eq!(dois("DOI 10.1038/NATURE14539."), vec!["10.1038/nature14539"]);
        assert_eq!(isbn("ISBN 978-0-262-03384-8 (hardcover)").as_deref(), Some("9780262033848"));
        assert_eq!(isbn("ISBN-10: 0-262-03384-4").as_deref(), Some("0262033844"));
        // A bad checksum is a page number or a phone number, not an ISBN.
        assert_eq!(isbn("ISBN 978-0-262-03384-9"), None);
        let many = "ISBN 9780262033848 ISBN 0262033844 ISBN 9780131103627 ISBN 0131103628";
        assert_eq!(isbn(many), None);
    }

    #[test]
    fn names_and_joins() {
        assert_eq!(join_lines(["Deep Residual Learn-", "ing for Image Recog-", "nition"]), "Deep Residual Learning for Image Recognition");
        assert_eq!(join_lines(["Self-", "Supervised Learning"]), "Self-Supervised Learning");
        assert_eq!(split_name("Ludwig van Beethoven"), Some(("van Beethoven".into(), "Ludwig".into())));
        assert_eq!(info_authors("Smith, John"), vec![("Smith".into(), "John".into())]);
        assert_eq!(info_authors("John Smith, Jane Doe and Ann Lee").len(), 3);
        assert!(info_authors("Administrator").is_empty());
        assert!(info_authors("jsmith").is_empty());
        assert_eq!(surnames("Watts, Duncan J. and {OpenAI} and Steven Strogatz"), vec!["Watts", "OpenAI", "Strogatz"]);
        assert!(is_section_break("1 Introduction"));
        assert!(is_section_break("I. INTRODUCTION"));
        assert!(!is_section_break("introduction of the method"));
    }
}

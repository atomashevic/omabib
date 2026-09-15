.pragma library

// Small, pure formatting helpers shared by the list and the detail pane.

function _names(authors) {
  return String(authors || "").split(/\s+and\s+/)
    .map(function (n) { return n.trim() })
    .filter(function (n) { return n.length > 0 && n.toLowerCase() !== "arxiv" })
}

function _family(name) {
  var n = name.replace(/^\{|\}$/g, "")
  if (n.indexOf(",") >= 0) return n.split(",")[0].trim()
  var parts = n.split(/\s+/)
  return parts[parts.length - 1]
}

// "Wang et al.", "Das & Pal", "Smaldino".
function shortAuthors(authors) {
  var names = _names(authors)
  if (!names.length) return ""
  if (names.length === 1) return _family(names[0])
  if (names.length === 2) return _family(names[0]) + " & " + _family(names[1])
  return _family(names[0]) + " et al."
}

// "Steven Wang, Kyle Hunt, …" in reading order, capped with "+N more".
function fullAuthors(authors, cap) {
  var names = _names(authors).map(function (n) {
    n = n.replace(/^\{|\}$/g, "")
    if (n.indexOf(",") < 0) return n
    var i = n.indexOf(",")
    return (n.slice(i + 1).trim() + " " + n.slice(0, i).trim()).trim()
  })
  if (cap && names.length > cap) return names.slice(0, cap).join(", ") + ", +" + (names.length - cap) + " more"
  return names.join(", ")
}

function relativeTime(iso, now) {
  if (!iso) return ""
  var t = Date.parse(String(iso).replace(" ", "T") + (/[zZ]|[+-]\d\d:?\d\d$/.test(iso) ? "" : "Z"))
  var ms = (now === undefined ? Date.now() : now) - t
  if (isNaN(ms)) return ""
  var s = Math.floor(ms / 1000)
  if (s < 60) return "just now"
  var m = Math.floor(s / 60); if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60); if (h < 24) return h + "h ago"
  var d = Math.floor(h / 24); if (d < 30) return d + "d ago"
  return new Date(t).toISOString().slice(0, 10)
}

function shortDate(iso) {
  var t = Date.parse(String(iso || ""))
  if (isNaN(t)) return ""
  var d = new Date(t)
  var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
  return d.getDate() + " " + months[d.getMonth()] + " " + d.getFullYear()
}

function basename(path) {
  var s = String(path || "")
  return s.slice(s.lastIndexOf("/") + 1)
}

function dirname(path, home) {
  var s = String(path || "")
  var dir = s.slice(0, Math.max(0, s.lastIndexOf("/")))
  if (home && dir.indexOf(home) === 0) dir = "~" + dir.slice(home.length)
  return dir
}

// The arXiv identifier of a fetched reference: its DOI when inferred from
// arXiv, or an arxiv.org URL / eprint field.
function arxivId(ref) {
  if (!ref || !ref.fields) return ""
  var f = ref.fields
  var m = /^10\.48550\/arxiv\.(.+)$/i.exec(f.doi || "")
  if (m) return m[1]
  m = /arxiv\.org\/(?:abs|pdf)\/([^\s?#]+)/i.exec((f.url || "") + " " + (f.eprint || ""))
  if (m) return m[1].replace(/\.pdf$/i, "")
  if (/^\d{4}\.\d{4,5}(v\d+)?$/.test(f.eprint || "")) return f.eprint
  return ""
}

function venue(ref) {
  if (!ref || !ref.fields) return ""
  var f = ref.fields
  return f.journal || f.journaltitle || f.booktitle || f.publisher || f.institution || f.school || ""
}

// "PDF p. 4 · /path/file.pdf" -> "p. 4"; other evidence is shown as written.
function evidenceLabel(evidence) {
  var s = String(evidence || "")
  var m = /\bp\.\s*(\d+)/i.exec(s)
  if (m && /^PDF\b/i.test(s)) return "p. " + m[1]
  return s.length > 48 ? s.slice(0, 47) + "…" : s
}

// One field's value from a BibTeX entry, braces or quotes stripped, for the
// add preview. Nested braces are kept balanced; LaTeX is left as written.
function bibField(bibtex, name) {
  var s = String(bibtex || "")
  var re = new RegExp("(^|[,\\s])" + name + "\\s*=\\s*", "i")
  var m = re.exec(s)
  if (!m) return ""
  var i = m.index + m[0].length
  var open = s.charAt(i)
  if (open === "{") {
    var depth = 0
    for (var j = i; j < s.length; j++) {
      if (s.charAt(j) === "{") depth++
      else if (s.charAt(j) === "}" && --depth === 0) return s.slice(i + 1, j).replace(/[{}]/g, "").replace(/\s+/g, " ").trim()
    }
    return ""
  }
  if (open === "\"") {
    var end = s.indexOf("\"", i + 1)
    return end < 0 ? "" : s.slice(i + 1, end).replace(/[{}]/g, "").replace(/\s+/g, " ").trim()
  }
  var bare = /^[^,}\s]+/.exec(s.slice(i))
  return bare ? bare[0] : ""
}

function host(url) {
  var m = /^https?:\/\/(?:www\.)?([^\/?#:]+)/i.exec(String(url || ""))
  return m ? m[1] : ""
}

.pragma library

// Turns an alphaXiv overview (Markdown) into typed blocks the AI summary tab
// lays out one by one, so headings, lists and tables get real typography and
// the section strip can scroll to a heading.
//
// Escape first: every piece of source text is HTML-escaped before a fixed,
// attribute-free set of StyledText tags (<b>, <i>, <tt>) is added. The one
// attribute emitted is a link's href, and only for http(s) URLs.

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function _safeUrl(url) {
  var u = String(url || "").trim()
  return /^https?:\/\/[^\s"'<>]+$/i.test(u) ? u : ""
}

// Inline Markdown for one already-unescaped line: code, links, bold, italic.
function inline(source) {
  var out = ""
  var s = String(source || "")
  var i = 0
  while (i < s.length) {
    var ch = s.charAt(i)
    if (ch === "`") {
      var close = s.indexOf("`", i + 1)
      if (close > i) {
        out += "<tt>" + escapeHtml(s.slice(i + 1, close)) + "</tt>"
        i = close + 1
        continue
      }
    }
    if (ch === "[") {
      var m = /^\[([^\]]+)\]\(([^)\s]+)\)/.exec(s.slice(i))
      if (m) {
        var url = _safeUrl(m[2])
        out += url ? "<a href=\"" + escapeHtml(url) + "\">" + _emphasis(m[1]) + "</a>" : _emphasis(m[1])
        i += m[0].length
        continue
      }
    }
    var next = s.slice(i).search(/[`\[]/)
    var end = next <= 0 ? (next === 0 ? i + 1 : s.length) : i + next
    out += _emphasis(s.slice(i, end))
    i = end
  }
  return out
}

function _emphasis(text) {
  var e = escapeHtml(text)
  e = e.replace(/\*\*([^*]+?)\*\*/g, "<b>$1</b>").replace(/__([^_]+?)__/g, "<b>$1</b>")
  e = e.replace(/(^|[\s(])\*([^*\s][^*]*?)\*(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>")
  e = e.replace(/(^|[\s(])_([^_\s][^_]*?)_(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>")
  return e
}

function _isTitle(line) {
  return /^#\s/.test(line) || /^##\s+(Research Report:|AI Overview)/i.test(line)
}

function _splitRow(line) {
  var t = line.trim().replace(/^\|/, "").replace(/\|$/, "")
  return t.split("|").map(function (c) { return c.trim() })
}

// Blocks: {type:"h2"|"h3"|"p"|"ol"|"ul"|"quote"|"code"|"table"|"hr", ...}
//   h2/h3: {number, html, text}
//   p/quote: {html}
//   ol/ul: {items:[{marker, html, detail, sub:[html]}]}
//   code: {text}
//   table: {header:[html], rows:[[html]]}
// The shallowest ##–#### heading level outside code fences. Overviews use
// either ## or ### for their numbered sections; that level becomes "h2".
function _sectionLevel(lines) {
  var level = 2, found = 5, inFence = false
  for (var i = 0; i < lines.length; i++) {
    var t = lines[i].trim()
    if (/^(```|~~~)/.test(t)) { inFence = !inFence; continue }
    var h = !inFence && /^(#{2,4})\s+\S/.exec(t)
    if (h && !_isTitle(t)) found = Math.min(found, h[1].length)
  }
  return found < 5 ? found : level
}

function blocks(markdown) {
  var lines = String(markdown || "").replace(/\r\n?/g, "\n").split("\n")
  var sectionLevel = _sectionLevel(lines)
  var out = []
  var para = []
  var sawTitle = false
  function flush() {
    if (para.length) out.push({ type: "p", html: inline(para.join(" ")) })
    para = []
  }
  var i = 0
  while (i < lines.length) {
    var line = lines[i]
    var trimmed = line.trim()
    if (!sawTitle && out.length === 0 && para.length === 0 && _isTitle(trimmed)) {
      sawTitle = true
      i++
      continue
    }
    var fence = /^(```|~~~)/.exec(trimmed)
    if (fence) {
      flush()
      var code = []
      i++
      while (i < lines.length && lines[i].trim().indexOf(fence[1]) !== 0) { code.push(lines[i]); i++ }
      out.push({ type: "code", text: code.join("\n") })
      i++
      continue
    }
    var h = /^(#{2,4})\s+(.*)$/.exec(trimmed)
    if (h) {
      flush()
      var level = h[1].length <= sectionLevel ? "h2" : "h3"
      var num = /^(\d+(?:\.\d+)*)\.?\s+(.*)$/.exec(h[2])
      var text = num ? num[2] : h[2]
      out.push({ type: level, number: num ? num[1] : "", text: text.replace(/\*\*/g, ""), html: inline(text) })
      i++
      continue
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) { flush(); out.push({ type: "hr" }); i++; continue }
    if (/^\|.*\|$/.test(trimmed) && i + 1 < lines.length && /^\|?\s*:?-{2,}/.test(lines[i + 1].trim())) {
      flush()
      var header = _splitRow(trimmed).map(inline)
      var rows = []
      i += 2
      while (i < lines.length && /^\|.*\|$/.test(lines[i].trim())) { rows.push(_splitRow(lines[i]).map(inline)); i++ }
      out.push({ type: "table", header: header, rows: rows })
      continue
    }
    var listMatch = /^(\s*)(\d+[.)]|[-*+])\s+(.*)$/.exec(line)
    if (listMatch && listMatch[1].length < 2) {
      flush()
      var ordered = /\d/.test(listMatch[2])
      var items = []
      while (i < lines.length) {
        var lm = /^(\s*)(\d+[.)]|[-*+])\s+(.*)$/.exec(lines[i])
        if (!lm || lm[1].length >= 2 || /\d/.test(lm[2]) !== ordered) break
        var head = lm[3].replace(/\s{2,}$/, "")
        var detail = []
        var sub = []
        i++
        // Indented lines belong to this item: nested bullets become `sub`,
        // other text continues the last nested bullet or the item's detail.
        while (i < lines.length && (/^\s{2,}\S/.test(lines[i]) || (/^\s*$/.test(lines[i]) && i + 1 < lines.length && /^\s{2,}\S/.test(lines[i + 1])))) {
          var nested = /^\s{2,}(\d+[.)]|[-*+])\s+(.*)$/.exec(lines[i])
          if (nested) sub.push(nested[2].trim())
          else if (lines[i].trim() && sub.length) sub[sub.length - 1] += " " + lines[i].trim()
          else if (lines[i].trim()) detail.push(lines[i].trim())
          i++
        }
        items.push({ marker: ordered ? lm[2].replace(")", ".") : "•", html: inline(head), detail: detail.length ? inline(detail.join(" ")) : "", sub: sub.map(inline) })
        while (i < lines.length && lines[i].trim() === "" && i + 1 < lines.length && /^(\s*)(\d+[.)]|[-*+])\s/.test(lines[i + 1]) && /^(\s*)/.exec(lines[i + 1])[1].length < 2) i++
      }
      out.push({ type: ordered ? "ol" : "ul", items: items })
      continue
    }
    if (/^>\s?/.test(trimmed)) {
      flush()
      var quote = []
      while (i < lines.length && /^>\s?/.test(lines[i].trim())) { quote.push(lines[i].trim().replace(/^>\s?/, "")); i++ }
      out.push({ type: "quote", html: inline(quote.join(" ")) })
      continue
    }
    if (trimmed === "") { flush(); i++; continue }
    para.push(trimmed)
    i++
  }
  flush()
  return out
}

// Top-level sections for the jump strip: [{block, number, title}].
function sections(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].type === "h2") out.push({ block: i, number: list[i].number, title: _shortTitle(list[i].text) })
  }
  return out
}

var _SHORT = [
  [/^authors?\b/i, "Authors"], [/landscape|context|background|related/i, "Landscape"],
  [/objective|motivation|goal/i, "Objectives"], [/method|approach/i, "Methodology"],
  [/finding|result/i, "Findings"], [/significance|impact|implication/i, "Significance"],
  [/limitation/i, "Limitations"], [/conclusion/i, "Conclusion"]
]

function _shortTitle(text) {
  for (var i = 0; i < _SHORT.length; i++) if (_SHORT[i][0].test(text)) return _SHORT[i][1]
  var words = String(text).split(/\s+/)
  return words.slice(0, 3).join(" ")
}

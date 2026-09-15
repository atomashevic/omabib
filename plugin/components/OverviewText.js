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

// One rich-text document for a selectable TextEdit, so a selection can run
// across paragraphs. Block html is already escaped; only fixed tags and the
// style values passed in (colors and sizes from the theme) are added.
//   s: {reading, mono, size, heading, small, text, bright, muted, dim, line, codeBg, link}
function toHtml(list, s) {
  function css(pairs) { return pairs.join(";") }
  function emphasize(html) {
    return String(html)
      .replace(/<b>/g, "<b><font color=\"" + s.bright + "\">").replace(/<\/b>/g, "</font></b>")
      .replace(/<a href="([^"]*)">/g, "<a href=\"$1\"><font color=\"" + s.link + "\">").replace(/<\/a>/g, "</font></a>")
  }
  var para = css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "line-height:160%"])
  var out = ["<body style=\"" + css(["font-family:'" + s.reading + "'", "font-size:" + s.size + "px", "color:" + s.text]) + "\">"]
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    var first = out.length === 1
    if (b.type === "h2" || b.type === "h3") {
      var major = b.type === "h2"
      var number = b.number ? "<span style=\"" + css(["font-family:'" + s.mono + "'", "font-size:" + (major ? s.small + 1 : s.small) + "px", "font-weight:400", "color:" + s.dim]) + "\">" + b.number + "</span>&nbsp;&nbsp;&nbsp;" : ""
      // A styled <p>, not <h2>/<h3>: Qt scales heading tags past the given size.
      var tag = "p"
      out.push("<" + tag + " style=\"" + css(["margin-top:" + (first ? 0 : major ? Math.round(s.size * 1.6) : Math.round(s.size * 0.9)) + "px", "margin-bottom:" + Math.round(s.size * 0.5) + "px", "font-size:" + (major ? s.heading : s.size) + "px", "font-weight:600", "color:" + s.bright]) + "\">" + number + emphasize(b.html) + "</" + tag + ">")
    } else if (b.type === "p") {
      out.push("<p style=\"" + para + "\">" + emphasize(b.html) + "</p>")
    } else if (b.type === "ol" || b.type === "ul") {
      var items = b.items.map(function (item) {
        var body = emphasize(item.html)
        if (item.detail) body += "<br><font color=\"" + s.muted + "\">" + emphasize(item.detail) + "</font>"
        if (item.sub && item.sub.length) {
          body += "<ul style=\"" + css(["margin-top:" + Math.round(s.size * 0.4) + "px", "margin-bottom:0", "list-style-type:circle"]) + "\">"
            + item.sub.map(function (sub) { return "<li style=\"" + css(["margin-bottom:0", "line-height:150%"]) + "\">" + emphasize(sub) + "</li>" }).join("")
            + "</ul>"
        }
        return "<li style=\"" + css(["margin-bottom:" + Math.round(s.size * 0.15) + "px", "line-height:150%"]) + "\">" + body + "</li>"
      }).join("")
      var listTag = b.type
      out.push("<" + listTag + " style=\"" + css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "list-style-type:" + (listTag === "ol" ? "decimal" : "disc")]) + "\">" + items + "</" + listTag + ">")
    } else if (b.type === "quote") {
      out.push("<p style=\"" + css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "margin-left:" + s.size + "px", "line-height:160%", "font-style:italic", "color:" + s.muted]) + "\">" + emphasize(b.html) + "</p>")
    } else if (b.type === "code") {
      out.push("<pre style=\"" + css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "font-family:'" + s.mono + "'", "font-size:" + s.small + "px", "background-color:" + s.codeBg]) + "\">" + escapeHtml(b.text) + "</pre>")
    } else if (b.type === "table") {
      var cell = function (html, head) {
        var t = head ? "th" : "td"
        return "<" + t + " style=\"" + css(["padding:" + Math.round(s.size * 0.4) + "px " + Math.round(s.size * 0.7) + "px", "text-align:left", head ? "font-weight:600" : "font-weight:400", "color:" + (head ? s.bright : s.text)]) + "\">" + emphasize(html) + "</" + t + ">"
      }
      out.push("<table cellspacing=\"0\" border=\"1\" style=\"" + css(["border-color:" + s.line, "border-style:solid", "margin-bottom:" + Math.round(s.size * 0.9) + "px"]) + "\">"
        + "<tr>" + b.header.map(function (h) { return cell(h, true) }).join("") + "</tr>"
        + b.rows.map(function (row) { return "<tr>" + row.map(function (c) { return cell(c, false) }).join("") + "</tr>" }).join("")
        + "</table>")
    } else if (b.type === "hr") {
      out.push("<hr/>")
    }
  }
  out.push("</body>")
  return out.join("\n")
}

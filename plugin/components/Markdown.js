.pragma library

// Markdown for notes and the AI overview: parse into typed blocks that keep
// their source lines, then build one rich-text document for a TextEdit.
//
// Escape first: every piece of source text is HTML-escaped before a fixed,
// attribute-free set of StyledText tags (<b>, <i>, <tt>) is added. The one
// attribute emitted is a link's href, and only for http(s) URLs. Math spans
// become placeholders that toHtml() swaps for rendered SVGs or TeX source.

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function _safeUrl(url) {
  var u = String(url || "").trim()
  return /^https?:\/\/[^\s"'<>]+$/i.test(u) ? u : ""
}

// Placeholders use private-use characters, which are stripped from the source.
var TOKEN_OPEN = "\uE000", TOKEN_CLOSE = "\uE001", MATH_OPEN = "\uE002", MATH_CLOSE = "\uE003"
var _PRIVATE = /[\uE000-\uE003]/g

function mathKey(tex, display) {
  return (display ? "D:" : "I:") + tex
}

// End of an inline `$…$` starting at `open`, or -1. A formula opens on a
// non-space and closes on a non-space not followed by a digit, so "$5 and $10"
// stays text.
function _dollarEnd(s, open) {
  var first = s.charAt(open + 1)
  if (first === "" || first === "$" || /\s/.test(first)) return -1
  for (var j = open + 1; j < s.length; j++) {
    var c = s.charAt(j)
    if (c === "\\") { j++; continue }
    if (c === "$") return /\s/.test(s.charAt(j - 1)) || /\d/.test(s.charAt(j + 1)) ? -1 : j
  }
  return -1
}

// Inline Markdown for one line: code, math, links, bold, italic. When `math`
// (an array) is given, formulas are appended to it and referenced by index;
// without it they are shown as TeX source.
function inline(source, math) {
  var s = String(source || "").replace(_PRIVATE, "")
  var tokens = []
  var text = ""
  function token(html) { text += TOKEN_OPEN + tokens.length + TOKEN_CLOSE; tokens.push(html) }
  function formula(tex, display) {
    if (math) { token(MATH_OPEN + math.length + MATH_CLOSE); math.push({ tex: tex, display: display }) }
    else token("<tt>" + escapeHtml(tex) + "</tt>")
  }
  var i = 0
  while (i < s.length) {
    var ch = s.charAt(i)
    var rest = s.slice(i)
    if (ch === "`") {
      var close = s.indexOf("`", i + 1)
      if (close > i) { token("<tt>" + escapeHtml(s.slice(i + 1, close)) + "</tt>"); i = close + 1; continue }
    } else if (ch === "\\") {
      var paren = /^\\\((.+?)\\\)/.exec(rest)
      if (paren && paren[1].trim()) { formula(paren[1].trim(), false); i += paren[0].length; continue }
      if (rest.charAt(1) === "$") { token("$"); i += 2; continue }
    } else if (ch === "$") {
      var display = /^\$\$([^$]+?)\$\$/.exec(rest)
      if (display && display[1].trim()) { formula(display[1].trim(), true); i += display[0].length; continue }
      var end = _dollarEnd(s, i)
      if (end > i + 1) { formula(s.slice(i + 1, end), false); i = end + 1; continue }
    } else if (ch === "[") {
      var m = /^\[([^\]]+)\]\(([^)\s]+)\)/.exec(rest)
      if (m) {
        var url = _safeUrl(m[2])
        token(url ? "<a href=\"" + escapeHtml(url) + "\">" + _emphasis(m[1]) + "</a>" : _emphasis(m[1]))
        i += m[0].length
        continue
      }
    }
    text += ch
    i++
  }
  var out = _emphasis(text)
  var pattern = new RegExp(TOKEN_OPEN + "(\\d+)" + TOKEN_CLOSE, "g")
  return out.replace(pattern, function (_, n) { return tokens[Number(n)] })
}

function _emphasis(text) {
  var e = escapeHtml(text)
  e = e.replace(/\*\*([^*]+?)\*\*/g, "<b>$1</b>").replace(/__([^_]+?)__/g, "<b>$1</b>")
  e = e.replace(/(^|[\s(])\*([^*\s][^*]*?)\*(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>")
  e = e.replace(/(^|[\s(])_([^_\s][^_]*?)_(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>")
  return e
}

function _splitRow(line) {
  var t = line.trim().replace(/^\|/, "").replace(/\|$/, "")
  return t.split("|").map(function (c) { return c.trim() })
}

// Blocks: {type, start, end, math, ...} where start/end are the first and last
// source line (0-based, inclusive) and math lists the block's formulas.
//   h1/h2/h3: {number, html, text}
//   p/quote: {html}
//   ol/ul: {items:[{marker, html, detail, sub:[html]}]}
//   code: {text, lang}
//   math: {tex}
//   table: {header:[html], rows:[[html]]}
//   hr
// options:
//   skipTitle: drop a leading "# Title" line (overviews)
//   sectionLevel: headings ##–#### only, with this many #s or fewer as "h2"
//     and deeper as "h3", numbered like "2.1 Title" (overviews). Without it,
//     # is h1, ## is h2 and ### or deeper is h3 (notes).
//   isTitle(line): what skipTitle treats as a title
function blocks(markdown, options) {
  var opt = options || {}
  var lines = String(markdown || "").replace(/\r\n?/g, "\n").split("\n")
  var out = []
  var para = [], paraStart = 0
  var sawTitle = false
  var math = []
  function push(block, start, end) {
    block.start = start
    block.end = end
    block.math = math
    math = []
    out.push(block)
  }
  function flush() {
    if (para.length) push({ type: "p", html: inline(para.join(" "), math) }, paraStart, paraStart + para.length - 1)
    para = []
  }
  var i = 0
  while (i < lines.length) {
    var line = lines[i]
    var trimmed = line.trim()
    var start = i
    if (opt.skipTitle && !sawTitle && out.length === 0 && para.length === 0 && opt.isTitle && opt.isTitle(trimmed)) {
      sawTitle = true
      i++
      continue
    }
    var fence = /^(```+|~~~+)\s*([\w+#.-]*)/.exec(trimmed)
    if (fence) {
      flush()
      var code = []
      i++
      while (i < lines.length && lines[i].trim().indexOf(fence[1]) !== 0) { code.push(lines[i]); i++ }
      var closed = i < lines.length
      push({ type: "code", text: code.join("\n"), lang: fence[2] || "" }, start, closed ? i : i - 1)
      i++
      continue
    }
    if (/^\$\$/.test(trimmed) || /^\\\[/.test(trimmed)) {
      flush()
      var dollar = trimmed.charAt(0) === "$"
      var closer = dollar ? "$$" : "\\]"
      var body = trimmed.slice(2)
      var tex = []
      var endAt = body.lastIndexOf(closer)
      if (endAt >= 0) {
        tex.push(body.slice(0, endAt))
      } else {
        if (body.trim()) tex.push(body)
        i++
        while (i < lines.length) {
          var t = lines[i].trim()
          var at = t.lastIndexOf(closer)
          if (at >= 0) { if (t.slice(0, at).trim()) tex.push(t.slice(0, at)); break }
          tex.push(lines[i])
          i++
        }
      }
      var formulaText = tex.join("\n").trim()
      var end = Math.min(i, lines.length - 1)
      if (formulaText) {
        math.push({ tex: formulaText, display: true })
        push({ type: "math", tex: formulaText }, start, end)
      } else {
        push({ type: "p", html: escapeHtml(lines.slice(start, end + 1).join(" ")) }, start, end)
      }
      i++
      continue
    }
    var h = opt.sectionLevel ? /^(#{2,4})\s+(.*)$/.exec(trimmed) : /^(#{1,6})\s+(.*)$/.exec(trimmed)
    if (h) {
      flush()
      var level, num = null, text = h[2]
      if (opt.sectionLevel) {
        level = h[1].length <= opt.sectionLevel ? "h2" : "h3"
        num = /^(\d+(?:\.\d+)*)\.?\s+(.*)$/.exec(h[2])
        text = num ? num[2] : h[2]
      } else {
        level = h[1].length === 1 ? "h1" : h[1].length === 2 ? "h2" : "h3"
      }
      push({ type: level, number: num ? num[1] : "", text: text.replace(/\*\*/g, ""), html: inline(text, math) }, start, i)
      i++
      continue
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) { flush(); push({ type: "hr" }, start, i); i++; continue }
    if (/^\|.*\|$/.test(trimmed) && i + 1 < lines.length && /^\|?\s*:?-{2,}/.test(lines[i + 1].trim())) {
      flush()
      var cell = function (c) { return inline(c, math) }
      var header = _splitRow(trimmed).map(cell)
      var rows = []
      i += 2
      while (i < lines.length && /^\|.*\|$/.test(lines[i].trim())) { rows.push(_splitRow(lines[i]).map(cell)); i++ }
      push({ type: "table", header: header, rows: rows }, start, i - 1)
      continue
    }
    var listMatch = /^(\s*)(\d+[.)]|[-*+])\s+(.*)$/.exec(line)
    if (listMatch && listMatch[1].length < 2) {
      flush()
      var ordered = /\d/.test(listMatch[2])
      var items = []
      var last = i
      while (i < lines.length) {
        var lm = /^(\s*)(\d+[.)]|[-*+])\s+(.*)$/.exec(lines[i])
        if (!lm || lm[1].length >= 2 || /\d/.test(lm[2]) !== ordered) break
        var head = lm[3].replace(/\s{2,}$/, "")
        var detail = []
        var sub = []
        last = i
        i++
        // Indented lines belong to this item: nested bullets become `sub`,
        // other text continues the last nested bullet or the item's detail.
        while (i < lines.length && (/^\s{2,}\S/.test(lines[i]) || (/^\s*$/.test(lines[i]) && i + 1 < lines.length && /^\s{2,}\S/.test(lines[i + 1])))) {
          var nested = /^\s{2,}(\d+[.)]|[-*+])\s+(.*)$/.exec(lines[i])
          if (nested) sub.push(nested[2].trim())
          else if (lines[i].trim() && sub.length) sub[sub.length - 1] += " " + lines[i].trim()
          else if (lines[i].trim()) detail.push(lines[i].trim())
          if (lines[i].trim()) last = i
          i++
        }
        items.push({ marker: ordered ? lm[2].replace(")", ".") : "•", html: inline(head, math), detail: detail.length ? inline(detail.join(" "), math) : "", sub: sub.map(function (x) { return inline(x, math) }) })
        while (i < lines.length && lines[i].trim() === "" && i + 1 < lines.length && /^(\s*)(\d+[.)]|[-*+])\s/.test(lines[i + 1]) && /^(\s*)/.exec(lines[i + 1])[1].length < 2) i++
      }
      push({ type: ordered ? "ol" : "ul", items: items }, start, last)
      continue
    }
    if (/^>\s?/.test(trimmed)) {
      flush()
      var quote = []
      while (i < lines.length && /^>\s?/.test(lines[i].trim())) { quote.push(lines[i].trim().replace(/^>\s?/, "")); i++ }
      push({ type: "quote", html: inline(quote.join(" "), math) }, start, i - 1)
      continue
    }
    if (trimmed === "") { flush(); i++; continue }
    if (!para.length) paraStart = i
    para.push(trimmed)
    i++
  }
  flush()
  return out
}

// Every formula the blocks need, once: [{key, tex, display}].
function mathKeys(list) {
  var seen = {}, out = []
  for (var i = 0; i < list.length; i++) {
    var m = list[i].math || []
    for (var j = 0; j < m.length; j++) {
      var key = mathKey(m[j].tex, m[j].display)
      if (!seen[key]) { seen[key] = true; out.push({ key: key, tex: m[j].tex, display: m[j].display }) }
    }
  }
  return out
}

function _fileUrl(path) {
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

// One rich-text document for a selectable TextEdit, so a selection can run
// across paragraphs. Block html is already escaped; only fixed tags and the
// style values passed in (colors and sizes from the theme) are added.
//   s: {reading, mono, size, heading, small, text, bright, muted, dim, line, codeBg, link, urgent}
//   rendered: {mathKey: {path, width, height} | {error}}, from render_math
function toHtml(list, s, rendered) {
  var done = rendered || {}
  function css(pairs) { return pairs.join(";") }
  function formula(m) {
    var r = done[mathKey(m.tex, m.display)]
    if (r && r.path) return "<img src=\"" + escapeHtml(_fileUrl(r.path)) + "\" width=\"" + r.width + "\" height=\"" + r.height + "\"" + (m.display ? "" : " style=\"vertical-align:middle\"") + ">"
    var color = r && r.error ? (s.urgent || s.muted) : s.dim
    var tex = m.display ? "$$" + m.tex + "$$" : "$" + m.tex + "$"
    return "<span style=\"" + css(["font-family:'" + s.mono + "'", "font-size:" + s.small + "px"]) + "\"><font color=\"" + color + "\">" + escapeHtml(tex) + "</font></span>"
  }
  function withMath(html, math) {
    var pattern = new RegExp(MATH_OPEN + "(\\d+)" + MATH_CLOSE, "g")
    return String(html).replace(pattern, function (_, n) { return math && math[Number(n)] ? formula(math[Number(n)]) : "" })
  }
  function emphasize(html, math) {
    return withMath(String(html)
      .replace(/<b>/g, "<b><font color=\"" + s.bright + "\">").replace(/<\/b>/g, "</font></b>")
      .replace(/<a href="([^"]*)">/g, "<a href=\"$1\"><font color=\"" + s.link + "\">").replace(/<\/a>/g, "</font></a>"), math)
  }
  var para = css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "line-height:160%"])
  var out = ["<body style=\"" + css(["font-family:'" + s.reading + "'", "font-size:" + s.size + "px", "color:" + s.text]) + "\">"]
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    var first = out.length === 1
    var em = function (html) { return emphasize(html, b.math) }
    if (b.type === "h1" || b.type === "h2" || b.type === "h3") {
      var major = b.type !== "h3"
      var size = b.type === "h1" ? Math.round(s.heading * 1.25) : major ? s.heading : s.size
      var number = b.number ? "<span style=\"" + css(["font-family:'" + s.mono + "'", "font-size:" + (major ? s.small + 1 : s.small) + "px", "font-weight:400", "color:" + s.dim]) + "\">" + b.number + "</span>&nbsp;&nbsp;&nbsp;" : ""
      // A styled <p>, not <h2>/<h3>: Qt scales heading tags past the given size.
      var tag = "p"
      out.push("<" + tag + " style=\"" + css(["margin-top:" + (first ? 0 : major ? Math.round(s.size * 1.6) : Math.round(s.size * 0.9)) + "px", "margin-bottom:" + Math.round(s.size * 0.5) + "px", "font-size:" + size + "px", "font-weight:600", "color:" + s.bright]) + "\">" + number + em(b.html) + "</" + tag + ">")
    } else if (b.type === "p") {
      out.push("<p style=\"" + para + "\">" + em(b.html) + "</p>")
    } else if (b.type === "ol" || b.type === "ul") {
      var items = b.items.map(function (item) {
        var body = em(item.html)
        if (item.detail) body += "<br><font color=\"" + s.muted + "\">" + em(item.detail) + "</font>"
        if (item.sub && item.sub.length) {
          body += "<ul style=\"" + css(["margin-top:" + Math.round(s.size * 0.4) + "px", "margin-bottom:0", "list-style-type:circle"]) + "\">"
            + item.sub.map(function (sub) { return "<li style=\"" + css(["margin-bottom:0", "line-height:150%"]) + "\">" + em(sub) + "</li>" }).join("")
            + "</ul>"
        }
        return "<li style=\"" + css(["margin-bottom:" + Math.round(s.size * 0.15) + "px", "line-height:150%"]) + "\">" + body + "</li>"
      }).join("")
      var listTag = b.type
      out.push("<" + listTag + " style=\"" + css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "list-style-type:" + (listTag === "ol" ? "decimal" : "disc")]) + "\">" + items + "</" + listTag + ">")
    } else if (b.type === "quote") {
      out.push("<p style=\"" + css(["margin-top:0", "margin-bottom:" + Math.round(s.size * 0.9) + "px", "margin-left:" + s.size + "px", "line-height:160%", "font-style:italic", "color:" + s.muted]) + "\">" + em(b.html) + "</p>")
    } else if (b.type === "code") {
      // A one-cell table: Qt rich text pads table cells but not <pre>. Qt adds
      // about 6px below a cell's last line, so the bottom padding is smaller.
      var pad = Math.round(s.size * 0.6)
      var label = b.lang ? "<p style=\"" + css(["margin:0", "margin-bottom:" + Math.round(s.small * 0.4) + "px", "font-family:'" + s.mono + "'", "font-size:" + (s.small - 1) + "px", "color:" + s.dim]) + "\">" + escapeHtml(b.lang) + "</p>" : ""
      out.push("<table width=\"100%\" cellspacing=\"0\" style=\"" + css(["margin-bottom:" + Math.round(s.size * 0.9) + "px", "background-color:" + s.codeBg]) + "\"><tr><td style=\"" + css(["padding:" + pad + "px", "padding-bottom:" + Math.max(0, pad - 6) + "px"]) + "\">" + label
        + "<p style=\"" + css(["margin:0", "white-space:pre-wrap", "font-family:'" + s.mono + "'", "font-size:" + s.small + "px", "color:" + s.bright]) + "\">" + escapeHtml(b.text).replace(/\n/g, "<br>") + "</p></td></tr></table>")
    } else if (b.type === "math") {
      // Qt leaves a paragraph holding only an image unaligned; the spaces center it.
      out.push("<p align=\"center\" style=\"" + css(["margin-top:" + Math.round(s.size * 0.3) + "px", "margin-bottom:" + Math.round(s.size * 0.9) + "px"]) + "\">&nbsp;" + formula(b.math[0]) + "&nbsp;</p>")
    } else if (b.type === "table") {
      var tableCell = function (html, head) {
        var t = head ? "th" : "td"
        return "<" + t + " style=\"" + css(["padding:" + Math.round(s.size * 0.4) + "px " + Math.round(s.size * 0.7) + "px", "text-align:left", head ? "font-weight:600" : "font-weight:400", "color:" + (head ? s.bright : s.text)]) + "\">" + em(html) + "</" + t + ">"
      }
      out.push("<table cellspacing=\"0\" border=\"1\" style=\"" + css(["border-color:" + s.line, "border-style:solid", "margin-bottom:" + Math.round(s.size * 0.9) + "px"]) + "\">"
        + "<tr>" + b.header.map(function (h) { return tableCell(h, true) }).join("") + "</tr>"
        + b.rows.map(function (row) { return "<tr>" + row.map(function (c) { return tableCell(c, false) }).join("") + "</tr>" }).join("")
        + "</table>")
    } else if (b.type === "hr") {
      out.push("<hr/>")
    }
  }
  out.push("</body>")
  return out.join("\n")
}

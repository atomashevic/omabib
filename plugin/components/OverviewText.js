.pragma library
.import "Markdown.js" as Markdown

// An alphaXiv overview (Markdown) as typed blocks the AI summary tab lays out,
// so headings, lists and tables get real typography and the section strip can
// scroll to a heading. Parsing and rendering live in Markdown.js; this file
// adds the overview's shape: a report title to drop and numbered sections.

function escapeHtml(text) { return Markdown.escapeHtml(text) }
function inline(source, math) { return Markdown.inline(source, math) }
function toHtml(list, style, rendered) { return Markdown.toHtml(list, style, rendered) }
function mathKeys(list) { return Markdown.mathKeys(list) }

function _isTitle(line) {
  return /^#\s/.test(line) || /^##\s+(Research Report:|AI Overview)/i.test(line)
}

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
  return Markdown.blocks(markdown, { skipTitle: true, isTitle: _isTitle, sectionLevel: _sectionLevel(lines) })
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

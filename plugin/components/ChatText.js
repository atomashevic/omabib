.pragma library

// Words for the chat transcript: what a tool call did, what an approval asks,
// and page references turned into links the reader can follow.

function basename(path) {
  var s = String(path || "")
  return s.slice(s.lastIndexOf("/") + 1)
}

function short(text, limit) {
  var s = String(text || "").replace(/\s+/g, " ").trim()
  return s.length > limit ? s.slice(0, limit - 1) + "…" : s
}

var OMABIB = {
  get_reference: "Read the reference",
  get_references: "Read references",
  search: "Searched the library",
  get_note_image: "Looked at a saved clip",
  get_pdf: "Found the PDF",
  get_alphaxiv_overview: "Read the alphaXiv overview",
  list_projects: "Listed projects",
  project_context: "Read the project",
  add_note: "Save a note",
  update_note: "Edit a note",
  delete_note: "Delete a note",
  delete_reference: "Delete the reference",
  add_reference: "Add a reference",
  add_pdf: "Attach a PDF",
  pull_pdf: "Download a PDF",
  remove_pdf: "Remove a PDF link",
  associate: "Add to a project",
  create_project: "Create a project"
}

function omabibTool(name) {
  var m = /^mcp__omabib__(.+)$/.exec(String(name || ""))
  return m ? m[1] : ""
}

// A short line for a tool call, e.g. "Ran `ls`" or "Searched the library: “attention”".
function toolLabel(name, input) {
  var i = input || {}
  var tool = omabibTool(name)
  if (tool) {
    var base = OMABIB[tool] || ("Omabib: " + tool.replace(/_/g, " "))
    if (tool === "search" && i.query) return base + ": “" + short(i.query, 60) + "”"
    return base
  }
  switch (name) {
  case "Read": return "Read " + basename(i.file_path)
  case "Grep": return "Searched files for “" + short(i.pattern, 50) + "”"
  case "Glob": return "Listed files " + short(i.pattern, 50)
  case "Bash":
  case "shell": return "Ran `" + short(String(i.command || "").replace(/^\/usr\/bin\/bash -lc /, "").replace(/^(['"])([\s\S]*)\1$/, "$2"), 80) + "`"
  case "WebFetch": return "Fetch " + short(i.url, 70)
  case "WebSearch": return "Search the web: “" + short(i.query, 60) + "”"
  case "Edit":
  case "MultiEdit": return "Edit " + basename(i.file_path)
  case "Write": return "Write " + basename(i.file_path)
  }
  return short(name, 60)
}

function toolIcon(name) {
  if (omabibTool(name)) return "book"
  if (name === "Bash" || name === "shell") return "terminal"
  if (name === "WebFetch" || name === "WebSearch") return "globe"
  if (name === "Edit" || name === "MultiEdit" || name === "Write") return "pencil"
  if (name === "Grep" || name === "Glob") return "search"
  if (name === "Read") return "file"
  return "robot"
}

// {title, detail} for an approval card.
function approvalSummary(tool, input, agentLabel) {
  var i = input || {}
  var who = agentLabel || "The agent"
  var action = toolLabel(tool, i)
  var title = "Allow " + who + " to " + action.charAt(0).toLowerCase() + action.slice(1) + "?"
  var detail = ""
  var o = omabibTool(tool)
  if (o === "add_note" || o === "update_note") detail = short(i.body, 400) + (i.project_id ? "" : "\nScope: Global")
  else if (tool === "Bash" || tool === "shell") detail = String(i.command || "")
  else if (tool === "WebFetch") detail = String(i.url || "")
  else if (tool === "Edit" || tool === "Write") detail = String(i.file_path || "")
  else detail = short(JSON.stringify(i), 400)
  return { title: title, detail: detail }
}

// Turns "p. 7", "pp. 7–9" and "page 12" in rendered HTML text into omabib-page links
// in `color`, leaving tags, attributes and existing links alone.
function linkPages(html, color) {
  var parts = String(html || "").split(/(<[^>]+>)/)
  var inLink = 0
  for (var k = 0; k < parts.length; k++) {
    var part = parts[k]
    if (part.charAt(0) === "<") {
      if (/^<a[\s>]/i.test(part)) inLink++
      else if (/^<\/a>/i.test(part)) inLink = Math.max(0, inLink - 1)
      continue
    }
    if (inLink) continue
    parts[k] = part.replace(/\b(pp?\.|pages?)(\s|&nbsp;)?(\d{1,4})/gi, function (all, word, space, page) {
      var label = color ? "<font color=\"" + color + "\">" + all + "</font>" : all
      return "<a href=\"omabib-page:" + page + "\">" + label + "</a>"
    })
  }
  return parts.join("")
}

function firstPage(text) {
  var m = /\b(?:pp?\.|pages?)\s?(\d{1,4})/i.exec(String(text || ""))
  return m ? Number(m[1]) : 0
}

function statusLabel(status) {
  switch (status) {
  case "thinking": return "Thinking…"
  case "writing": return "Writing…"
  case "tool": return "Using tools…"
  case "approval": return "Waiting for your approval"
  }
  return ""
}

function tokens(n) {
  n = Number(n) || 0
  return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n)
}

// The quiet line after a turn: "stopped", or tokens read and written.
function turnLabel(data) {
  var d = data || {}
  if (d.interrupted) return "Stopped"
  if (d.is_error) return "Ended with an error"
  var u = d.usage || {}
  var read = (Number(u.input_tokens) || 0) + (Number(u.cache_read_input_tokens) || 0) + (Number(u.cache_creation_input_tokens) || 0)
  var parts = []
  if (read) parts.push(tokens(read) + " read")
  if (u.output_tokens) parts.push(tokens(u.output_tokens) + " written")
  return parts.join(" · ")
}

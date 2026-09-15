.pragma library

// The popup's icons, by name. Each is a Material Design glyph from the range
// Nerd Fonts bundle (U+F0001–U+F1AF0), the same range the Omarchy shell and
// Omamail draw from. Codepoints were read from the installed
// JetBrainsMono Nerd Font's own glyph names (md-*), not typed from memory.
var GLYPHS = {
  search: 0xF0349,        // magnify
  book: 0xF15D6,          // book-open-page-variant-outline — the app mark
  library: 0xF125F,       // bookshelf — all references
  recent: 0xF0150,        // clock-outline — newest added
  folder: 0xF0256,        // folder-outline — projects
  folderOpen: 0xF0DCF,    // folder-open-outline
  alert: 0xF002A,         // alert-outline — needs attention
  plus: 0xF0415,          // plus
  sync: 0xF04E6,          // sync
  syncAlert: 0xF04E7,     // sync-alert
  branch: 0xF062C,        // source-branch — history repository
  command: 0xF0633,       // apple-keyboard-command — actions
  pdf: 0xF0226,           // file-pdf-box
  file: 0xF0224,          // file-outline
  fileMissing: 0xF1036,   // file-question-outline
  external: 0xF03CC,      // open-in-new
  link: 0xF0339,          // link-variant
  unlink: 0xF033A,        // link-variant-off
  notePlus: 0xF1782,      // note-edit-outline
  note: 0xF11D7,          // note-text-outline
  sparkles: 0xF0674,      // creation — the AI overview
  terminal: 0xF018D,      // console — Codex
  chat: 0xF0365,          // message-outline — ChatGPT
  dots: 0xF01D8,          // dots-horizontal — overflow
  copy: 0xF018F,          // content-copy
  pencil: 0xF0CB6,        // pencil-outline
  tag: 0xF04FC,           // tag-outline
  trash: 0xF0A7A,         // trash-can-outline
  download: 0xF0B8F,      // download-outline
  braces: 0xF0169,        // code-braces — BibTeX
  chevronDown: 0xF0140,   // chevron-down
  chevronRight: 0xF0142,  // chevron-right
  close: 0xF0156,         // close
  filter: 0xF0236,        // filter-variant
  sort: 0xF04BA,          // sort
  globe: 0xF01E7,         // earth — global note scope
  refresh: 0xF0450,       // refresh
  check: 0xF012C,         // check
  text: 0xF09AA,          // text-long — abstract
  image: 0xF0976,         // image-outline
  enter: 0xF0311,         // keyboard-return
  checkboxBlank: 0xF0131, // checkbox-blank-outline
  checkboxMarked: 0xF0135,// checkbox-marked-outline
  cloudCheck: 0xF12CC,    // cloud-check-outline
  folderUp: 0xF19F0,      // folder-arrow-up
  cog: 0xF08BB,           // cog-outline
  radioOn: 0xF043E,       // radiobox-marked
  radioOff: 0xF043D       // radiobox-blank
}

function has(name) {
  return Object.prototype.hasOwnProperty.call(GLYPHS, String(name || ""))
}

// The character to draw, or "" for an unknown name (an empty slot shows up in
// a test where a wrong glyph would not).
function glyph(name) {
  return has(name) ? String.fromCodePoint(GLYPHS[name]) : ""
}

function names() {
  return Object.keys(GLYPHS)
}

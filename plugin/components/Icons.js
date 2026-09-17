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
  radioOff: 0xF043D,      // radiobox-blank
  tab: 0xF04E9,           // tab
  tabPlus: 0xF075C,       // tab-plus
  document: 0xF09EE,      // file-document-outline
  bold: 0xF0264,          // format-bold
  italic: 0xF0277,        // format-italic
  code: 0xF0174,          // code-tags
  math: 0xF04A0,          // sigma
  list: 0xF0279,          // format-list-bulleted
  heading: 0xF0274,       // format-header-pound
  quote: 0xF0757,         // format-quote-open
  crop: 0xF019E,          // crop — the clip rectangle tool
  zoomIn: 0xF06ED,        // magnify-plus-outline
  zoomOut: 0xF06EC,       // magnify-minus-outline
  fitWidth: 0xF084E,      // arrow-expand-horizontal
  fitPage: 0xF0EF6,       // fit-to-page-outline
  sidebar: 0xF10AB,       // dock-right — the reader's notes pane
  outline: 0xF0836,       // table-of-contents
  chevronUp: 0xF0143,     // chevron-up
  pageColors: 0xF050E,    // theme-light-dark — PDF pages in theme colors
  robot: 0xF167A,         // robot-outline — in-window agent chat
  send: 0xF048A,          // send
  stop: 0xF04DB,          // stop — end a streaming reply
  quote: 0xF0757,         // format-quote-open — a quoted selection
  history: 0xF02DA,       // history — earlier chats
  steps: 0xF0756,         // format-list-checks — show the agent's steps
  brain: 0xF09D1,         // brain — the chat model
  speedometer: 0xF04C5    // speedometer — reasoning effort
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

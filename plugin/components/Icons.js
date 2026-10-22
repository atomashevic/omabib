.pragma library

// The window's icons, by name: Lucide line icons from the bundled lucide.ttf
// (fonts/lucide.ttf, ISC licence), cut to these glyphs by scripts/subset-icons.
// Codepoints were read from that release's codepoints.json, not typed from
// memory; the comment is Lucide's own name.
var GLYPHS = {
  search:         0xE151,  // search
  book:           0xE05F,  // book-open
  library:        0xE100,  // library
  recent:         0xE087,  // clock
  folder:         0xE0D7,  // folder
  folderOpen:     0xE247,  // folder-open
  folderPlus:     0xE0D9,  // folder-plus
  alert:          0xE193,  // triangle-alert
  plus:           0xE13D,  // plus
  sync:           0xE145,  // refresh-cw
  syncAlert:      0xE498,  // refresh-cw-off
  branch:         0xE0E2,  // git-branch
  command:        0xE09A,  // command
  pdf:            0xE0CC,  // file-text
  file:           0xE0C0,  // file
  fileMissing:    0xE322,  // file-question-mark
  external:       0xE0B9,  // external-link
  link:           0xE102,  // link
  unlink:         0xE19C,  // unlink
  notePlus:       0xE596,  // notebook-pen
  note:           0xE598,  // notebook-text
  sparkles:       0xE412,  // sparkles
  terminal:       0xE181,  // terminal
  chat:           0xE117,  // message-square
  dots:           0xE0B6,  // ellipsis
  copy:           0xE09E,  // copy
  pencil:         0xE1F9,  // pencil
  tag:            0xE17F,  // tag
  trash:          0xE18E,  // trash-2
  download:       0xE0B2,  // download
  braces:         0xE36A,  // braces
  chevronDown:    0xE06D,  // chevron-down
  chevronRight:   0xE06F,  // chevron-right
  chevronLeft:    0xE06E,  // chevron-left
  chevronUp:      0xE070,  // chevron-up
  close:          0xE1B2,  // x
  filter:         0xE460,  // list-filter
  sort:           0xE046,  // arrow-down-up
  globe:          0xE0E8,  // globe
  refresh:        0xE145,  // refresh-cw
  check:          0xE06C,  // check
  text:           0xE185,  // align-left
  image:          0xE0F6,  // image
  enter:          0xE0A1,  // corner-down-left
  checkboxBlank:  0xE167,  // square
  checkboxMarked: 0xE559,  // square-check
  cloudCheck:     0xE66E,  // cloud-check
  folderUp:       0xE33D,  // folder-up
  cog:            0xE154,  // settings
  radioOn:        0xE345,  // circle-dot
  radioOff:       0xE076,  // circle
  tab:            0xE426,  // app-window
  tabPlus:        0xE173,  // square-plus
  document:       0xE0CC,  // file-text
  bold:           0xE05D,  // bold
  italic:         0xE0FB,  // italic
  code:           0xE093,  // code
  math:           0xE201,  // sigma
  list:           0xE106,  // list
  heading:        0xE384,  // heading
  quote:          0xE239,  // quote
  crop:           0xE0AB,  // crop
  highlighter:    0xE130,  // pen-line (the font's highlighter glyph lacks its pen body)
  chatQuote:      0xE572,  // message-square-quote
  zoomIn:         0xE1B6,  // zoom-in
  zoomOut:        0xE1B7,  // zoom-out
  fitWidth:       0xE1C6,  // move-horizontal
  fitPage:        0xE112,  // maximize
  sidebar:        0xE431,  // panel-right
  sidebarLeft:    0xE12A,  // panel-left
  outline:        0xE408,  // list-tree
  pageColors:     0xE09D,  // contrast
  robot:          0xE1BB,  // bot
  send:           0xE152,  // send
  stop:           0xE083,  // circle-stop
  history:        0xE1F5,  // history
  steps:          0xE1D0,  // list-checks
  brain:          0xE3C6,  // brain
  speedometer:    0xE1BF,  // gauge
  googleDrive:    0xE088,  // cloud
  dropbox:        0xE088,  // cloud
  onedrive:       0xE088,  // cloud
  folderSync:     0xE4C9,  // folder-sync
  cloudSync:      0xE6E3,  // cloud-sync
  cloudOff:       0xE08D,  // cloud-off
  cloudAlert:     0xE633,  // cloud-alert
  laptop:         0xE1CD,  // laptop
  server:         0xE153,  // server
  settings:       0xE154,  // settings
  sliders:        0xE29A,  // sliders-horizontal
  back:           0xE048,  // arrow-left
  cite:           0xE239,  // quote
  attach:         0xE12D,  // paperclip
  sun:            0xE178,  // sun
  moon:           0xE11E,  // moon
  monitor:        0xE11D,  // monitor
  palette:        0xE1DD   // palette
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

import QtQuick

// Long-form text you can select and copy: the abstract and the AI summary.
// Rich text keeps the reading line height; Ctrl+C copies it as plain text.
TextEdit {
    id: root

    required property var theme

    signal openLink(string url)

    readOnly: true
    selectByMouse: true
    textFormat: TextEdit.RichText
    wrapMode: TextEdit.Wrap
    color: theme.text
    selectionColor: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.5)
    selectedTextColor: theme.bright
    font.family: theme.readingFamily
    font.pixelSize: theme.title
    onLinkActivated: link => root.openLink(link)
    // Clicking elsewhere in the popup clears a stale highlight.
    onActiveFocusChanged: if (!activeFocus) deselect()

    HoverHandler { cursorShape: root.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
}

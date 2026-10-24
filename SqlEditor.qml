pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Theme
import "editor/sql-language.js" as Sql

// The editable document stays plain text: coloring is a viewport-sized paint
// layer, so it never changes SQL, selection, the clipboard, or the undo stack.
TextArea {
  id: editor
  property string dialect: "sqlserver"
  property string contextKey: ""
  property var catalog: []
  property var definitions: ({})
  property bool completionsEnabled: true
  property real viewportX: 0
  property real viewportY: 0
  property real viewportWidth: width
  property real viewportHeight: height
  property color textInk: Theme.Color.popups.text
  readonly property color keywordInk: Qt.hsla((Theme.Color.accent.hslHue + 1) % 1, 0.72, textInk.hslLightness > 0.5 ? 0.76 : 0.36, 1)
  readonly property color stringInk: textInk.hslLightness > 0.5 ? "#a9ce91" : "#327228"
  readonly property color numberInk: textInk.hslLightness > 0.5 ? "#dfba88" : "#885719"
  readonly property color commentInk: Qt.rgba(textInk.r,textInk.g,textInk.b,0.56)
  readonly property var analysis: Sql.analyze(text,dialect)
  readonly property var highlightedSegments: visibleSegments()
  readonly property bool completionVisible: completionPopup.visible
  property var completion: ({items:[],missing:[]})
  property bool explicitCompletion: false
  property bool applyingCompletion: false
  signal metadataRequested(var objects)

  color: preeditText.length ? textInk : "transparent"
  textFormat: TextEdit.PlainText
  wrapMode: TextEdit.NoWrap
  selectByMouse: true
  Accessible.name: "SQL editor"
  Accessible.description: "SQL syntax highlighting and autocomplete. Press Control Space for suggestions, arrows to select, Tab or Enter to insert, Escape to dismiss."
  cursorDelegate: Rectangle { width: 2; color: editor.textInk; visible: editor.cursorVisible }

  function textRect(position) { return positionToRectangle(Math.max(0,Math.min(length,position))) }
  function visibleSegments() {
    // Depend on the document and viewport, and use the native editor's glyph
    // positions. This preserves tabs, Unicode, blank lines and horizontal scroll.
    var parsed = analysis, ranges = []
    var first = Sql.lineAt(parsed,positionAt(viewportX,viewportY))
    var last = Sql.lineAt(parsed,positionAt(viewportX+viewportWidth,viewportY+viewportHeight))
    for (var i = first; i <= Math.min(last+1,parsed.lines.length-1); i++) {
      var line = parsed.lines[i], rect = textRect(line.start)
      var from = Math.max(line.start,positionAt(Math.max(leftPadding,viewportX-8),rect.y+rect.height/2))
      var to = Math.min(line.end,positionAt(viewportX+viewportWidth+16,rect.y+rect.height/2)+1)
      ranges.push({start:from,end:to})
    }
    return Sql.paintSegments(parsed,ranges,selectionStart,selectionEnd)
  }
  function tokenColor(kind) {
    if (kind === "keyword") return keywordInk
    if (kind === "function") return Qt.tint(textInk,Qt.rgba(Theme.Color.accent.r,Theme.Color.accent.g,Theme.Color.accent.b,0.45))
    if (kind === "string") return stringInk
    if (kind === "number" || kind === "variable") return numberInk
    if (kind === "comment") return commentInk
    return textInk
  }
  Repeater {
    model: editor.preeditText.length ? [] : editor.highlightedSegments
    delegate: Text {
      required property var modelData
      readonly property rect glyphRect: editor.textRect(modelData.start)
      x: glyphRect.x
      y: glyphRect.y
      text: modelData.text
      textFormat: Text.PlainText
      color: editor.tokenColor(modelData.kind)
      font: editor.font
      renderType: editor.renderType
    }
  }

  function dismissCompletion() { completionDelay.stop(); completionPopup.close(); explicitCompletion = false }
  function refreshCompletion(explicit) {
    if (!completionsEnabled || !activeFocus || preeditText.length || selectionStart !== selectionEnd) { dismissCompletion(); return }
    explicitCompletion = explicit
    completion = Sql.complete(analysis,cursorPosition,catalog,definitions,dialect,explicit)
    suggestionList.currentIndex = 0
    if (completion.blocked || (!completion.items.length && !completion.loading && !explicit)) { completionPopup.close(); return }
    if (completion.missing.length) metadataRequested(completion.missing)
    positionPopup()
    completionPopup.open()
  }
  function positionPopup() {
    var point = mapToItem(completionPopup.parent,cursorRectangle.x,cursorRectangle.y)
    completionPopup.x = Math.max(8,Math.min(point.x,completionPopup.parent.width-completionPopup.width-8))
    var below = completionPopup.parent.height-point.y-cursorRectangle.height-8
    var preferredY = below >= completionPopup.height || point.y < completionPopup.height
      ? point.y+cursorRectangle.height+4 : point.y-completionPopup.height-4
    completionPopup.y = Math.max(8,Math.min(preferredY,completionPopup.parent.height-completionPopup.height-8))
  }
  function acceptCompletion(index) {
    var item = completion.items[index]
    if (!item) return
    applyingCompletion = true
    var start = completion.start, end = completion.end
    // One native insert over the current selection makes this one undo step.
    select(start,end)
    cursorSelection.text = item.insertText
    cursorPosition = start+item.insertText.length
    deselect()
    dismissCompletion()
    applyingCompletion = false
    forceActiveFocus()
    if (item.insertText.endsWith('.')) Qt.callLater(function() { editor.refreshCompletion(true) })
  }
  onTextChanged: if (!applyingCompletion && activeFocus && completionsEnabled) completionDelay.restart()
  onCursorPositionChanged: if (!applyingCompletion && completionPopup.visible) completionDelay.restart()
  onPreeditTextChanged: if (preeditText.length) dismissCompletion()
  onActiveFocusChanged: if (!activeFocus) dismissCompletion()
  onContextKeyChanged: dismissCompletion()
  onCompletionsEnabledChanged: if (!completionsEnabled) dismissCompletion()
  onDefinitionsChanged: if (completionPopup.visible) Qt.callLater(function() { if (completionPopup.visible) editor.refreshCompletion(editor.explicitCompletion) })
  onCatalogChanged: dismissCompletion()
  onViewportWidthChanged: if (completionPopup.visible) positionPopup()
  onViewportHeightChanged: if (completionPopup.visible) positionPopup()
  onViewportYChanged: if (completionPopup.visible) positionPopup()
  onViewportXChanged: if (completionPopup.visible) positionPopup()
  Timer { id: completionDelay; interval: 140; onTriggered: editor.refreshCompletion(editor.explicitCompletion) }

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) {
      refreshCompletion(true); event.accepted = true; return
    }
    if (!completionPopup.visible) return
    if (event.key === Qt.Key_Escape) { dismissCompletion(); event.accepted = true }
    else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      var count = completion.items.length
      if (count) suggestionList.currentIndex = (suggestionList.currentIndex+(event.key === Qt.Key_Down ? 1 : count-1)) % count
      event.accepted = true
    } else if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier))) {
      if (completion.items.length) { acceptCompletion(suggestionList.currentIndex); event.accepted = true }
      else dismissCompletion()
    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Home || event.key === Qt.Key_End) dismissCompletion()
  }

  Popup {
    id: completionPopup
    objectName: "sqlCompletionPopup"
    parent: Overlay.overlay
    width: Math.min(460,parent ? parent.width-16 : 460)
    height: Math.min(310,parent ? parent.height-16 : 310,Math.max(86,suggestionList.contentHeight+40))
    onOpened: editor.positionPopup()
    onHeightChanged: if (visible) editor.positionPopup()
    padding: 5
    modal: false
    focus: false
    closePolicy: Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.Color.popups.background; border.color: Theme.Color.accent; radius: 5 }
    contentItem: ColumnLayout {
      spacing: 4
      ListView {
        id: suggestionList
        objectName: "sqlCompletionList"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: editor.completion.items
        currentIndex: 0
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        delegate: ItemDelegate {
          id: suggestion
          required property var modelData
          required property int index
          width: suggestionList.width
          height: 32
          focusPolicy: Qt.NoFocus
          highlighted: suggestionList.currentIndex === index
          Accessible.name: modelData.label+", "+modelData.kind+", "+modelData.detail
          background: Rectangle { radius: 3; color: suggestion.highlighted ? Qt.rgba(Theme.Color.accent.r,Theme.Color.accent.g,Theme.Color.accent.b,0.22) : "transparent" }
          contentItem: RowLayout {
            spacing: 10
            Text { text: suggestion.modelData.kind === "column" ? "C" : suggestion.modelData.kind === "table" || suggestion.modelData.kind === "view" ? "T" : suggestion.modelData.kind === "schema" ? "S" : suggestion.modelData.kind === "function" ? "ƒ" : "K"; color: Theme.Color.accent; font.family: editor.font.family; font.pixelSize: 13; Layout.preferredWidth: 16 }
            Text { text: suggestion.modelData.label; textFormat: Text.PlainText; color: editor.textInk; font.family: editor.font.family; font.pixelSize: 14; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { text: suggestion.modelData.detail; textFormat: Text.PlainText; color: editor.commentInk; font.pixelSize: 12; elide: Text.ElideRight; Layout.maximumWidth: suggestion.width*0.45 }
          }
          onClicked: editor.acceptCompletion(index)
          onHoveredChanged: if (hovered) suggestionList.currentIndex = index
        }
        Text { anchors.centerIn: parent; visible: !editor.completion.items.length; text: editor.completion.loading ? "Loading column suggestions…" : "No suggestions here"; color: editor.commentInk; font.pixelSize: 13 }
      }
      Text {
        Layout.fillWidth: true
        text: editor.completion.loading ? "Loading columns…" : editor.completion.unavailable ? "Column details unavailable · refresh schema to retry" : "↑↓ select · Tab / Enter insert · Esc close"
        color: editor.commentInk
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
  }
}

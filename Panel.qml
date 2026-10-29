import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "jakubkozera.audio-mixer"
  ipcTarget: "jakubkozera.audio-mixer"

  // Everything is read from PulseAudio's JSON view of the sound server, not from
  // Quickshell's PipeWire nodes: that view lists every sink and source (including
  // ones nothing has bound yet), with human-readable names, ports and availability.
  property var audio: ({ sinks: [], sources: [], streams: [], defaultSink: "", defaultSource: "", loaded: false })
  property var items: ({})
  property var sinkKeys: []
  property var sourceKeys: []
  property var streamKeys: []
  property string lastSnapshot: ""
  property bool showMonitors: false
  property var collapsed: ({ output: false, input: false, apps: false })
  property bool refreshQueued: false
  property real wheelAccumulator: 0

  property string cursorKey: "header"
  property bool cursorActive: false

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"

  readonly property var defaultSinkItem: items["sink:" + audio.defaultSink] || null
  readonly property var defaultSourceItem: items["source:" + audio.defaultSource] || null
  readonly property bool hasOutput: !!defaultSinkItem
  readonly property bool hasInput: !!defaultSourceItem
  readonly property bool anyAudible: (hasOutput && !defaultSinkItem.muted) || (hasInput && !defaultSourceItem.muted)

  readonly property var entries: {
    var list = ["header"]
    if (!collapsed.output) list = list.concat(sinkKeys)
    if (!collapsed.input) list = list.concat(sourceKeys)
    if (!collapsed.apps) list = list.concat(streamKeys)
    return list
  }

  // ---------- Data ----------

  function refresh() {
    if (snapshotProc.running) { refreshQueued = true; return }
    snapshotProc.running = true
  }

  function applySnapshot(text) {
    lastSnapshot = text
    var next = Model.buildState(text, { showMonitors: showMonitors })
    if (!next.loaded) return
    audio = next
    items = Model.indexItems(next)

    var sinks = Model.keysOf(next.sinks)
    var sources = Model.keysOf(next.sources)
    var streams = Model.keysOf(next.streams)
    // Reassigning an equal list would rebuild the rows and cancel a slider drag.
    if (!Model.sameKeys(sinks, sinkKeys)) sinkKeys = sinks
    if (!Model.sameKeys(sources, sourceKeys)) sourceKeys = sources
    if (!Model.sameKeys(streams, streamKeys)) streamKeys = streams
    clampCursor()
  }

  // Reflect a change immediately; the next snapshot confirms it.
  function patch(key, changes) {
    var current = items[key]
    if (!current) return
    var next = {}
    for (var k in items) next[k] = items[k]
    var updated = {}
    for (var f in current) updated[f] = current[f]
    for (var c in changes) updated[c] = changes[c]
    next[key] = updated
    items = next
  }

  function run(command) {
    Quickshell.execDetached(command)
    afterChange.restart()
  }

  function volumeCommand(item, value) {
    var pct = Math.round(Model.clamp(value, 0, 1) * 100) + "%"
    if (item.kind === "sink") return ["pactl", "set-sink-volume", item.name, pct]
    if (item.kind === "source") return ["pactl", "set-source-volume", item.name, pct]
    return ["pactl", "set-sink-input-volume", String(item.index), pct]
  }

  property var pendingVolumes: ({})

  function setVolume(key, value) {
    var item = items[key]
    if (!item) return -1
    var volume = Model.clamp(value, 0, 1)
    patch(key, { volume: volume })
    pendingVolumes[key] = volume
    if (!volumeFlush.running) volumeFlush.start()
    return volume
  }

  function flushVolumes() {
    var pending = pendingVolumes
    pendingVolumes = ({})
    for (var key in pending) {
      var item = items[key]
      if (item) run(volumeCommand(item, pending[key]))
    }
  }

  function toggleMute(key) {
    var item = items[key]
    if (!item) return
    var verb = item.kind === "sink" ? "set-sink-mute"
      : item.kind === "source" ? "set-source-mute" : "set-sink-input-mute"
    var target = item.kind === "stream" ? String(item.index) : item.name
    var changes = { muted: !item.muted }
    if (item.kind === "stream") changes.glyph = item.muted ? Model.GLYPH.streamOn : Model.GLYPH.streamOff
    patch(key, changes)
    run(["pactl", verb, target, "toggle"])
  }

  function setMuted(item, muted) {
    if (item && item.muted !== muted) toggleMute(item.key)
  }

  function toggleAllMuted() {
    var mute = anyAudible
    setMuted(defaultSinkItem, mute)
    setMuted(defaultSourceItem, mute)
  }

  function setDefault(key) {
    var item = items[key]
    if (!item || item.kind === "stream" || item.isDefault) return
    var next = {}
    for (var k in items) next[k] = items[k]
    for (var other in next) {
      if (next[other].kind !== item.kind) continue
      var copy = {}
      for (var f in next[other]) copy[f] = next[other][f]
      copy.isDefault = other === key
      next[other] = copy
    }
    items = next
    var audioNext = {}
    for (var a in audio) audioNext[a] = audio[a]
    if (item.kind === "sink") audioNext.defaultSink = item.name
    else audioNext.defaultSource = item.name
    audio = audioNext

    var helper = item.kind === "sink" ? "omarchy-audio-output-set-default" : "omarchy-audio-input-set-default"
    if (item.nodeId) run([helper, item.nodeId, item.name])
    else run(["pactl", item.kind === "sink" ? "set-default-sink" : "set-default-source", item.name])
  }

  function cyclePort(key) {
    var item = items[key]
    if (!item || item.kind === "stream" || item.ports.length < 2) return
    var port = Model.nextChoice(item.ports, item.activePort)
    run(["pactl", item.kind === "sink" ? "set-sink-port" : "set-source-port", item.name, port])
  }

  function cycleStreamDevice(key) {
    var item = items[key]
    if (!item || item.kind !== "stream") return
    var names = []
    for (var i = 0; i < audio.sinks.length; i++)
      if (audio.sinks[i].available) names.push(audio.sinks[i].name)
    var next = Model.nextChoice(names, item.sinkName)
    if (next) run(["pactl", "move-sink-input", String(item.index), next])
  }

  function setShowMonitors(value) {
    showMonitors = value
    if (lastSnapshot) applySnapshot(lastSnapshot)
  }

  function toggleSection(name) {
    var next = {}
    for (var k in collapsed) next[k] = collapsed[k]
    next[name] = !next[name]
    collapsed = next
    clampCursor()
  }

  // ---------- Cursor ----------

  function clampCursor() {
    if (entries.indexOf(cursorKey) < 0) cursorKey = "header"
  }

  function moveCursor(delta) {
    var at = entries.indexOf(cursorKey)
    if (at < 0) at = 0
    cursorKey = entries[Math.max(0, Math.min(entries.length - 1, at + delta))]
  }

  function adjustVolume(delta) {
    var item = items[cursorKey]
    if (item) setVolume(item.key, item.volume + delta)
  }

  function activateCursor() {
    if (cursorKey === "header") { toggleAllMuted(); return }
    var item = items[cursorKey]
    if (!item) return
    if (item.kind === "stream") toggleMute(item.key)
    else setDefault(item.key)
  }

  function resetScroll() {
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = 6
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    cursorActive = false
    cursorKey = "header"
    Qt.callLater(resetScroll)
  }

  Component.onCompleted: refresh()

  // ---------- Bar button ----------

  function showVolumeOsd(item, volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: Model.outputIcon(item),
      value: Math.round(volume * 100)
    }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: Pipewire.defaultAudioSource ? [Pipewire.defaultAudioSource] : [] }

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: Pipewire.defaultAudioSource
    enabled: root.opened && !!Pipewire.defaultAudioSource
  }

  Process {
    id: snapshotProc
    command: ["bash", "-c", [
      "pactl --format=json info | tr -d '\\n'; echo",
      "for k in sinks sources sink-inputs; do pactl --format=json list $k | tr -d '\\n'; echo; done"
    ].join("\n")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySnapshot(text)
    }
    onExited: if (root.refreshQueued) {
      root.refreshQueued = false
      root.refresh()
    }
  }

  Process {
    id: subscribeProc
    command: ["pactl", "subscribe"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (/'(change|new|remove)' on (sink|source|sink-input|server|card)\b/.test(line))
          refreshDebounce.restart()
      }
    }
    onExited: resubscribe.start()
  }

  Timer {
    id: resubscribe
    interval: 2000
    onTriggered: subscribeProc.running = true
  }

  Timer {
    id: refreshDebounce
    interval: 90
    onTriggered: root.refresh()
  }

  Timer {
    id: afterChange
    interval: 350
    onTriggered: root.refresh()
  }

  Timer {
    id: volumeFlush
    interval: 45
    onTriggered: root.flushVolumes()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.outputIcon(root.defaultSinkItem)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAllMuted()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      var item = root.defaultSinkItem
      if (!item) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var volume = root.setVolume(item.key, item.volume + wheel.steps * 0.05)
      root.showVolumeOsd(item, volume)
    }
  }

  // ---------- Panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(800))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * 0.05)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.cursorActive) return
        var item = root.items[root.cursorKey]
        var key = t.toLowerCase()
        if (key === "m") {
          if (item) root.toggleMute(item.key)
          else root.toggleAllMuted()
        } else if (key === "p" && item) {
          root.cyclePort(item.key)
        } else if (key === "d" && item) {
          root.cycleStreamDevice(item.key)
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: Model.outputIcon(root.defaultSinkItem)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.defaultSinkItem && root.defaultSinkItem.muted ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: powerSwitch
              checked: root.anyAudible
              hasCursor: root.cursorActive && root.cursorKey === "header"
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.cursorKey = "header" } }
              onToggled: root.toggleAllMuted()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.anyAudible ? "Mute" : "Unmute"
                fontFamily: root.bar.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Audio"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.defaultSinkItem ? root.defaultSinkItem.label.toUpperCase() : "NO OUTPUT"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          SectionBlock {
            sectionName: "output"
            title: "OUTPUT"
            keys: root.sinkKeys
          }

          SectionBlock {
            sectionName: "input"
            title: "INPUT"
            keys: root.sourceKeys
            actionText: root.showMonitors ? "HIDE MONITORS" : "SHOW MONITORS"
            onActionClicked: root.setShowMonitors(!root.showMonitors)
          }

          SectionBlock {
            sectionName: "apps"
            title: "APPS"
            keys: root.streamKeys
          }
        }
      }
    }
  }

  // ---------- Components ----------

  component SectionBlock: Column {
    id: block
    required property string sectionName
    required property string title
    required property var keys
    property string actionText: ""
    signal actionClicked()

    readonly property bool isCollapsed: !!root.collapsed[sectionName]

    width: panelColumn.width
    spacing: Style.space(6)
    visible: keys.length > 0 || actionText !== ""

    PanelSeparator { foreground: root.bar.foreground }

    Item {
      width: parent.width
      implicitHeight: Math.max(headerLeft.implicitHeight, headerAction.implicitHeight) + Style.space(4)

      Row {
        id: headerLeft
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: block.isCollapsed ? Model.GLYPH.chevronRight : Model.GLYPH.chevronDown
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        PanelSectionHeader {
          text: block.title + (block.keys.length > 0 ? "  " + block.keys.length : "")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: headerLeft.width + Style.space(12)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleSection(block.sectionName)
      }

      Text {
        id: headerAction
        visible: block.actionText !== ""
        textFormat: Text.PlainText
        text: block.actionText
        color: Qt.darker(root.bar.foreground, actionArea.containsMouse ? 1.0 : 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 0.8
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          id: actionArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: block.actionClicked()
        }
      }
    }

    Repeater {
      model: block.isCollapsed ? [] : block.keys

      DeviceRow {
        required property string modelData
        itemKey: modelData
        width: block.width
      }
    }
  }

  // One row for an output, an input or an app: mute button, name, default
  // marker and its own volume slider. Clicking the row makes a device the
  // default; apps have no default, so their row only carries the controls.
  component DeviceRow: CursorSurface {
    id: row
    required property string itemKey

    readonly property var item: root.items[itemKey] || null
    readonly property bool isStream: !!item && item.kind === "stream"
    readonly property bool canCycle: !!item && (isStream || item.ports.length > 1)
    readonly property bool isDefaultInput: !!item && item.kind === "source" && item.isDefault

    visible: !!item
    hasCursor: root.cursorActive && root.cursorKey === itemKey
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)
    current: !!item && item.isDefault
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: item ? rowColumn.implicitHeight + Style.spacing.xl : 0
    opacity: item && !item.available ? 0.55 : 1.0

    HoverHandler {
      onHoveredChanged: if (hovered) {
        root.cursorActive = true
        root.cursorKey = row.itemKey
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: row.isStream ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!row.isStream) root.setDefault(row.itemKey)
    }

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(4)

      Row {
        id: topRow
        width: parent.width
        spacing: Style.space(8)

        Item {
          id: glyphBox
          width: Style.space(26)
          height: Math.max(glyphText.implicitHeight, labels.implicitHeight)

          Text {
            id: glyphText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: {
              if (!row.item) return ""
              if (row.item.kind === "source" && row.item.muted) return Model.GLYPH.micMuted
              if (row.item.kind === "sink" && row.item.muted) return Model.GLYPH.volumeMuted
              return row.item.glyph
            }
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            opacity: row.item && row.item.muted ? 0.5 : 1.0
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleMute(row.itemKey)
          }
        }

        Column {
          id: labels
          width: Math.round((topRow.width - glyphBox.width - percent.width - markBox.width - topRow.spacing * 4) * 0.56)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: row.item ? row.item.label : ""
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: !!row.item && row.item.isDefault
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            id: subtitle
            visible: text !== ""
            textFormat: Text.PlainText
            text: {
              if (!row.item) return ""
              var base = row.item.subtitle
              if (row.isStream && base) base = "→ " + base
              if (row.canCycle && base) base += "  " + Model.GLYPH.swap
              return base
            }
            color: Qt.darker(root.bar.foreground, subtitleArea.containsMouse && row.canCycle ? 1.0 : 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width

            MouseArea {
              id: subtitleArea
              anchors.fill: parent
              enabled: row.canCycle
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: row.isStream ? root.cycleStreamDevice(row.itemKey) : root.cyclePort(row.itemKey)
            }
          }
        }

        PanelSlider {
          id: slider
          bar: root.bar
          width: topRow.width - glyphBox.width - labels.width - percent.width - markBox.width - topRow.spacing * 4
          minimum: 0
          maximum: 1
          step: 0.05
          value: row.item ? row.item.volume : 0
          opacity: row.item && row.item.muted ? 0.5 : 1.0
          anchors.verticalCenter: parent.verticalCenter

          onMoved: function(v) { root.setVolume(row.itemKey, v) }
          onRightClicked: root.toggleMute(row.itemKey)
        }

        Text {
          id: percent
          textFormat: Text.PlainText
          text: Math.round((slider.dragging ? slider.liveValue : slider.value) * 100) + "%"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(40)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          id: markBox
          width: Style.space(20)
          height: glyphBox.height

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: row.item && row.item.isDefault ? Model.GLYPH.check : ""
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
          }
        }
      }

      Row {
        visible: row.isDefaultInput
        width: parent.width
        spacing: topRow.spacing

        Item { width: glyphBox.width + labels.width + topRow.spacing; height: 1 }

        Rectangle {
          width: slider.width
          height: Math.max(Style.space(5), Style.spacing.xs)
          color: Util.alpha(root.bar.foreground, 0.18)
          opacity: row.item && row.item.muted ? 0.35 : 1.0

          Rectangle {
            height: parent.height
            width: parent.width * Math.max(0, Math.min(1, inputPeakMonitor.peak))
            color: root.bar.foreground
            Behavior on width { NumberAnimation { duration: 70 } }
          }
        }
      }
    }
  }
}

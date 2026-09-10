import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "azure.fabric-capacity"
  ipcTarget: "azure.fabric-capacity"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Fabric's published F-SKU scale. Resizing only takes effect while a
  // capacity is paused, so each row's picker locks whenever it's on (or
  // mid-transition).
  readonly property var skuOptions: ["F2", "F4", "F8", "F16", "F32", "F64", "F128", "F256", "F512", "F1024", "F2048"]

  // Poll cadence. Also exposed via Omarchy's generic widget-settings schema
  // (manifest.json), but surfaced here too so it's editable in the same
  // right-click popup as the capacity list, without leaving the panel.
  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  readonly property int refreshIntervalSec: Math.max(15, Number(root.setting("refreshIntervalSec", 60)))
  readonly property int busyRefreshIntervalSec: Math.max(5, Number(root.setting("busyRefreshIntervalSec", 10)))

  // ---------------------------------------------------------------- config
  //
  // `settings.capacities` is the canonical list (array of full ARM resource
  // IDs), editable from the right-click config popup below. Falls back to
  // the single `resourceId` this plugin used before multi-capacity support,
  // so an existing single-capacity setup keeps working until re-saved.
  function computeCapacityIds(s) {
    // `settings.capacities` round-trips through Qt's JSON/QVariant bridge,
    // which can hand back a list-like object that fails a strict
    // Array.isArray() check even though it's iterable — duck-type on
    // `.length` instead of trusting the true-Array check.
    var raw = s ? s.capacities : null
    var list = raw && typeof raw.length === "number" ? raw : null
    var out = []
    var seen = ({})
    if (list) {
      for (var i = 0; i < list.length; i++) {
        var id = String(list[i] || "").trim()
        if (id !== "" && !seen[id]) { seen[id] = true; out.push(id) }
      }
    }
    if (out.length === 0) {
      var legacy = s ? String(s.resourceId || "").trim() : ""
      if (legacy !== "") out.push(legacy)
    }
    return out
  }

  readonly property var capacityIds: computeCapacityIds(root.settings)

  function saveCapacityIds(ids, refreshSec, busySec) {
    var list = ids && typeof ids.length === "number" ? ids : []
    var seen = ({})
    var out = []
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i] || "").trim()
      if (id === "" || seen[id]) continue
      seen[id] = true
      out.push(id)
    }
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) {
      if (key !== "id" && key !== "capacities" && key !== "resourceId"
          && key !== "refreshIntervalSec" && key !== "busyRefreshIntervalSec") entry[key] = root.settings[key]
    }
    entry.capacities = out
    entry.refreshIntervalSec = refreshSec
    entry.busyRefreshIntervalSec = busySec
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ------------------------------------------------------------ instances
  //
  // One CapacityService per configured id, tracked the same way the Agents
  // plugin tracks its per-provider Agent instances: an Instantiator keyed
  // off the id list, rebuilt into a plain array on every add/remove.
  property var capacityServices: []

  function rebuildCapacityServices() {
    var result = []
    for (var i = 0; i < capacityInstantiator.count; i++) {
      var obj = capacityInstantiator.objectAt(i)
      if (obj) result.push(obj)
    }
    capacityServices = result
  }

  function findCapacity(resourceId) {
    for (var i = 0; i < capacityServices.length; i++)
      if (capacityServices[i].resourceId === resourceId) return capacityServices[i]
    return null
  }

  function refreshAll() {
    for (var i = 0; i < capacityServices.length; i++) capacityServices[i].refresh()
  }

  Instantiator {
    id: capacityInstantiator
    model: root.capacityIds

    delegate: CapacityService {
      required property var modelData
      resourceId: modelData
      settings: root.settings
    }

    onObjectAdded: (index, object) => root.rebuildCapacityServices()
    onObjectRemoved: (index, object) => root.rebuildCapacityServices()
  }

  // -------------------------------------------------------------- summary
  //
  // The single bar icon has to speak for every configured capacity: it
  // lights up if any one of them is active, tints urgent if any one's
  // az login looks expired, and pulses while any one is transitioning.
  readonly property bool anyActive: {
    for (var i = 0; i < capacityServices.length; i++) if (capacityServices[i].active) return true
    return false
  }
  readonly property bool anyBusy: {
    for (var i = 0; i < capacityServices.length; i++) if (capacityServices[i].busy) return true
    return false
  }
  readonly property bool anyCredsExpired: {
    for (var i = 0; i < capacityServices.length; i++) if (capacityServices[i].credsExpired) return true
    return false
  }

  function launchAzLogin() {
    if (root.bar) root.bar.run("omarchy launch terminal az login")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // -------------------------------------------------------- monitor panel

  onOpenedChanged: if (opened) {
    root.refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function pause(resourceId: string): string { var c = root.findCapacity(resourceId); if (c) c.pause(); return "ok" }
    function resume(resourceId: string): string { var c = root.findCapacity(resourceId); if (c) c.resume(); return "ok" }
    function setSku(resourceId: string, value: string): string { var c = root.findCapacity(resourceId); if (c) c.setSku(value); return "ok" }
    function list(): string { return JSON.stringify(root.capacityIds) }
    function status(): string {
      var out = []
      for (var i = 0; i < root.capacityServices.length; i++) {
        var c = root.capacityServices[i]
        out.push({ resourceId: c.resourceId, name: c.capacityName, state: c.state, sku: c.sku, credsExpired: c.credsExpired })
      }
      return JSON.stringify(out)
    }
    function openConfig(): void { root.openConfig() }
    function closeConfig(): void { root.closeConfig() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.anyActive || root.anyCredsExpired

    iconComponent: Component {
      Item {
        FabricMark {
          anchors.centerIn: parent
          size: Style.bar.iconCanvas
          grayscale: !root.anyActive && !root.anyCredsExpired
          tinted: root.anyCredsExpired
          tintColor: root.urgent
          pulsing: root.anyBusy
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.close()
        root.toggleConfig()
      } else if (buttonCode === Qt.MiddleButton) {
        root.refreshAll()
      } else {
        root.closeConfig()
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {}
      onActivateRequested: {}
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {}

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(14)

          Text {
            visible: root.capacityIds.length === 0
            width: parent.width
            topPadding: Style.space(16)
            text: "No capacities configured.\nRight-click the bar icon to add one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.capacityServices

            delegate: CapacityRow {
              required property var modelData
              required property int index
              width: column.width
              capacity: modelData
              first: index === 0
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------- config panel

  property bool configOpened: false
  function openConfig() {
    configOpened = true
  }
  function closeConfig() {
    configOpened = false
  }
  function toggleConfig() {
    configOpened = !configOpened
  }

  // KeyboardPanel's outside-click/Escape dismissal calls `owner.close()`.
  // Pointing both popups' `owner` straight at `root` made the config
  // popup's dismissal call root.close() (the *main* panel's open/close,
  // via PanelController) instead of closeConfig() — so clicking away from
  // the settings popup silently did nothing to it while still eating the
  // click meant for whatever window was underneath, making it feel like a
  // stuck full-screen modal. Give the config popup its own owner so its
  // dismissal actually targets configOpened.
  readonly property QtObject configPanelOwner: QtObject {
    function close() { root.closeConfig() }
  }

  // ----------------------------------------------------- capacity discovery
  //
  // Lets the config popup offer every Fabric capacity the cached `az login`
  // can see as one drag-reorderable, toggle-to-enable list, instead of
  // requiring the user to copy each resource ID out of the portal by hand.
  // `capacityRows` is the single source of truth for the popup session: its
  // *array order* is the display order saved to settings.capacities (and
  // so the order CapacityRow instances render in on the left-click panel),
  // and each entry's `enabled` flag is whether it's checked. `source`
  // ("saved" | "discovered" | "manual") drives the remove button below,
  // which is offered for anything discovery hasn't (yet) vouched for in
  // this session — "manual" rows, but also "saved" ones, since reopening
  // the popup reseeds every saved row as "saved" regardless of how it
  // originally got there (see onConfigOpenedChanged).
  property var capacityRows: []   // [{ id, label, description, enabled, source }]
  property bool discovering: false
  property string discoverError: ""
  property int lastDiscoverCount: -1

  readonly property real capacityRowHeight: Style.space(44)
  property int draggingIndex: -1
  property real dragGhostY: 0
  property string dragGhostLabel: ""

  function lastPathSegment(id) {
    var parts = String(id || "").split("/")
    return parts.length > 0 ? parts[parts.length - 1] : String(id || "")
  }

  function capacityRowIndex(id) {
    for (var i = 0; i < capacityRows.length; i++) if (capacityRows[i].id === id) return i
    return -1
  }

  function setRowEnabled(index, value) {
    if (index < 0 || index >= capacityRows.length) return
    var rows = capacityRows.slice()
    rows[index] = { id: rows[index].id, label: rows[index].label, description: rows[index].description, enabled: value, source: rows[index].source }
    capacityRows = rows
  }

  function removeCapacityRow(index) {
    if (index < 0 || index >= capacityRows.length) return
    var rows = capacityRows.slice()
    rows.splice(index, 1)
    capacityRows = rows
  }

  function moveCapacityRow(from, to) {
    if (from === to || from < 0 || to < 0 || from >= capacityRows.length || to >= capacityRows.length) return
    var rows = capacityRows.slice()
    var item = rows.splice(from, 1)[0]
    rows.splice(to, 0, item)
    capacityRows = rows
  }

  // capacityRows' own array order *is* the display order — it's what Save
  // hands to saveCapacityIds, unchanged, so there's nothing else to sort.
  function enabledCapacityIds() {
    var ids = []
    for (var i = 0; i < capacityRows.length; i++) if (capacityRows[i].enabled) ids.push(capacityRows[i].id)
    return ids
  }

  function addManualCapacity(text) {
    var id = String(text || "").trim()
    if (id === "") return
    var idx = capacityRowIndex(id)
    if (idx === -1) {
      var rows = capacityRows.slice()
      rows.push({ id: id, label: root.lastPathSegment(id), description: "Added manually", enabled: true, source: "manual" })
      capacityRows = rows
    } else {
      setRowEnabled(idx, true)
    }
    manualIdField.text = ""
  }

  // Merges a discovery run's results into `capacityRows` in place: a
  // matching id is upgraded (real resource-group description, "discovered"
  // source — even if it was "manual" before, since Azure now vouches for
  // it) without disturbing its position or enabled state; a new id is
  // appended, unchecked, so the user opts it in rather than every
  // capacity in the tenant silently going live in the left-click panel.
  function mergeDiscovered(found) {
    root.lastDiscoverCount = found.length
    var rows = capacityRows.slice()
    for (var i = 0; i < found.length; i++) {
      var idx = capacityRowIndex(found[i].id)
      if (idx === -1) {
        rows.push({ id: found[i].id, label: root.lastPathSegment(found[i].id), description: found[i].description, enabled: false, source: "discovered" })
      } else {
        rows[idx] = { id: rows[idx].id, label: rows[idx].label, description: found[i].description, enabled: rows[idx].enabled, source: "discovered" }
      }
    }
    capacityRows = rows
  }

  // Mirrors CapacityService's own looksLikeAuthFailure — kept local rather
  // than shared since it's a handful of lines and the two components are
  // otherwise independent (one process per configured capacity vs. this
  // one-off discovery call).
  function looksLikeAuthFailure(text) {
    var t = String(text || "").toLowerCase()
    return t.indexOf("az login") >= 0
      || t.indexOf("refresh token") >= 0
      || t.indexOf("interactive authentication is needed") >= 0
      || t.indexOf("aadsts700082") >= 0
      || t.indexOf("aadsts70008") >= 0
  }

  readonly property string discoverStatusText: {
    if (root.discovering) return "Searching your Azure subscriptions…"
    if (root.discoverError !== "") return root.discoverError
    if (root.lastDiscoverCount >= 0) {
      return "Found " + root.lastDiscoverCount
        + (root.lastDiscoverCount === 1 ? " capacity." : " capacities.")
    }
    return "Not discovered yet — click Discover, or add one manually below."
  }

  function discoverCapacities() {
    if (discoverProcess.running) return
    discoverError = ""
    discovering = true
    discoverProcess.running = true
  }

  property string _discoverStderr: ""
  property var _discoverFound: []

  // Loops `az resource list` over every subscription the cached login can
  // see. TSV output (not JSON) so results from successive subscriptions can
  // just be concatenated line-by-line — chaining `az resource list` calls'
  // JSON array output together wouldn't parse as one document. `pipefail`
  // makes an expired-login failure in `az account list` (which would
  // otherwise leave the `while read` loop silently iterating zero lines and
  // exiting 0) surface as the pipeline's exit code instead.
  Process {
    id: discoverProcess
    command: ["bash", "-lc",
      "set -o pipefail; az account list --query \"[].id\" -o tsv | while IFS= read -r sub; do az resource list --subscription \"$sub\" --resource-type Microsoft.Fabric/capacities --query \"[].[id,resourceGroup]\" -o tsv 2>/dev/null; done"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var found = []
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].replace(/\r$/, "")
          if (line.trim() === "") continue
          var parts = line.split("\t")
          var id = (parts[0] || "").trim()
          var rg = (parts[1] || "").trim()
          if (id === "") continue
          found.push({ id: id, description: rg !== "" ? "Resource group: " + rg : "" })
        }
        root._discoverFound = found
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._discoverStderr = String(text || "").trim()
    }

    onExited: function(exitCode) {
      root.discovering = false
      if (exitCode !== 0) {
        root.discoverError = root.looksLikeAuthFailure(root._discoverStderr)
          ? "Azure sign-in expired. Run az login, then try Discover again."
          : (root._discoverStderr !== "" ? root._discoverStderr : "Discovery failed (exit " + exitCode + ")")
      } else {
        root.mergeDiscovered(root._discoverFound)
        root.discoverError = root._discoverFound.length === 0 ? "No Fabric capacities found across your subscriptions." : ""
      }
      root._discoverStderr = ""
      root._discoverFound = []
    }
  }

  onConfigOpenedChanged: if (configOpened) {
    var rows = []
    for (var i = 0; i < root.capacityIds.length; i++) {
      rows.push({ id: root.capacityIds[i], label: root.lastPathSegment(root.capacityIds[i]), description: "", enabled: true, source: "saved" })
    }
    capacityRows = rows
    refreshField.field.value = root.refreshIntervalSec
    busyField.field.value = root.busyRefreshIntervalSec
  }

  KeyboardPanel {
    id: configPanel
    anchorItem: button
    owner: root.configPanelOwner
    bar: root.bar
    open: root.configOpened
    focusTarget: configKeyCatcher
    contentWidth: configPanel.fittedContentWidth(Style.space(360))
    // No height cap here (unlike contentWidth's 360 above): this content
    // isn't wrapped in a Flickable like the main panel's is, and reusing
    // that same 360 figure as a height cap left it well short of what the
    // title/textarea/polling fields/button row actually need, so the card
    // background rendered shorter than the (unclipped) content and the
    // Save/Cancel row spilled out below it. fittedContentHeight still
    // bounds this to the screen's available height on its own.
    contentHeight: configPanel.fittedContentHeight(configColumn.implicitHeight)

    PanelKeyCatcher {
      id: configKeyCatcher
      anchors.fill: parent
      onCloseRequested: root.closeConfig()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: configColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Text {
          text: "Fabric capacities"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          text: "Discover capacities from your az login, drag ⋮⋮ to reorder, and toggle which ones show in the left-click panel."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          width: configColumn.width
          spacing: Style.space(8)

          Button {
            id: discoverButton
            Layout.alignment: Qt.AlignVCenter
            enabled: !root.discovering
            text: root.discovering ? "Discovering…" : "Discover capacities"
            iconText: "󰑐"
            iconSpinning: root.discovering
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.discoverCapacities()
          }

          Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.discoverStatusText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        RowLayout {
          width: configColumn.width
          spacing: Style.space(8)

          TextField {
            id: manualIdField
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            placeholderText: "Or paste a resource ID to add manually"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Keys.onReturnPressed: root.addManualCapacity(manualIdField.text)
          }

          Button {
            text: "Add"
            Layout.alignment: Qt.AlignVCenter
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.addManualCapacity(manualIdField.text)
          }
        }

        Text {
          width: parent.width
          visible: root.capacityRows.length === 0
          text: "No capacities yet — Discover or add one manually above."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Capped-height scroll area so a long capacity list can't push the
        // Polling section and Save/Cancel row off screen; short lists just
        // shrink to fit instead of leaving dead scroll space. A plain
        // ScrollView left this unscrollable in practice — with no
        // Flickable-derived content and no explicit contentHeight of its
        // own, it had nothing to tell it the list was taller than the
        // capped viewport, so rows past the cap just went unreachable
        // instead of becoming scrollable. Mirrors the main panel's own
        // Flickable further up this file: explicit contentWidth/
        // contentHeight instead of relying on implicit content sizing.
        Flickable {
          id: capacityFlick
          visible: root.capacityRows.length > 0
          width: configColumn.width
          height: Math.min(rowsColumn.implicitHeight, Style.space(230))
          contentWidth: width
          contentHeight: rowsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // The ghost below has to be a sibling of the Column, not a
          // child of it: Column would fight its explicit `y` binding the
          // same way it fought the Save/Cancel row's anchors earlier in
          // this file — a positioner claims every direct child's
          // position, full stop, whatever else that child sets. A
          // Flickable doesn't reposition its children that way (it moves
          // the whole content via one transform), so it's a safe parent
          // for both.
          Column {
              id: rowsColumn
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.capacityRows

                // The dragged row's own position stays Column-managed (see
                // the MouseArea comment below) — only a floating ghost
                // tracks the cursor — so there's nothing here to unwind if
                // a drag is abandoned mid-gesture.
                delegate: Item {
                  id: rowItem
                  required property var modelData
                  required property int index
                  width: rowsColumn.width
                  height: root.capacityRowHeight
                  opacity: root.draggingIndex === index ? 0.35 : 1.0

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(4)
                    anchors.rightMargin: Style.space(4)
                    spacing: Style.space(8)

                    Text {
                      text: "⋮⋮"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      Layout.alignment: Qt.AlignVCenter

                      // `rowItem` is a Column/Repeater-owned child — Column
                      // sets its y every layout pass, so assigning
                      // drag.target to it directly would fight that (and
                      // leave stale offsets once the array reorders out
                      // from under it, the same trap the bar's own
                      // module-reorder code documents avoiding). Track the
                      // raw pointer delta instead and drive a separate
                      // floating ghost; the real row is only ever touched
                      // once, on release, via moveCapacityRow.
                      MouseArea {
                        id: gripArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        cursorShape: Qt.SizeVerCursor
                        property real pressY: 0

                        onPressed: function(mouse) {
                          var p = gripArea.mapToItem(rowsColumn, 0, mouse.y)
                          pressY = p.y
                          root.draggingIndex = rowItem.index
                          root.dragGhostLabel = rowItem.modelData.label
                          root.dragGhostY = rowItem.y
                        }
                        onPositionChanged: function(mouse) {
                          if (root.draggingIndex !== rowItem.index) return
                          var p = gripArea.mapToItem(rowsColumn, 0, mouse.y)
                          var slot = root.capacityRowHeight + rowsColumn.spacing
                          var proposed = rowItem.index * slot + (p.y - pressY)
                          root.dragGhostY = Math.max(0, Math.min(rowsColumn.height - root.capacityRowHeight, proposed))
                        }
                        onReleased: {
                          if (root.draggingIndex === -1) return
                          var slot = root.capacityRowHeight + rowsColumn.spacing
                          var targetIndex = Math.round(root.dragGhostY / slot)
                          targetIndex = Math.max(0, Math.min(root.capacityRows.length - 1, targetIndex))
                          root.moveCapacityRow(root.draggingIndex, targetIndex)
                          root.draggingIndex = -1
                        }
                        onCanceled: root.draggingIndex = -1
                      }
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0

                      Text {
                        Layout.fillWidth: true
                        text: rowItem.modelData.label
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                      Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: rowItem.modelData.description
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      Layout.alignment: Qt.AlignVCenter
                      // Not just source === "manual": reopening the popup
                      // reseeds every saved row with source "saved" (see
                      // onConfigOpenedChanged), so a manually-added entry
                      // loses that tag the moment it's saved — which used
                      // to mean losing the only way to get rid of it again
                      // short of a save-while-unchecked round trip. Offer
                      // it for anything discovery hasn't (yet) vouched for
                      // instead.
                      visible: rowItem.modelData.source !== "discovered"
                      iconText: "󰅙"
                      tooltipText: "Remove"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.removeCapacityRow(rowItem.index)
                    }

                    ToggleSwitch {
                      Layout.alignment: Qt.AlignVCenter
                      checked: rowItem.modelData.enabled
                      foreground: root.foreground
                      onToggled: root.setRowEnabled(rowItem.index, !rowItem.modelData.enabled)
                    }
                  }
                }
              }
            }

            // Drop-target ghost: a floating copy of the dragged row's
            // label that follows the vertical drag. A sibling of the
            // Column above, not a child of it — see the comment on this
            // Flickable's declaration.
            Rectangle {
              visible: root.draggingIndex !== -1
              x: 0
              y: root.dragGhostY
              width: rowsColumn.width
              height: root.capacityRowHeight
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, Color.accent)
              border.width: 1
              border.color: Color.accent
              z: 100

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                text: root.dragGhostLabel
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
        }

        Text {
          text: "Polling"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          topPadding: Style.space(4)
        }

        NumberField {
          id: refreshField
          label: "Refresh interval (seconds)"
          from: 15
          to: 3600
          stepSize: 15
          value: root.refreshIntervalSec
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        NumberField {
          id: busyField
          label: "Refresh interval while pausing/resuming (seconds)"
          from: 5
          to: 60
          stepSize: 5
          value: root.busyRefreshIntervalSec
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Positioners like Column don't support anchoring a direct child
        // (it silently falls out of the stacking flow and doesn't count
        // toward implicitHeight), which was leaving this row rendered
        // below the card's computed height entirely — the background
        // never reached it. Wrap it in a plain Item sized by the Column
        // instead, and anchor the Row to *that*.
        Item {
          width: configColumn.width
          height: buttonRow.implicitHeight

          Row {
            id: buttonRow
            anchors.right: parent.right
            spacing: Style.space(8)

            Button {
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.closeConfig()
            }

            Button {
              text: "Save"
              selected: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.saveCapacityIds(root.enabledCapacityIds(), refreshField.field.value, busyField.field.value)
                root.closeConfig()
              }
            }
          }
        }
      }
    }
  }

  // One capacity's hero row: icon, name, live state, SKU picker, and the
  // pause/resume switch. `first` suppresses the leading separator so the
  // list doesn't open with a stray rule above the first row.
  component CapacityRow: Column {
    id: capRow
    required property var capacity
    property bool first: false
    spacing: Style.space(10)

    readonly property string displayName: capacity.capacityName !== "" ? capacity.capacityName : "Fabric Capacity"
    readonly property string rowMeta: {
      if (capacity.credsExpired) return "Azure sign-in expired"
      if (!capacity.stateLoaded) return "Checking status…"
      if (capacity.actionStatus !== "") return capacity.actionStatus
      return capacity.state !== "" ? capacity.state : "Unknown"
    }
    readonly property string toggleHint: capacity.active ? "Pause capacity" : "Resume capacity"
    readonly property bool skuLocked: capacity.active || capacity.busy || capacity.credsExpired
    readonly property string skuHint: capacity.credsExpired ? "" : (skuLocked ? "Pause the capacity to change its size" : "Capacity size (SKU)")

    PanelSeparator {
      visible: !capRow.first
      foreground: root.foreground
    }

    PanelHero {
      id: hero
      width: parent.width
      title: capRow.displayName
      meta: capRow.rowMeta
      foreground: root.foreground
      fontFamily: root.fontFamily

      iconComponent: Component {
        FabricMark {
          size: Style.font.display
          grayscale: !capRow.capacity.active && !capRow.capacity.credsExpired
          tinted: capRow.capacity.credsExpired
          tintColor: root.urgent
          pulsing: capRow.capacity.busy
        }
      }

      trailingControl: Component {
        RowLayout {
          spacing: Style.space(8)

          Dropdown {
            id: skuDropdown
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Style.space(92)
            visible: !capRow.capacity.credsExpired
            enabled: !capRow.skuLocked
            opacity: capRow.skuLocked ? 0.5 : 1.0
            showLabel: false
            options: root.skuOptions
            value: capRow.capacity.sku
            foreground: hero.foreground
            fontFamily: hero.fontFamily

            onChanged: function(v) { capRow.capacity.setSku(v) }

            // Picking an option makes Dropdown assign its own `value`
            // directly, severing the `value: capacity.sku` binding above.
            // Re-sync on every completed probe (not just when sku actually
            // changes) so a rejected setSku() — where Azure's confirmed
            // value comes back the same as before — still snaps the picker
            // back instead of leaving it stuck on the attempted value.
            Connections {
              target: capRow.capacity
              function onProbed() { skuDropdown.value = capRow.capacity.sku }
            }

            Behavior on opacity { NumberAnimation { duration: 160 } }

            PanelToolTip {
              visible: skuHover.hovered && capRow.skuHint !== ""
              text: capRow.skuHint
              fontFamily: hero.fontFamily
            }

            HoverHandler { id: skuHover }
          }

          ToggleSwitch {
            id: powerSwitch
            Layout.alignment: Qt.AlignVCenter
            visible: !capRow.capacity.credsExpired
            checked: capRow.capacity.active
            busy: capRow.capacity.busy
            foreground: hero.foreground
            onToggled: capRow.capacity.active ? capRow.capacity.pause() : capRow.capacity.resume()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: capRow.toggleHint
              fontFamily: hero.fontFamily
            }
          }
        }
      }
    }

    Text {
      visible: capRow.capacity.lastError !== "" && !capRow.capacity.credsExpired
      width: parent.width
      text: capRow.capacity.lastError
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    CredsRow {
      visible: capRow.capacity.credsExpired
      width: parent.width
      capacity: capRow.capacity
    }
  }

  // The Microsoft Fabric mark (assets/fabric.png), reused at bar-icon and
  // hero size. `tinted` recolors it solid and `grayscale` desaturates it,
  // both via MultiEffect (same trick the built-in tray uses for symbolic
  // icons), since a raster PNG can't be recolored with a plain `color`
  // property the way the glyph fonts elsewhere in this shell are.
  component FabricMark: Item {
    id: mark
    property real size: 16
    property bool tinted: false
    property color tintColor: "red"
    property bool grayscale: false
    property real dimOpacity: 1.0
    property bool pulsing: false

    readonly property bool effected: tinted || grayscale

    implicitWidth: size
    implicitHeight: size
    opacity: dimOpacity
    Behavior on opacity { NumberAnimation { duration: 160 } }

    SequentialAnimation on scale {
      running: mark.pulsing
      loops: Animation.Infinite
      NumberAnimation { to: 0.82; duration: 650; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
    }
    onPulsingChanged: if (!pulsing) scale = 1.0

    // The source Image stays permanently hidden-but-layered and the
    // MultiEffect stays permanently on, with only its numeric saturation/
    // colorization properties changing between states. Toggling `visible`/
    // `layer.enabled` themselves at runtime (rather than leaving them fixed
    // from creation) left the layered texture blank after a live
    // active-\>inactive transition instead of falling back to grayscale.
    Image {
      id: img
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      smooth: true
      source: Qt.resolvedUrl("assets/fabric.png")
      sourceSize.width: Math.round(mark.size * 2)
      sourceSize.height: Math.round(mark.size * 2)
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: img
      source: img
      saturation: mark.tinted ? 0.0 : (mark.grayscale ? -1.0 : 0.0)
      colorization: mark.tinted ? 1.0 : 0.0
      colorizationColor: mark.tintColor

      Behavior on saturation { NumberAnimation { duration: 200 } }
      Behavior on colorization { NumberAnimation { duration: 200 } }
    }
  }

  // Shown only when a row's status probe or an action fails in a way that
  // looks like the az CLI's cached login has expired. Clicking it opens a
  // terminal running `az login` instead of trying to drive the browser flow
  // headless. The login itself is shared across every capacity (one az CLI
  // session), so this doesn't need to know which row triggered it.
  component CredsRow: CursorSurface {
    id: credsRow
    required property var capacity
    property bool hot: false

    hasCursor: hot
    foreground: root.foreground
    implicitHeight: credsInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: credsRow.hot = true
      onExited: credsRow.hot = false
      onClicked: root.launchAzLogin()
    }

    RowLayout {
      id: credsInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: "󰀦"
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: "Azure sign-in expired"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: credsRow.capacity.lastError !== "" ? credsRow.capacity.lastError : "Click to open a terminal and run az login"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}

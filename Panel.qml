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

  function saveCapacityIds(text, refreshSec, busySec) {
    var lines = String(text || "").split("\n")
    var seen = ({})
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var id = lines[i].trim()
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

  onConfigOpenedChanged: if (configOpened) {
    idsArea.text = root.capacityIds.join("\n")
    refreshField.field.value = root.refreshIntervalSec
    busyField.field.value = root.busyRefreshIntervalSec
    Qt.callLater(function() { idsArea.forceActiveFocus() })
  }

  KeyboardPanel {
    id: configPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.configOpened
    focusTarget: configKeyCatcher
    contentWidth: configPanel.fittedContentWidth(Style.space(360))
    contentHeight: configPanel.fittedContentHeight(configColumn.implicitHeight, Style.space(360))

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
        anchors.margins: Style.space(4)
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
          text: "One Azure resource ID per line."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ScrollView {
          id: idsScroll
          width: parent.width
          height: Style.space(150)
          clip: true

          TextArea {
            id: idsArea
            width: idsScroll.width
            wrapMode: TextEdit.NoWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
            placeholderText: "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Fabric/capacities/<name>"
            placeholderTextColor: Qt.darker(root.foreground, 1.6)

            background: BorderSurface {
              color: Style.controlFill(idsArea.activeFocus, false, root.foreground, Color.accent)
              borderSpec: Border.controlSpec(idsArea.activeFocus ? "focus" : "normal", root.foreground, Color.accent)
              radius: Style.cornerRadius
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

        Row {
          spacing: Style.space(8)
          anchors.right: parent.right

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
              root.saveCapacityIds(idsArea.text, refreshField.field.value, busyField.field.value)
              root.closeConfig()
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

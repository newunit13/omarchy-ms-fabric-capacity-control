import QtQuick
import Quickshell.Io

// Polls one Azure Microsoft Fabric capacity's state via the az CLI (reusing
// whatever login is already cached) and exposes pause/resume/setSku actions.
// One of these is instantiated per configured resource ID (see Panel.qml's
// Instantiator). State values ending in "ing" (Pausing, Resuming,
// Provisioning, ...) are Azure's own transitional states, so `busy` derives
// from that suffix rather than an enumerated list.
Item {
  id: root
  visible: false

  // Set externally by the Instantiator delegate in Panel.qml, one per
  // configured capacity — not read from `settings`, since there can now be
  // several of these alive at once.
  property string resourceId: ""

  // Shared across every capacity (poll cadence, etc.); still comes from the
  // plugin's single settings object.
  property var settings: ({})

  readonly property int refreshIntervalSec: Math.max(15, Number(setting("refreshIntervalSec", 60)))
  readonly property int busyRefreshIntervalSec: Math.max(5, Number(setting("busyRefreshIntervalSec", 10)))

  readonly property string capacityName: {
    var parts = resourceId.split("/")
    return parts.length > 0 ? parts[parts.length - 1] : ""
  }

  property string state: ""
  property string sku: ""
  property bool stateLoaded: false
  property bool credsExpired: false
  property string lastError: ""
  property string actionStatus: ""

  readonly property bool active: state === "Active"
  readonly property bool busy: /ing$/.test(state) || actionProcess.running

  // Fires after every completed probe, success or failure — unlike
  // onSkuChanged, this also covers a rejected setSku() where Azure's
  // confirmed value comes back unchanged (no property change to react to,
  // but the UI still needs to snap back to it).
  signal probed()

  // Cleared automatically once Azure reports a settled (non-"ing") state.
  onStateChanged: if (!/ing$/.test(state)) actionStatus = ""

  // `resourceId` is bound from the Instantiator's model item and should be
  // set from construction, but a defensive re-probe here costs nothing and
  // covers any settings/model timing wrinkle the same way it did before
  // multi-capacity support.
  onResourceIdChanged: refresh()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function quoted(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
  }

  function looksLikeAuthFailure(text) {
    var t = String(text || "").toLowerCase()
    return t.indexOf("az login") >= 0
      || t.indexOf("refresh token") >= 0
      || t.indexOf("interactive authentication is needed") >= 0
      || t.indexOf("aadsts700082") >= 0
      || t.indexOf("aadsts70008") >= 0
  }

  function refresh() {
    if (resourceId === "") {
      lastError = "No capacity resourceId configured."
      stateLoaded = true
      return
    }
    if (!statusProbe.running) statusProbe.running = true
  }

  // Distinguishes what actionProcess.onExited should do with actionStatus
  // on success: pause/resume actually move `state` through a transitional
  // "-ing" value, so onStateChanged above clears it once that settles.
  // setSku never touches `state` at all (see below), so nothing would ever
  // clear it without onExited doing so directly.
  property string pendingAction: ""

  function pause() { invoke("suspend", "Pausing…", "pause") }
  function resume() { invoke("resume", "Resuming…", "resume") }

  function invoke(action, statusText, kind) {
    if (resourceId === "" || actionProcess.running) return
    actionStatus = statusText
    pendingAction = kind
    actionProcess.command = ["bash", "-lc",
      "az resource invoke-action --ids " + quoted(resourceId) + " --action " + action + " -o none"]
    actionProcess.running = true
  }

  // Resizing only takes effect while paused; the caller (the panel's SKU
  // picker) already locks itself while active, this just double-checks.
  //
  // `az resource update --set sku.name=...` (a read-modify-PUT of the whole
  // resource) gets rejected by Fabric's RP with "Service is not ready to be
  // updated" even on a paused capacity. A targeted PATCH of just the sku
  // object — what the Azure portal itself sends — is what Fabric actually
  // accepts.
  function setSku(newSku) {
    if (resourceId === "" || actionProcess.running || active) return
    var value = String(newSku || "")
    if (value === "" || value === sku) return
    actionStatus = "Changing size…"
    pendingAction = "sku"
    var propsJson = JSON.stringify({ sku: { name: value } })
    actionProcess.command = ["bash", "-lc",
      "az resource patch --ids " + quoted(resourceId) + " --is-full-object --properties " + quoted(propsJson) + " -o none"]
    actionProcess.running = true
  }

  property string _statusStderr: ""

  Process {
    id: statusProbe
    command: ["bash", "-lc",
      "az resource show --ids " + root.quoted(root.resourceId) + " --query \"{state:properties.state, sku:sku.name}\" -o json"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.state) root.state = String(parsed.state)
          if (parsed && parsed.sku) root.sku = String(parsed.sku)
          root.lastError = ""
          root.credsExpired = false
        } catch (e) {
          // Leave prior state/sku alone; onExited below still runs with
          // exitCode 0, so nothing else flags this as a failed probe. A
          // malformed response here is rare enough not to special-case.
        }
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._statusStderr = String(text || "").trim()
    }

    onExited: function(exitCode) {
      root.stateLoaded = true
      if (exitCode !== 0) {
        root.lastError = root._statusStderr !== "" ? root._statusStderr : "az resource show failed (exit " + exitCode + ")"
        root.credsExpired = root.looksLikeAuthFailure(root._statusStderr)
      }
      root._statusStderr = ""
      root.probed()
    }
  }

  property string _actionStderr: ""

  Process {
    id: actionProcess

    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._actionStderr = String(text || "").trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root._actionStderr !== "" ? root._actionStderr : "Action failed (exit " + exitCode + ")"
        root.credsExpired = root.looksLikeAuthFailure(root._actionStderr)
        root.actionStatus = ""
      } else if (root.pendingAction === "sku") {
        // Unlike pause/resume, a successful sku change never moves `state`
        // through a transitional value, so onStateChanged will never fire
        // to clear this — clear it here instead.
        root.actionStatus = ""
      }
      root.pendingAction = ""
      root._actionStderr = ""
      // Pick up whatever Azure reports next, whether the call succeeded
      // (now "Pausing"/"Resuming") or failed (state unchanged).
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Faster polling only while a transition is actually in flight.
  Timer {
    interval: root.busyRefreshIntervalSec * 1000
    running: root.busy
    repeat: true
    onTriggered: root.refresh()
  }
}

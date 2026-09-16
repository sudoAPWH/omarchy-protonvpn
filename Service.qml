import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Every conversation with the `protonvpn` CLI lives here so the panel stays
// declarative. The CLI has no JSON mode and no daemon socket we can subscribe
// to, so state is polled — but sparingly: a NetworkManager monitor supplies
// the fast path for connects and drops that happen outside this widget, and
// the timer is only a backstop.
Item {
  id: root

  property var settings: ({})

  // --- discovery -----------------------------------------------------------
  // The absolute path state-helper.py found for the CLI. Everything that runs
  // it uses this, so no call is ever resolved through $PATH.
  property string cliPath: ""
  readonly property bool installed: cliPath !== ""
  property bool installChecked: false

  readonly property string helperPath:
    decodeURIComponent(String(Qt.resolvedUrl("state-helper.py")).replace(/^file:\/\//, ""))

  function helperCommand(mode, argument) {
    return ["/usr/bin/python3", "-I", "-S", helperPath, mode, argument]
  }

  // --- account -------------------------------------------------------------
  property string accountName: ""
  property bool accountKnown: false
  readonly property bool signedIn: accountKnown && !Model.isSignedOutAccount(accountName)

  // --- connection ----------------------------------------------------------
  property bool connected: false
  property string serverName: ""
  property string serverLocation: ""
  property int serverLoad: -1
  property string protocol: ""

  // Optimistic overlay. `protonvpn connect` can take 10-20s to return, so the
  // UI commits to the requested state immediately and reconciles when the
  // command exits. -1 means "just report what the CLI last told us".
  property int desiredState: -1
  property string pendingLabel: ""
  readonly property bool active: desiredState === -1 ? connected : (desiredState === 1)
  readonly property bool transitioning: desiredState !== -1

  // --- catalogue -----------------------------------------------------------
  property var countries: []
  property var citiesByCountry: ({})
  property string citiesPendingFor: ""
  property var config: ({})
  property var recents: []
  property var favorites: []
  property string pendingSetting: ""

  // --- feedback ------------------------------------------------------------
  property bool refreshing: false
  property string lastError: ""
  property string actionStatus: ""
  property bool awaitingSignin: false

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int recentLimit: intSetting("recentLimit", 5, 0, 20)
  readonly property bool busy: actionProcess.running || signoutProcess.running
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy-protonvpn"

  signal connectionChanged()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ------------------------------------------------------------- reading

  function refresh() {
    if (!installChecked) {
      if (!resolveProcess.running) {
        resolveProcess.command = helperCommand("resolve", "protonvpn")
        resolveProcess.running = true
      }
      return
    }
    if (!installed) return

    if (!statusProcess.running) {
      refreshing = true
      statusProcess.command = Model.cliCommand(root.cliPath, ["status"])
      statusProcess.running = true
    }
    if (!accountProcess.running) {
      accountProcess.command = Model.cliCommand(root.cliPath, ["info"])
      accountProcess.running = true
    }
  }

  // Catalogue and settings are only meaningful once signed in, and neither
  // changes minute to minute — fetch them on demand (panel open) rather than
  // on the status cadence.
  function refreshCatalogue(force) {
    if (!installed || !signedIn) return
    if ((force || countries.length === 0) && !countriesProcess.running) {
      countriesProcess.command = Model.cliCommand(root.cliPath, ["countries", "list"])
      countriesProcess.running = true
    }
    if ((force || Object.keys(config).length === 0) && !configProcess.running) {
      configProcess.command = Model.cliCommand(root.cliPath, ["config", "list"])
      configProcess.running = true
    }
  }

  function loadCities(code) {
    var key = String(code || "").toUpperCase()
    if (!installed || !signedIn || key === "") return
    if (citiesByCountry[key] !== undefined || citiesProcess.running) return
    citiesPendingFor = key
    citiesProcess.command = Model.cliCommand(root.cliPath, ["cities", "list", key])
    citiesProcess.running = true
  }

  function applyStatus(stdout) {
    var parsed = Model.parseStatus(stdout)
    var was = connected
    connected = parsed.connected
    serverName = parsed.server
    serverLocation = parsed.location
    serverLoad = parsed.load
    protocol = parsed.protocol
    if (was !== connected) connectionChanged()
  }

  // ------------------------------------------------------------- actions

  function runAction(argv, label, desired) {
    if (!installed || actionProcess.running) return
    lastError = ""
    actionStatus = label
    desiredState = desired
    pendingLabel = label
    actionProcess.command = Model.cliCommand(argv)
    actionProcess.running = true
  }

  function connectTo(target) {
    if (!signedIn) return
    var label = target && target.label ? String(target.label) : "Fastest server"
    runAction(Model.connectArgs(target), "Connecting to " + label + "…", 1)
    rememberTarget(target)
  }

  function disconnect() {
    runAction(["disconnect"], "Disconnecting…", 0)
  }

  function toggleConnection() {
    if (busy) return
    if (active) disconnect()
    else connectTo({ kind: "fastest", value: "", label: "Fastest server" })
  }

  function setConfigValue(key, value) {
    if (!signedIn || actionProcess.running) return
    // The CLI refuses kill-switch changes while a tunnel is up; say so here
    // rather than surfacing a raw usage error.
    if (key === "kill-switch" && connected) {
      lastError = "Disconnect before changing the kill switch."
      return
    }
    pendingSetting = key
    runAction(["config", "set", key, value], "Setting " + key + "…", desiredState)
  }

  // `protonvpn signin` reads the password (and any 2FA token) with
  // getpass(), so it needs a real TTY — there is no headless path. Hand the
  // flow to a terminal and watch for it to land.
  function signIn(username) {
    var name = Model.trim(username)
    if (!installed || name === "") return
    lastError = ""
    actionStatus = "Finish signing in from the terminal…"
    awaitingSignin = true
    Quickshell.execDetached([
      "/usr/bin/omarchy-launch-floating-terminal-with-presentation",
      Model.cliShell(cliPath, "signin " + Util.shellQuote(name))
    ])
    signinWatchTimer.restart()
    signinGiveUpTimer.restart()
  }

  function signOut() {
    if (!installed || signoutProcess.running) return
    lastError = ""
    actionStatus = "Signing out…"
    signoutProcess.command = Model.cliCommand(root.cliPath, ["signout"])
    signoutProcess.running = true
  }

  // ------------------------------------------------------------- recents

  function rememberTarget(target) {
    if (recentLimit === 0 || !target) return
    // "Fastest" already has its own button; keeping it out of recents leaves
    // the list for places the user actually picked.
    if (String(target.kind) === "fastest") return
    recents = Model.addRecent(recents, {
      kind: String(target.kind || ""),
      value: String(target.value || ""),
      label: String(target.label || "")
    }, recentLimit)
    writeRecents(recents)
  }

  function setRecents(list) {
    writeRecents(list)
  }

  // ----------------------------------------------------------- favorites

  function isFavorite(code) {
    var key = String(code || "").toUpperCase()
    for (var i = 0; i < favorites.length; i++) {
      if (favorites[i].code === key) return true
    }
    return false
  }

  function toggleFavorite(code, name) {
    var key = String(code || "").toUpperCase()
    if (key === "") return
    var next = []
    var removed = false
    for (var i = 0; i < favorites.length; i++) {
      if (favorites[i].code === key) removed = true
      else next.push(favorites[i])
    }
    // Newly starred countries go to the end so the home list keeps the order
    // the user built it in rather than reshuffling on every change.
    if (!removed) next.push({ code: key, name: String(name || key) })
    writeFavorites(next)
  }

  function flashStatus(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  function reportFailure(fallback, stdout, stderr) {
    var text = Model.trim(stderr) || Model.trim(stdout)
    // click prints "Usage: ...\nTry '... --help'" around the real message;
    // the Error line is the only part worth showing in a popup.
    var rows = Model.textLines(text)
    for (var i = 0; i < rows.length; i++) {
      var line = Model.trim(rows[i])
      if (line.indexOf("Error:") === 0) {
        lastError = Model.trim(line.slice(6))
        return
      }
    }
    lastError = text !== "" ? rows[0] : fallback
  }

  // ------------------------------------------------------------- processes

  Process {
    id: resolveProcess
    running: false
    stdout: StdioCollector { id: resolveOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.installChecked = true
      root.cliPath = exitCode === 0 ? Model.trim(resolveOut.text) : ""
      if (root.installed) root.refresh()
    }
  }

  Process {
    id: statusProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) {
        root.applyStatus(statusOut.text || "")
        // The CLI has spoken; drop the optimistic overlay.
        root.desiredState = -1
        root.pendingLabel = ""
      } else {
        root.reportFailure("Could not read VPN status", statusOut.text, statusErr.text)
      }
    }
  }

  Process {
    id: accountProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: accountOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var name = Model.parseAccount(accountOut.text || "")
      var wasSignedIn = root.signedIn
      root.accountName = name
      root.accountKnown = true
      if (root.signedIn && !wasSignedIn) {
        // Sign-in just landed (possibly from the terminal we launched).
        root.awaitingSignin = false
        signinWatchTimer.stop()
        signinGiveUpTimer.stop()
        root.flashStatus("Signed in as " + name)
        root.refreshCatalogue(true)
      } else if (!root.signedIn && wasSignedIn) {
        root.countries = []
        root.citiesByCountry = ({})
        root.config = ({})
      }
    }
  }

  Process {
    id: countriesProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: countriesOut; waitForEnd: true }
    stderr: StdioCollector { id: countriesErr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = countriesOut.text || ""
      if (exitCode === 0) {
        root.countries = Model.parseCountries(text)
        return
      }
      if (!Model.isAuthError(text + countriesErr.text)) {
        root.reportFailure("Could not load the country list", text, countriesErr.text)
      }
    }
  }

  Process {
    id: citiesProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: citiesOut; waitForEnd: true }
    onExited: function(exitCode) {
      var code = root.citiesPendingFor
      root.citiesPendingFor = ""
      if (code === "") return
      var next = {}
      for (var key in root.citiesByCountry) next[key] = root.citiesByCountry[key]
      next[code] = exitCode === 0 ? Model.parseCities(citiesOut.text || "") : []
      root.citiesByCountry = next
    }
  }

  Process {
    id: configProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.config = Model.parseConfig(configOut.text || "")
    }
  }

  Process {
    id: actionProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var settingKey = root.pendingSetting
      root.pendingSetting = ""
      if (exitCode === 0) {
        root.flashStatus(Model.trim(Model.textLines(actionOut.text || "")[0]))
      } else {
        root.reportFailure("Command failed", actionOut.text, actionErr.text)
        root.actionStatus = ""
        // The optimistic state was a guess and the guess was wrong.
        root.desiredState = -1
        root.pendingLabel = ""
      }
      if (settingKey !== "") root.refreshCatalogue(true)
      root.refresh()
    }
  }

  Process {
    id: signoutProcess
    running: false
    environment: Model.CLI_ENVIRONMENT
    stdout: StdioCollector { id: signoutOut; waitForEnd: true }
    stderr: StdioCollector { id: signoutErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.accountName = "None"
        root.countries = []
        root.citiesByCountry = ({})
        root.config = ({})
        root.flashStatus("Signed out")
      } else {
        root.reportFailure("Sign out failed", signoutOut.text, signoutErr.text)
      }
      root.refresh()
    }
  }

  // NetworkManager is what the CLI drives, so its event stream is the cheapest
  // way to notice a tunnel coming up or dropping — including connects made
  // from another terminal, or a drop we did not ask for. Purely an accelerant:
  // if nmcli is missing the poll timer still carries the widget.
  Process {
    id: networkMonitor
    running: true
    command: ["/usr/bin/nmcli", "monitor"]
    stdout: SplitParser {
      onRead: function(line) {
        if (Model.trim(line) === "") return
        networkSettleTimer.restart()
      }
    }
    onExited: networkMonitorRestart.restart()
  }

  Timer {
    id: networkMonitorRestart
    interval: 5000
    onTriggered: networkMonitor.running = true
  }

  // nmcli emits a burst of lines per transition; wait for it to settle so one
  // connect costs one status read.
  Timer {
    id: networkSettleTimer
    interval: 1200
    onTriggered: if (root.installed && !actionProcess.running) root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.installed
    onTriggered: if (!actionProcess.running) root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 4000
    onTriggered: root.actionStatus = ""
  }

  // Poll for the terminal sign-in landing so the panel updates itself the
  // moment the user finishes, without them having to click anything.
  Timer {
    id: signinWatchTimer
    interval: 2000
    repeat: true
    onTriggered: if (!accountProcess.running) {
      accountProcess.command = Model.cliCommand(root.cliPath, ["info"])
      accountProcess.running = true
    }
  }

  Timer {
    id: signinGiveUpTimer
    interval: 180000
    onTriggered: {
      signinWatchTimer.stop()
      root.awaitingSignin = false
      root.actionStatus = ""
    }
  }

  // ------------------------------------------------------- state on disk
  //
  // Starred countries and recent connections are read and written through
  // state-helper.py rather than opened here. It walks the folders with
  // O_NOFOLLOW, checks each descriptor it opens, and replaces the file through
  // a same-directory temporary, so a path swapped underneath is refused instead
  // of followed. It also creates the folder, which is why there is no mkdir.
  //
  // A file that cannot be read, or that holds something this did not write, is
  // left alone: writing over it would turn an unreadable file into a lost one.
  property bool recentsLocked: false
  property bool favoritesLocked: false
  property string recentsPayload: ""
  property string favoritesPayload: ""

  readonly property string recentsPath: statePath + "/recents.json"
  readonly property string favoritesPath: statePath + "/favorites.json"

  function loadState() {
    if (!recentsReader.running) {
      recentsReader.command = helperCommand("read", recentsPath)
      recentsReader.running = true
    }
    if (!favoritesReader.running) {
      favoritesReader.command = helperCommand("read", favoritesPath)
      favoritesReader.running = true
    }
  }

  function writeRecents(list) {
    recents = list
    if (recentsLocked || recentsWriter.running) return
    recentsPayload = JSON.stringify(list, null, 2) + "\n"
    recentsWriter.command = helperCommand("write", recentsPath)
    recentsWriter.running = true
  }

  function writeFavorites(list) {
    favorites = list
    if (favoritesLocked || favoritesWriter.running) return
    favoritesPayload = JSON.stringify(list, null, 2) + "\n"
    favoritesWriter.command = helperCommand("write", favoritesPath)
    favoritesWriter.running = true
  }

  // 15 is "no file yet", which is simply an empty list on first run.
  function readState(exitCode, text, path) {
    if (exitCode === 15) return { list: [], locked: false }
    if (exitCode !== 0) {
      console.warn("omarchy-protonvpn: cannot read " + path + " (" + exitCode + ")")
      return { list: null, locked: true }
    }
    var problem = Model.stateProblem(text)
    if (problem !== "") {
      console.warn("omarchy-protonvpn: " + path + " is " + problem + ", leaving it alone")
      return { list: null, locked: true }
    }
    return { list: text, locked: false }
  }

  Process {
    id: recentsReader
    running: false
    stdout: StdioCollector { id: recentsOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.readState(exitCode, recentsOut.text, root.recentsPath)
      root.recentsLocked = result.locked
      if (result.list !== null)
        root.recents = Model.normalizeRecents(result.list === "" ? "[]" : result.list, root.recentLimit)
    }
  }

  Process {
    id: favoritesReader
    running: false
    stdout: StdioCollector { id: favoritesOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.readState(exitCode, favoritesOut.text, root.favoritesPath)
      root.favoritesLocked = result.locked
      if (result.list !== null)
        root.favorites = Model.normalizeFavorites(result.list === "" ? "[]" : result.list)
    }
  }

  Process {
    id: recentsWriter
    running: false
    stdinEnabled: true
    onStarted: {
      write(root.recentsPayload)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      if (exitCode !== 0) {
        root.recentsLocked = true
        console.warn("omarchy-protonvpn: cannot write " + root.recentsPath + " (" + exitCode + ")")
      }
    }
  }

  Process {
    id: favoritesWriter
    running: false
    stdinEnabled: true
    onStarted: {
      write(root.favoritesPayload)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      if (exitCode !== 0) {
        root.favoritesLocked = true
        console.warn("omarchy-protonvpn: cannot write " + root.favoritesPath + " (" + exitCode + ")")
      }
    }
  }

  Component.onCompleted: {
    root.loadState()
    root.refresh()
  }
}

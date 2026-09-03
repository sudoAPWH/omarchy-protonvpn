import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "mark.protonvpn"
  ipcTarget: "mark.protonvpn"
  manageIpc: false

  // Two views share one card. Home is the everyday surface — connect, the
  // countries you starred, what you used last, settings. The full country list
  // is 149 rows on a paid plan, so it lives behind "All countries" instead of
  // burying everything else under it.
  property string view: "home"
  readonly property bool browsing: view === "countries"

  // Keyboard navigation addresses rows by a stable string id rather than an
  // index into a rendered tree. Sections appear and disappear as the account
  // signs in, a country expands, or a filter narrows the list; ids let the
  // cursor survive all of that, and let the layout stay plain nested Columns.
  property string cursorId: ""
  property bool cursorActive: false
  property string query: ""
  property string expandedCountry: ""
  property var rowItems: ({})

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color barIconColor: vpn.active ? barForeground : Qt.darker(barForeground, 1.55)

  readonly property var quickTargets: [
    { kind: "fastest",    value: "", label: "Fastest server", glyph: "󰓅", hint: "Lowest latency anywhere" },
    { kind: "random",     value: "", label: "Random server",  glyph: "󰒝", hint: "Anywhere at all" },
    { kind: "p2p",        value: "", label: "P2P",            glyph: "󰒖", hint: "Optimized for file sharing" },
    { kind: "securecore", value: "", label: "Secure Core",    glyph: "󰒘", hint: "Routed through a hardened country" },
    { kind: "tor",        value: "", label: "Tor",            glyph: "󱁑", hint: "Exits onto the Tor network" }
  ]

  readonly property var settingRows: [
    { key: "netshield",       label: "NetShield" },
    { key: "kill-switch",     label: "Kill switch" },
    { key: "port-forwarding", label: "Port forwarding" }
  ]

  readonly property var filteredCountries: {
    var all = vpn.countries
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (Model.matchesQuery(all[i], root.query)) out.push(all[i])
    }
    return out
  }

  readonly property bool showHome: vpn.signedIn && !root.browsing
  readonly property bool showRecents: root.showHome && vpn.recents.length > 0

  // ------------------------------------------------------------ navigation

  function buildNavRows() {
    var ids = []
    if (!vpn.installed) return ids
    if (!vpn.signedIn) return ["signin"]

    if (root.browsing) {
      ids.push("back")
      var list = root.filteredCountries
      for (var c = 0; c < list.length; c++) {
        var code = list[c].code
        ids.push("c:" + code)
        if (root.expandedCountry === code) {
          var cities = vpn.citiesByCountry[code] || []
          for (var s = 0; s < cities.length; s++) ids.push("city:" + code + ":" + cities[s].name)
        }
      }
      return ids
    }

    ids.push("toggle")
    for (var q = 0; q < root.quickTargets.length; q++) ids.push("q:" + q)
    for (var f = 0; f < vpn.favorites.length; f++) ids.push("fav:" + vpn.favorites[f].code)
    for (var r = 0; r < vpn.recents.length; r++) ids.push("r:" + r)
    ids.push("browse")
    for (var t = 0; t < root.settingRows.length; t++) ids.push("s:" + root.settingRows[t].key)
    ids.push("signout")
    return ids
  }

  readonly property var navRows: buildNavRows()

  function registerRow(id, item) {
    if (id) rowItems[id] = item
  }

  function unregisterRow(id, item) {
    if (id && rowItems[id] === item) delete rowItems[id]
  }

  function setCursor(id) {
    if (!id) return
    root.cursorActive = true
    root.cursorId = id
    scrollCursorIntoView()
  }

  function moveCursor(dx, dy) {
    var rows = root.navRows
    if (rows.length === 0) return

    if (dx !== 0) {
      // Horizontal is the country expander: right opens the city list, left
      // closes it (or jumps back to the country from one of its cities).
      var id = root.cursorId
      if (id.indexOf("c:") === 0) {
        var code = id.slice(2)
        if (dx > 0) root.expandCountry(code)
        else if (root.expandedCountry === code) root.expandedCountry = ""
      } else if (id.indexOf("city:") === 0 && dx < 0) {
        var owner = id.split(":")[1]
        root.expandedCountry = ""
        root.setCursor("c:" + owner)
      }
      return
    }

    var index = rows.indexOf(root.cursorId)
    if (index < 0) {
      root.setCursor(rows[dy > 0 ? 0 : rows.length - 1])
      return
    }
    root.setCursor(rows[Math.max(0, Math.min(rows.length - 1, index + dy))])
  }

  function expandCountry(code) {
    root.expandedCountry = code
    vpn.loadCities(code)
  }

  function openBrowser() {
    root.view = "countries"
    root.query = ""
    root.expandedCountry = ""
    vpn.refreshCatalogue(false)
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function closeBrowser() {
    root.view = "home"
    root.query = ""
    root.expandedCountry = ""
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    root.setCursor("browse")
  }

  function activateCursor() {
    var id = root.cursorId
    if (id === "") return
    if (id === "signin") { usernameField.forceActiveFocus(); return }
    if (id === "toggle") { vpn.toggleConnection(); return }
    if (id === "browse") { root.openBrowser(); return }
    if (id === "back") { root.closeBrowser(); return }
    if (id === "signout") { vpn.signOut(); return }

    if (id.indexOf("q:") === 0) {
      root.connectTarget(root.quickTargets[parseInt(id.slice(2), 10)])
      return
    }
    if (id.indexOf("r:") === 0) {
      root.connectTarget(vpn.recents[parseInt(id.slice(2), 10)])
      return
    }
    if (id.indexOf("fav:") === 0) {
      var favCode = id.slice(4)
      root.connectTarget({ kind: "country", value: favCode, label: root.countryName(favCode) })
      return
    }
    if (id.indexOf("city:") === 0) {
      var parts = id.split(":")
      root.connectTarget({ kind: "city", value: parts[2], label: parts[2] })
      return
    }
    if (id.indexOf("c:") === 0) {
      var code = id.slice(2)
      root.connectTarget({ kind: "country", value: code, label: root.countryName(code) })
      return
    }
    if (id.indexOf("s:") === 0) root.cycleSetting(id.slice(2))
  }

  // Star/unstar whatever country the cursor is on, from either view.
  function toggleFavoriteAtCursor() {
    var id = root.cursorId
    var code = ""
    if (id.indexOf("c:") === 0) code = id.slice(2)
    else if (id.indexOf("fav:") === 0) code = id.slice(4)
    else if (id.indexOf("city:") === 0) code = id.split(":")[1]
    if (code === "") return
    vpn.toggleFavorite(code, root.countryName(code))
  }

  function countryName(code) {
    var key = String(code || "").toUpperCase()
    for (var i = 0; i < vpn.countries.length; i++) {
      if (vpn.countries[i].code === key) return vpn.countries[i].name
    }
    // The catalogue may not have loaded yet, but a starred country already
    // carries the name it was starred under.
    for (var f = 0; f < vpn.favorites.length; f++) {
      if (vpn.favorites[f].code === key) return vpn.favorites[f].name
    }
    return key
  }

  function connectTarget(target) {
    if (!target) return
    vpn.connectTo(target)
    root.close()
  }

  function cycleSetting(key) {
    var current = vpn.config[key] || ""
    if (Model.settingIsLocked(current)) return
    if (key === "netshield") {
      vpn.setConfigValue(key, Model.nextNetshield(current))
      return
    }
    if (key === "kill-switch") {
      vpn.setConfigValue(key, Model.settingIsOn(current) ? "off" : "standard")
      return
    }
    vpn.setConfigValue(key, Model.settingIsOn(current) ? "off" : "on")
  }

  function settingValueLabel(key) {
    var value = vpn.config[key]
    if (value === undefined) return "…"
    if (Model.settingIsLocked(value)) return "Upgrade to enable"
    if (key === "netshield") return Model.netshieldLabel(value)
    if (key === "kill-switch") return Model.settingIsOn(value) ? "Standard" : "Off"
    return Model.settingIsOn(value) ? "On" : "Off"
  }

  function deleteAtCursor() {
    var id = root.cursorId
    if (id.indexOf("r:") !== 0) return
    var index = parseInt(id.slice(2), 10)
    var next = []
    for (var i = 0; i < vpn.recents.length; i++) {
      if (i !== index) next.push(vpn.recents[i])
    }
    vpn.setRecents(next)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !item.mapToItem) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    scrollItemIntoView(root.rowItems[root.cursorId])
  }

  // Keep the cursor on something that still exists after a filter, an expand,
  // a view switch, or a sign-in flipping whole sections in and out.
  function ensureCursor() {
    var rows = root.navRows
    if (rows.length === 0) { root.cursorId = ""; return }
    if (rows.indexOf(root.cursorId) < 0) root.cursorId = rows[0]
  }

  onNavRowsChanged: ensureCursor()

  // -------------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) return
    // Always come back to home: the browser is a place you go, not a state
    // the widget should remember.
    root.view = "home"
    root.cursorActive = false
    root.query = ""
    root.expandedCountry = ""
    if (panelFlick) panelFlick.contentY = 0
    vpn.refresh()
    vpn.refreshCatalogue(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: vpn
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); return "ok" }
    function status(): string {
      if (!vpn.installed) return "not installed"
      if (!vpn.signedIn) return "signed out"
      if (!vpn.connected) return "disconnected"
      return "connected " + vpn.serverName + " " + vpn.serverLocation
    }
    function connect(target: string): string {
      if (!vpn.signedIn) return "signed out"
      var value = Model.trim(target)
      if (value === "") vpn.connectTo({ kind: "fastest", value: "", label: "Fastest server" })
      else if (value.indexOf("#") > 0) vpn.connectTo({ kind: "server", value: value, label: value })
      else vpn.connectTo({ kind: "country", value: value, label: root.countryName(value.toUpperCase()) })
      return "ok"
    }
    function disconnect(): string { vpn.disconnect(); return "ok" }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (!vpn.installed) return "Proton VPN CLI not installed"
      if (!vpn.signedIn) return "Proton VPN — not signed in"
      if (vpn.transitioning) return vpn.pendingLabel
      if (vpn.connected) return "Proton VPN — " + vpn.serverName + " · " + vpn.serverLocation
      return "Proton VPN — disconnected"
    }
    iconComponent: Component {
      Item {
        ProtonIcon {
          anchors.centerIn: parent
          iconSize: Style.space(13)
          color: root.barIconColor
          filled: vpn.active
          slashed: !vpn.installed || !vpn.signedIn
          opacity: vpn.transitioning ? 0.55 : 1.0

          SequentialAnimation on opacity {
            running: vpn.transitioning
            loops: Animation.Infinite
            NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.4; duration: 620; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleConnection()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(370))
    // Tall enough that the whole home view fits without scrolling; the country
    // browser always outgrows any cap and scrolls regardless. fittedContentHeight
    // clamps this to the screen, so a short display is still handled.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While either text input owns the keyboard, every key belongs to it —
      // otherwise "j" would move the cursor instead of typing.
      blocked: searchField.activeFocus || usernameField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        // Escape backs out of the browser first, and only then closes.
        if (root.browsing) root.closeBrowser()
        else root.close()
      }
      onDeleteRequested: if (root.cursorActive) root.deleteAtCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") { if (!root.browsing) root.openBrowser(); else searchField.forceActiveFocus() }
        else if (t === "a" || t === "A") root.openBrowser()
        else if (t === "s" || t === "S") root.toggleFavoriteAtCursor()
        else if (t === "r" || t === "R") { vpn.refresh(); vpn.refreshCatalogue(true) }
        else if (t === "d" || t === "D") vpn.disconnect()
        else if (t === "f" || t === "F") root.connectTarget(root.quickTargets[0])
        else if (t === "t" || t === "T") vpn.toggleConnection()
      }

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
          spacing: Style.space(12)

          // ---------------------------------------------------------- hero

          Item {
            id: header
            visible: !root.browsing
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.cursorId === "toggle"
            function focusHero() { root.setCursor("toggle") }

            PanelHero {
              id: hero
              width: parent.width
              title: "Proton VPN"
              meta: {
                if (!vpn.installed) return "CLI not installed"
                if (!vpn.accountKnown) return "Checking…"
                if (!vpn.signedIn) return "Not signed in"
                if (vpn.transitioning) return vpn.pendingLabel
                if (vpn.connected) return vpn.serverName + " · " + vpn.serverLocation
                return "Disconnected"
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: vpn.active ? 1.0 : 0.5
              iconComponent: Component {
                ProtonIcon {
                  iconSize: Style.font.display
                  color: vpn.active ? root.foreground : root.dim
                  filled: vpn.active
                  slashed: !vpn.installed
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: vpn.installed && vpn.signedIn
                  checked: vpn.active
                  busy: vpn.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: vpn.toggleConnection()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: vpn.active ? "Disconnect" : "Connect to the fastest server"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== "" && !root.browsing
            width: parent.width
            text: vpn.lastError !== "" ? vpn.lastError : vpn.actionStatus
            color: vpn.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------- CLI missing

          Text {
            textFormat: Text.PlainText
            visible: vpn.installChecked && !vpn.installed
            width: parent.width
            text: "The protonvpn CLI is not on PATH.\nInstall it with: omarchy pkg add proton-vpn-cli"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------------ sign in

          Column {
            visible: vpn.installed && vpn.accountKnown && !vpn.signedIn
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Signing in needs a password and possibly a 2FA code, so it finishes in a terminal window."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: usernameField
                Layout.fillWidth: true
                placeholderText: "you@proton.me"
                foreground: root.foreground
                hasCursor: root.cursorActive && root.cursorId === "signin"
                onAccepted: vpn.signIn(text)
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              PanelActionButton {
                iconText: "󰌋"
                tooltipText: "Sign in"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: Model.trim(usernameField.text) !== ""
                Layout.alignment: Qt.AlignVCenter
                onClicked: vpn.signIn(usernameField.text)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.awaitingSignin
              width: parent.width
              text: "Waiting for the terminal to finish…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ------------------------------------------------- connection info

          Column {
            visible: root.showHome && vpn.connected
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Server";   value: vpn.serverName }
            InfoPair { label: "Location"; value: vpn.serverLocation }
            InfoPair { label: "Load";     value: Model.loadLabel(vpn.serverLoad); visible: vpn.serverLoad >= 0 }
            InfoPair { label: "Protocol"; value: Model.protocolLabel(vpn.protocol); visible: vpn.protocol !== "" }
          }

          PanelSeparator {
            visible: root.showHome
            foreground: root.foreground
          }

          // --------------------------------------------------- quick connect

          Column {
            visible: root.showHome
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "QUICK CONNECT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.quickTargets
              GlyphRow {
                required property var modelData
                required property int index
                width: column.width
                rowId: "q:" + index
                glyph: modelData.glyph
                title: modelData.label
                subtitle: modelData.hint
                onActivated: root.connectTarget(modelData)
              }
            }
          }

          // ------------------------------------------------------ favorites

          Column {
            visible: root.showHome
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "FAVORITES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.favorites.length === 0
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: "Star a country in All countries to pin it here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: vpn.favorites
              GlyphRow {
                required property var modelData
                width: column.width
                rowId: "fav:" + modelData.code
                glyph: Model.countryFlag(modelData.code)
                title: modelData.name
                trailing: modelData.code
                onActivated: root.connectTarget({
                  kind: "country",
                  value: modelData.code,
                  label: modelData.name
                })
              }
            }
          }

          // --------------------------------------------------------- recents

          Column {
            visible: root.showRecents
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RECENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: vpn.recents
              GlyphRow {
                required property var modelData
                required property int index
                width: column.width
                rowId: "r:" + index
                glyph: modelData.kind === "country" ? Model.countryFlag(modelData.value) : "󰋚"
                title: modelData.label
                subtitle: modelData.kind === "city" ? "City" : (modelData.kind === "country" ? "Country" : modelData.kind)
                onActivated: root.connectTarget(modelData)
              }
            }
          }

          // ---------------------------------------------------- all countries

          GlyphRow {
            visible: root.showHome
            width: column.width
            rowId: "browse"
            glyph: "󰇧"
            title: "All countries"
            subtitle: vpn.countries.length > 0
              ? vpn.countries.length + " available — star the ones you use"
              : "Loading…"
            trailing: "󰅂"
            onActivated: root.openBrowser()
          }

          // -------------------------------------------------------- settings

          PanelSeparator {
            visible: root.showHome
            foreground: root.foreground
          }

          Column {
            visible: root.showHome
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.settingRows

              GlyphRow {
                required property var modelData
                width: column.width
                rowId: "s:" + modelData.key
                glyph: "󰒓"
                title: modelData.label
                trailing: root.settingValueLabel(modelData.key)
                enabled: !Model.settingIsLocked(vpn.config[modelData.key] || "")
                onActivated: root.cycleSetting(modelData.key)
              }
            }
          }

          // ---------------------------------------------------------- footer

          PanelSeparator {
            visible: root.showHome
            foreground: root.foreground
          }

          GlyphRow {
            visible: root.showHome
            width: column.width
            rowId: "signout"
            glyph: "󰍃"
            title: "Sign out"
            subtitle: vpn.accountName
            onActivated: vpn.signOut()
          }

          // ------------------------------------------------- country browser

          Column {
            visible: root.browsing
            width: parent.width
            spacing: Style.space(8)

            GlyphRow {
              width: column.width
              rowId: "back"
              glyph: "󰅁"
              title: "All countries"
              subtitle: root.filteredCountries.length + " of " + vpn.countries.length + " shown"
              onActivated: root.closeBrowser()
            }

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Filter countries"
              foreground: root.foreground
              verticalPadding: Style.spacing.controlPaddingY
              onTextChanged: root.query = text
              onAccepted: {
                if (root.filteredCountries.length === 0) return
                var first = root.filteredCountries[0]
                root.connectTarget({ kind: "country", value: first.code, label: first.name })
              }
              Keys.onEscapePressed: {
                if (text !== "") text = ""
                else root.closeBrowser()
              }
              Keys.onDownPressed: keyCatcher.forceActiveFocus()
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.countries.length === 0
              width: parent.width
              text: "Loading countries…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.countries.length > 0 && root.filteredCountries.length === 0
              width: parent.width
              text: "No country matches “" + root.query + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.browsing ? root.filteredCountries : []

              Column {
                id: countryGroup
                required property var modelData
                width: column.width
                spacing: Style.space(4)

                readonly property string code: modelData.code
                readonly property bool expanded: root.expandedCountry === code
                readonly property var cities: vpn.citiesByCountry[code] || []

                CountryRow {
                  width: countryGroup.width
                  rowId: "c:" + countryGroup.code
                  countryCode: countryGroup.code
                  countryTitle: countryGroup.modelData.name
                  expanded: countryGroup.expanded
                  favorite: vpn.isFavorite(countryGroup.code)
                  onActivated: root.connectTarget({
                    kind: "country",
                    value: countryGroup.code,
                    label: countryGroup.modelData.name
                  })
                  onToggleFavorite: vpn.toggleFavorite(countryGroup.code, countryGroup.modelData.name)
                  onToggleExpand: {
                    if (countryGroup.expanded) root.expandedCountry = ""
                    else root.expandCountry(countryGroup.code)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: countryGroup.expanded && countryGroup.cities.length === 0
                  width: parent.width
                  leftPadding: Style.space(30)
                  text: vpn.citiesPendingFor === countryGroup.code ? "Loading cities…" : "No cities listed."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: countryGroup.expanded ? countryGroup.cities : []

                  GlyphRow {
                    required property var modelData
                    width: countryGroup.width
                    rowId: "city:" + countryGroup.code + ":" + modelData.name
                    glyph: "󰍎"
                    indent: Style.space(18)
                    title: modelData.name
                    subtitle: modelData.features.length > 0 ? modelData.features.join(" · ") : ""
                    onActivated: root.connectTarget({
                      kind: "city",
                      value: modelData.name,
                      label: modelData.name
                    })
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  // One row shape for every list in the panel: a glyph, a title, an optional
  // subtitle underneath, and an optional value on the trailing edge.
  component GlyphRow: CursorSurface {
    id: glyphRow

    property string rowId: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property string trailing: ""
    property real indent: 0
    property bool enabled: true

    signal activated()

    hasCursor: root.cursorActive && root.cursorId === glyphRow.rowId
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    opacity: glyphRow.enabled ? 1.0 : 0.45

    onRowIdChanged: root.registerRow(glyphRow.rowId, glyphRow)
    Component.onCompleted: root.registerRow(glyphRow.rowId, glyphRow)
    Component.onDestruction: root.unregisterRow(glyphRow.rowId, glyphRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: glyphRow.enabled
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(glyphRow.rowId)
      onClicked: glyphRow.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10) + glyphRow.indent
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        visible: glyphRow.glyph !== ""
        text: glyphRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: glyphRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: glyphRow.subtitle !== ""
          Layout.fillWidth: true
          text: glyphRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: glyphRow.trailing !== ""
        text: glyphRow.trailing
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  // Country rows carry three actions — connect, star, and expand into cities —
  // so the two secondary ones get their own hit targets instead of overloading
  // the row.
  component CountryRow: CursorSurface {
    id: countryRow

    property string rowId: ""
    property string countryCode: ""
    property string countryTitle: ""
    property bool expanded: false
    property bool favorite: false

    signal activated()
    signal toggleExpand()
    signal toggleFavorite()

    hasCursor: root.cursorActive && root.cursorId === countryRow.rowId
    current: countryRow.expanded
    foreground: root.foreground
    implicitHeight: countryLabel.implicitHeight + Style.spacing.rowPaddingX

    onRowIdChanged: root.registerRow(countryRow.rowId, countryRow)
    Component.onCompleted: root.registerRow(countryRow.rowId, countryRow)
    Component.onDestruction: root.unregisterRow(countryRow.rowId, countryRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(countryRow.rowId)
      onClicked: countryRow.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.countryFlag(countryRow.countryCode)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        id: countryLabel
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: countryRow.countryTitle
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: countryRow.countryCode
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        iconText: countryRow.favorite ? "󰓎" : "󰓒"
        tooltipText: countryRow.favorite ? "Remove from favorites" : "Add to favorites"
        foreground: countryRow.favorite ? root.foreground : root.dim
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
        onClicked: countryRow.toggleFavorite()
      }

      PanelActionButton {
        iconText: countryRow.expanded ? "󰅀" : "󰅂"
        tooltipText: countryRow.expanded ? "Hide cities" : "Show cities"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
        onClicked: countryRow.toggleExpand()
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}

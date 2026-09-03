.pragma library

// Pure parsing helpers for the `protonvpn` CLI. The CLI prints human-facing
// text (click + tabulate) with no JSON mode, so every reader here is written
// to tolerate the progress chatter the CLI interleaves with real output
// ("Server list is outdated, updating...") and to fail soft rather than throw.

function textLines(text) {
  return String(text || "").replace(/\r/g, "").split("\n")
}

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// `Key: value` scan. Returns the first match so a repeated key from a retry
// does not shadow the authoritative first line.
function keyValue(text, key) {
  var rows = textLines(text)
  var prefix = key.toLowerCase() + ":"
  for (var i = 0; i < rows.length; i++) {
    var line = trim(rows[i])
    if (line.toLowerCase().indexOf(prefix) === 0) return trim(line.slice(prefix.length))
  }
  return ""
}

function isAuthError(text) {
  return /authentication required/i.test(String(text || ""))
}

function isSignedOutAccount(name) {
  var value = trim(name)
  return value === "" || value.toLowerCase() === "none"
}

// ---------------------------------------------------------------- status

// protonvpn status prints either "Status: Disconnected" or four lines:
//   Status: Connected
//   Server: CA#12 in Toronto, Canada
//   Load: 34%
//   Protocol: wireguard
function parseStatus(stdout) {
  var state = keyValue(stdout, "Status")
  var connected = /connected/i.test(state) && !/disconnected/i.test(state)
  var result = {
    connected: connected,
    server: "",
    location: "",
    load: -1,
    protocol: ""
  }
  if (!connected) return result

  var server = keyValue(stdout, "Server")
  // "NAME in LOCATION" — split on the first " in " only; locations such as
  // "Zurich, via Iceland" legitimately contain more words.
  var split = server.indexOf(" in ")
  if (split >= 0) {
    result.server = trim(server.slice(0, split))
    result.location = trim(server.slice(split + 4))
  } else {
    result.server = server
  }

  var load = keyValue(stdout, "Load").replace("%", "")
  var loadNum = parseInt(load, 10)
  result.load = isFinite(loadNum) ? loadNum : -1
  result.protocol = keyValue(stdout, "Protocol")
  return result
}

function parseAccount(stdout) {
  // "Account: 'alex@proton.me'" — strip the quotes the CLI wraps it in.
  var raw = keyValue(stdout, "Account")
  return trim(raw.replace(/^'|'$/g, ""))
}

// ------------------------------------------------------------ simple tables

// tabulate(tablefmt="simple") renders a header row, a rule of dash groups,
// then the rows. The rule gives exact column spans, which is what makes
// values containing single spaces ("United States", "New York") safe to
// slice — splitting on whitespace would tear them apart.
function parseSimpleTable(text) {
  var rows = textLines(text)
  var ruleIndex = -1
  for (var i = 0; i < rows.length; i++) {
    if (/^-+(\s+-+)*\s*$/.test(rows[i]) && rows[i].indexOf("-") >= 0) {
      ruleIndex = i
      break
    }
  }
  if (ruleIndex < 1) return { headers: [], rows: [] }

  var spans = []
  var rule = rows[ruleIndex]
  var match = /-+/g
  var found
  while ((found = match.exec(rule)) !== null) {
    spans.push({ start: found.index, end: found.index + found[0].length })
  }
  if (spans.length === 0) return { headers: [], rows: [] }

  function slice(line, span, isLast) {
    if (line.length <= span.start) return ""
    return trim(isLast ? line.slice(span.start) : line.slice(span.start, span.end))
  }

  var headers = []
  for (var h = 0; h < spans.length; h++) {
    headers.push(slice(rows[ruleIndex - 1], spans[h], h === spans.length - 1))
  }

  var out = []
  for (var r = ruleIndex + 1; r < rows.length; r++) {
    var line = rows[r]
    // A blank line ends the table; footer guidance follows it.
    if (trim(line) === "") break
    var cells = []
    var any = false
    for (var c = 0; c < spans.length; c++) {
      var cell = slice(line, spans[c], c === spans.length - 1)
      if (cell !== "") any = true
      cells.push(cell)
    }
    if (any) out.push(cells)
  }
  return { headers: headers, rows: out }
}

// ------------------------------------------------------------ CLI readers

function parseCountries(stdout) {
  var table = parseSimpleTable(stdout)
  var out = []
  for (var i = 0; i < table.rows.length; i++) {
    var name = table.rows[i][0]
    var code = table.rows[i].length > 1 ? table.rows[i][1] : ""
    if (name === "" || code === "") continue
    out.push({ name: name, code: code.toUpperCase() })
  }
  return out
}

function parseCities(stdout) {
  var table = parseSimpleTable(stdout)
  var out = []
  for (var i = 0; i < table.rows.length; i++) {
    var name = table.rows[i][0]
    if (name === "") continue
    var featureText = table.rows[i].length > 1 ? table.rows[i][1] : ""
    var features = []
    if (featureText !== "") {
      var parts = featureText.split(",")
      for (var p = 0; p < parts.length; p++) {
        var feature = trim(parts[p])
        if (feature !== "") features.push(feature)
      }
    }
    out.push({ name: name, features: features })
  }
  return out
}

function parseConfig(stdout) {
  var table = parseSimpleTable(stdout)
  var out = {}
  for (var i = 0; i < table.rows.length; i++) {
    var key = table.rows[i][0]
    if (key === "") continue
    out[key] = table.rows[i].length > 1 ? table.rows[i][1] : ""
  }
  return out
}

// ------------------------------------------------------------ presentation

var NETSHIELD_CYCLE = ["off", "malware-only", "malware-ads-trackers"]

function netshieldLabel(value) {
  var v = trim(value).toLowerCase()
  if (v.indexOf("malware-ads-trackers") === 0) return "Malware, ads & trackers"
  if (v.indexOf("malware-only") === 0) return "Malware only"
  if (v.indexOf("upgrade") === 0) return "Upgrade to enable"
  if (v === "") return "Unknown"
  return "Off"
}

function nextNetshield(value) {
  var v = trim(value).toLowerCase()
  var index = NETSHIELD_CYCLE.indexOf(v)
  if (index < 0) index = 0
  return NETSHIELD_CYCLE[(index + 1) % NETSHIELD_CYCLE.length]
}

// Toggle-shaped settings report "on"/"off"; kill-switch reports
// "off"/"standard". Custom DNS appends its IP list ("on  [1.1.1.1]").
function settingIsOn(value) {
  var v = trim(value).toLowerCase()
  if (v === "" || v.indexOf("upgrade") === 0) return false
  return v.indexOf("off") !== 0
}

function settingIsLocked(value) {
  return trim(value).toLowerCase().indexOf("upgrade") === 0
}

// Country codes are ISO 3166-1 alpha-2, which maps directly onto the regional
// indicator block — no flag table to maintain.
function countryFlag(code) {
  var c = trim(code).toUpperCase()
  if (!/^[A-Z]{2}$/.test(c)) return ""
  var base = 0x1F1E6
  return String.fromCodePoint(base + c.charCodeAt(0) - 65) +
         String.fromCodePoint(base + c.charCodeAt(1) - 65)
}

function loadLabel(load) {
  var n = Number(load)
  if (!isFinite(n) || n < 0) return ""
  return n + "%"
}

function protocolLabel(protocol) {
  var p = trim(protocol).toLowerCase()
  if (p === "wireguard") return "WireGuard"
  if (p === "openvpn-udp") return "OpenVPN (UDP)"
  if (p === "openvpn-tcp") return "OpenVPN (TCP)"
  return trim(protocol)
}

function matchesQuery(country, query) {
  var q = trim(query).toLowerCase()
  if (q === "") return true
  return String(country.name || "").toLowerCase().indexOf(q) >= 0 ||
         String(country.code || "").toLowerCase().indexOf(q) >= 0
}

// ------------------------------------------------------------ recents

function targetKey(target) {
  if (!target) return ""
  return String(target.kind || "") + ":" + String(target.value || "")
}

function sameTarget(a, b) {
  return targetKey(a) !== "" && targetKey(a) === targetKey(b)
}

function addRecent(list, target, limit) {
  var out = []
  if (target && targetKey(target) !== "") out.push(target)
  var source = Array.isArray(list) ? list : []
  for (var i = 0; i < source.length && out.length < limit; i++) {
    if (!sameTarget(source[i], target)) out.push(source[i])
  }
  return out
}

function normalizeRecents(raw, limit) {
  var parsed = []
  try {
    parsed = JSON.parse(String(raw || "[]"))
  } catch (e) {
    parsed = []
  }
  if (!Array.isArray(parsed)) return []
  var out = []
  for (var i = 0; i < parsed.length && out.length < limit; i++) {
    var entry = parsed[i]
    if (!entry || typeof entry !== "object") continue
    var kind = trim(entry.kind)
    var label = trim(entry.label)
    if (kind === "" || label === "") continue
    out.push({ kind: kind, value: trim(entry.value), label: label })
  }
  return out
}

function normalizeFavorites(raw) {
  var parsed = []
  try {
    parsed = JSON.parse(String(raw || "[]"))
  } catch (e) {
    parsed = []
  }
  if (!Array.isArray(parsed)) return []
  var out = []
  var seen = {}
  for (var i = 0; i < parsed.length; i++) {
    var entry = parsed[i]
    if (!entry || typeof entry !== "object") continue
    var code = trim(entry.code).toUpperCase()
    if (!/^[A-Z]{2}$/.test(code) || seen[code]) continue
    seen[code] = true
    out.push({ code: code, name: trim(entry.name) || code })
  }
  return out
}

// The argv for one connection target. Kept here so the panel, the recents
// list, and IPC all build the exact same command.
function connectArgs(target) {
  var kind = target ? String(target.kind || "") : ""
  var value = target ? String(target.value || "") : ""
  if (kind === "country") return ["connect", "--country", value]
  if (kind === "city") return ["connect", "--city", value]
  if (kind === "server") return ["connect", value]
  if (kind === "p2p") return ["connect", "--p2p"]
  if (kind === "securecore") return ["connect", "--securecore"]
  if (kind === "tor") return ["connect", "--tor"]
  if (kind === "random") return ["connect", "--random"]
  return ["connect"]
}

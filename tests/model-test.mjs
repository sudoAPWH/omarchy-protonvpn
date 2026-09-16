// Parser tests for Model.js. The protonvpn CLI has no JSON mode, so every
// reader in Model.js is pulling structure out of human-facing text — which is
// exactly the kind of code that breaks quietly when the CLI reformats a table.
//
// Run with: node tests/model-test.mjs
//
// Model.js is a QML .pragma library, so it is loaded here as source with the
// pragma stripped, rather than copied — the tests always run against the file
// the shell actually loads.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\.pragma\s+library\s*$/m, "")
const Model = await import("data:text/javascript;base64," + Buffer.from(
  source + "\nexport {" + [
    "textLines", "trim", "keyValue", "isAuthError", "isSignedOutAccount",
    "parseStatus", "parseAccount", "parseSimpleTable", "parseCountries",
    "parseCities", "parseConfig", "netshieldLabel", "nextNetshield",
    "settingIsOn", "settingIsLocked", "countryFlag", "loadLabel",
    "protocolLabel", "matchesQuery", "addRecent", "normalizeRecents",
    "normalizeFavorites", "connectArgs", "cliCommand", "cliShell",
    "stateProblem", "CLI_ENVIRONMENT", "MAX_FAVORITES"
  ].join(", ") + "}"
).toString("base64"))

let failures = 0
const eq = (actual, expected, msg) => {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) {
    console.log("PASS " + msg)
  } else {
    failures++
    console.log(`FAIL ${msg}\n  got:  ${a}\n  want: ${b}`)
  }
}

// ------------------------------------------------------------------ status

eq(Model.parseStatus("Status: Disconnected\n"),
   { connected: false, server: "", location: "", load: -1, protocol: "" },
   "status disconnected")

// The CLI interleaves progress chatter with real output.
eq(Model.parseStatus(`Server list is outdated, updating... This may take a moment.
Status: Connected
Server: CA#12 in Toronto, Canada
Load: 34%
Protocol: wireguard`),
   { connected: true, server: "CA#12", location: "Toronto, Canada", load: 34, protocol: "wireguard" },
   "status connected, ignoring progress chatter")

// Secure Core locations read "City, via EntryCountry" — splitting on every
// " in " would truncate them.
eq(Model.parseStatus(`Status: Connected
Server: CH#5 in Zurich, via Iceland
Load: 7%
Protocol: openvpn-udp`).location,
   "Zurich, via Iceland",
   "secure core location keeps its 'via' clause")

eq(Model.isSignedOutAccount(Model.parseAccount("Account: 'None'")), true, "signed out account")
eq(Model.isSignedOutAccount(Model.parseAccount("Account: 'alex@proton.me'")), false, "signed in account")
eq(Model.parseAccount("Account: 'alex@proton.me'"), "alex@proton.me", "account name unquoted")

// ------------------------------------------------------------------ tables

eq(Model.parseCountries(`Country                   Code
------------------------  ------
Australia                 AU
United States             US
Hong Kong SAR China       HK`),
   [{ name: "Australia", code: "AU" },
    { name: "United States", code: "US" },
    { name: "Hong Kong SAR China", code: "HK" }],
   "countries keep spaces inside names")

eq(Model.parseCities(`
Cities in United States:
City             Features
---------------  --------------------
New York         P2P, Tor
Los Angeles
Chicago          Secure Core
`),
   [{ name: "New York", features: ["P2P", "Tor"] },
    { name: "Los Angeles", features: [] },
    { name: "Chicago", features: ["Secure Core"] }],
   "cities tolerate an empty features cell")

const config = Model.parseConfig(`
Current configuration
Setting                  Value
-----------------------  ---------------------
vpn-accelerator          on
moderate-nat             off
ipv6                     on
anonymous-crash-reports  off
port-forwarding          Upgrade to enable
custom-dns               on  [1.1.1.1, 9.9.9.9]
netshield                malware-ads-trackers
kill-switch              standard

Use 'protonvpn config set <setting> <value>' to change settings.`)

eq(config["netshield"], "malware-ads-trackers", "config reads netshield")
eq(config["kill-switch"], "standard", "config reads kill-switch")
eq(config["custom-dns"], "on  [1.1.1.1, 9.9.9.9]", "config keeps the custom-dns ip list")
eq(Object.keys(config).length, 8, "config stops at the blank line, not the footer")

eq(Model.settingIsOn(config["kill-switch"]), true, "kill-switch 'standard' counts as on")
eq(Model.settingIsOn(config["custom-dns"]), true, "custom-dns with ips counts as on")
eq(Model.settingIsOn(config["port-forwarding"]), false, "an upgrade-locked setting is not on")
eq(Model.settingIsLocked(config["port-forwarding"]), true, "upgrade-locked setting detected")
eq(Model.netshieldLabel(config["netshield"]), "Malware, ads & trackers", "netshield label")
eq(Model.nextNetshield("off"), "malware-only", "netshield cycles forward")
eq(Model.nextNetshield("malware-ads-trackers"), "off", "netshield cycle wraps")

eq(Model.parseSimpleTable("no table here"), { headers: [], rows: [] }, "missing table is not an error")
eq(Model.parseCountries("Error: Authentication required to view complete country list."), [],
   "an error page yields no rows")
eq(Model.isAuthError("Error: Authentication required to view complete country list."), true,
   "auth error detected")

// ------------------------------------------------------------ presentation

eq(Model.countryFlag("CA"), "🇨🇦", "flag from country code")
eq(Model.countryFlag("ca"), "🇨🇦", "flag from lowercase code")
eq(Model.countryFlag("bad"), "", "flag rejects anything but alpha-2")
eq(Model.loadLabel(34), "34%", "load label")
eq(Model.loadLabel(-1), "", "unknown load renders empty")
eq(Model.protocolLabel("wireguard"), "WireGuard", "protocol label")
eq(Model.matchesQuery({ name: "United States", code: "US" }, "unit"), true, "filter matches name")
eq(Model.matchesQuery({ name: "United States", code: "US" }, "us"), true, "filter matches code")
eq(Model.matchesQuery({ name: "Canada", code: "CA" }, "zz"), false, "filter rejects non-matches")

// ---------------------------------------------------------------- commands

eq(Model.connectArgs({ kind: "country", value: "US" }), ["connect", "--country", "US"], "connect country")
eq(Model.connectArgs({ kind: "city", value: "New York" }), ["connect", "--city", "New York"], "connect city")
eq(Model.connectArgs({ kind: "server", value: "IT#23" }), ["connect", "IT#23"], "connect named server")
eq(Model.connectArgs({ kind: "securecore" }), ["connect", "--securecore"], "connect secure core")
eq(Model.connectArgs({ kind: "fastest" }), ["connect"], "connect fastest")
eq(Model.connectArgs(null), ["connect"], "no target falls back to fastest")

// -------------------------------------------------------------- cli command

eq(Model.cliCommand("/usr/bin/protonvpn", ["status"]), ["/usr/bin/protonvpn", "status"],
   "cli runs the resolved path, with no env(1) wrapper and nothing from $PATH")
eq(Model.cliCommand("/usr/bin/protonvpn"), ["/usr/bin/protonvpn"], "cli with no args")
eq(Model.CLI_ENVIRONMENT, { PROTON_LOADER_OVERRIDES: "keyring=json" },
   "the JSON keyring backend is forced through the process environment")
eq(Model.cliShell("/usr/bin/protonvpn", "signin 'me'"),
   "PROTON_LOADER_OVERRIDES=keyring=json '/usr/bin/protonvpn' signin 'me'",
   "sign-in terminal forces the JSON keyring backend too")
eq(Model.cliShell("/home/me/.local/bin/proton'vpn", "signin 'me'"),
   "PROTON_LOADER_OVERRIDES=keyring=json '/home/me/.local/bin/proton'\\''vpn' signin 'me'",
   "a quote in the resolved path cannot break out of the shell string")

// ------------------------------------------------------------ state files
// An unreadable state file must never read as "empty": the next star or
// connection would write over whatever was actually in it.
eq(Model.stateProblem('[{"code":"CA"}]'), "", "a good state file has no problem")
eq(Model.stateProblem(""), "", "an empty state file is an empty list")
eq(Model.stateProblem("   "), "", "whitespace only is an empty list")
eq(Model.stateProblem("not json at all"), "corrupt", "a corrupt state file is flagged, not emptied")
eq(Model.stateProblem('{"code":"CA"}'), "foreign", "a non-array state file is flagged")
eq(Model.stateProblem("x".repeat(1048577)), "oversize", "an oversized state file is refused before parsing")

const manyFavorites = JSON.stringify(
  Array.from({ length: Model.MAX_FAVORITES + 40 }, (_, i) =>
    ({ code: String.fromCharCode(65 + (i % 26)) + String.fromCharCode(65 + Math.floor(i / 26)), name: "x" })))
eq(Model.normalizeFavorites(manyFavorites).length <= Model.MAX_FAVORITES, true,
   "favorites are capped rather than rendered without limit")

// ----------------------------------------------------------------- recents

let recents = []
recents = Model.addRecent(recents, { kind: "country", value: "US", label: "United States" }, 5)
recents = Model.addRecent(recents, { kind: "city", value: "Toronto", label: "Toronto" }, 5)
recents = Model.addRecent(recents, { kind: "country", value: "US", label: "United States" }, 5)
eq(recents.map(r => r.value), ["US", "Toronto"], "recents dedupe and move to front")

let capped = []
for (const code of ["A", "B", "C", "D"]) {
  capped = Model.addRecent(capped, { kind: "country", value: code, label: code }, 2)
}
eq(capped.map(r => r.value), ["D", "C"], "recents honour the limit")

eq(Model.normalizeRecents(JSON.stringify(recents), 5).length, 2, "recents survive a round trip")
eq(Model.normalizeRecents("not json at all", 5), [], "a corrupt recents file reads as empty")
eq(Model.normalizeRecents('[{"kind":"country"}]', 5), [], "entries without a label are dropped")
eq(Model.normalizeRecents('{"kind":"country"}', 5), [], "a non-array recents file reads as empty")

// --------------------------------------------------------------- favorites

eq(Model.normalizeFavorites('[{"code":"ca","name":"Canada"},{"code":"US","name":"United States"}]'),
   [{ code: "CA", name: "Canada" }, { code: "US", name: "United States" }],
   "favorites upcase their country codes")
eq(Model.normalizeFavorites('[{"code":"CA","name":"Canada"},{"code":"CA","name":"Canada"}]'),
   [{ code: "CA", name: "Canada" }],
   "duplicate favorites collapse")
eq(Model.normalizeFavorites('[{"code":"CANADA","name":"Canada"},{"code":"","name":"x"}]'), [],
   "favorites reject anything but an alpha-2 code")
eq(Model.normalizeFavorites('[{"code":"CA"}]'), [{ code: "CA", name: "CA" }],
   "a favorite without a name falls back to its code")
eq(Model.normalizeFavorites("garbage"), [], "a corrupt favorites file reads as empty")
eq(Model.normalizeFavorites('{"code":"CA"}'), [], "a non-array favorites file reads as empty")

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} test(s) failed.`)
process.exit(failures === 0 ? 0 : 1)

# Proton VPN — Omarchy bar widget

A Proton VPN widget for the Omarchy bar (Quickshell). Connect, disconnect,
pick a country or city, keep favorites, and change NetShield or the kill
switch — without leaving the bar.

It drives the official `protonvpn` CLI (`proton-vpn-cli`); it does not talk to
Proton's API itself.

## What it does

**Bar icon** — a shield: filled when the tunnel is up, outline when it's down,
slashed when the CLI is missing or you're signed out, pulsing while a connect
or disconnect is in flight. Hover for the current server.

| Click | Action |
|---|---|
| left | open the panel |
| right | connect to the fastest server / disconnect |
| middle | refresh status |

**Panel — home**

- Current server, location, load, and protocol while connected
- A switch that connects to the fastest server, or disconnects
- Quick connect: fastest, random, P2P, Secure Core, Tor
- **Favorites** — the countries you starred, one click to connect
- Recent connections, most recent first
- **All countries** → the browser (below)
- NetShield, kill switch, and port forwarding, each toggled in place
- Sign out

**Panel — all countries**

The full list (149 countries on a paid plan) lives behind its own view so the
home panel stays short. Filter as you type, star a country to pin it to home,
or expand one to connect to a specific city.

## Keyboard

The panel takes keyboard focus when it opens.

| Key | Action |
|---|---|
| `j` / `k` or `↓` / `↑` | move the cursor |
| `enter` / `space` | activate the row |
| `l` / `→` | expand a country into its cities |
| `h` / `←` | collapse it again |
| `a` or `/` | open the country browser (`/` again focuses the filter) |
| `s` | star / unstar the country under the cursor |
| `t` | connect to the fastest server, or disconnect |
| `f` | connect to the fastest server |
| `d` | disconnect |
| `r` | refresh status, countries, and settings |
| `x` | forget the recent connection under the cursor |
| `esc` | leave the country browser, then close the panel |

## Signing in

`protonvpn signin` reads your password (and any 2FA code) with `getpass()`, so
it needs a real terminal — there is no headless path. Type your username in the
panel and press enter: the widget opens an Omarchy terminal running the sign-in,
then notices when it lands and refreshes itself. Nothing is stored by this
widget; credentials live wherever the Proton CLI keeps them.

## Install

Requires `quickshell` (Omarchy's shell), `proton-vpn-cli`, and — optionally —
`nmcli` for instant status updates.

```bash
git clone <this repo> ~/Projects/omarchy-protonvpn
ln -sfn ~/Projects/omarchy-protonvpn ~/.config/omarchy/plugins/mark.protonvpn
omarchy-shell shell rescanPlugins
omarchy plugin enable mark.protonvpn
```

Move it in the bar with `omarchy bar move mark.protonvpn --section right`.

## Settings

Set on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | 30 | status poll interval, in seconds |
| `recentLimit` | 5 | how many recent connections to keep (0 disables) |

```json
{ "id": "mark.protonvpn", "refreshIntervalSec": 60, "recentLimit": 8 }
```

## IPC

```bash
omarchy-shell mark.protonvpn toggle              # show/hide the panel
omarchy-shell mark.protonvpn status              # connected CA#954 Vancouver, Canada
omarchy-shell mark.protonvpn connect             # fastest server
omarchy-shell mark.protonvpn connect US          # fastest in a country
omarchy-shell mark.protonvpn connect 'IT#23'     # a named server
omarchy-shell mark.protonvpn disconnect
omarchy-shell mark.protonvpn refresh
```

## How it stays current

`protonvpn status` is a Python process that costs most of a second, so it is not
polled tightly. Instead the widget watches `nmcli monitor` — NetworkManager is
what the CLI drives — and reads status when the tunnel actually changes, which
also catches connects and drops made from a terminal or by the network itself.
The timer is only a backstop. Countries and settings are fetched when the panel
opens, not on the status cadence.

## State

Favorites and recents are plain JSON under
`~/.local/state/omarchy-protonvpn/` (`favorites.json`, `recents.json`), safe to
edit or delete. A corrupt file reads as empty rather than breaking the widget.

## Development

```bash
node tests/model-test.mjs     # parser tests — no Qt needed
omarchy restart shell         # load your changes
```

`Model.js` holds every reader for the CLI's output. The CLI has no JSON mode, so
those parsers work from human-facing text (click messages and `tabulate` tables)
and are the part most likely to break when Proton reformats something — hence
the tests, which run against `Model.js` directly rather than a copy.

Note that Omarchy's plugin hot-reload watches `~/.config/omarchy/plugins`
with `inotifywait -r`, which does not follow the symlink into `~/Projects`.
Edits here need `omarchy restart shell`; `rescanPlugins` alone will not pick
them up.

## Layout

| File | What it is |
|---|---|
| `manifest.json` | plugin declaration and settings schema |
| `Panel.qml` | bar button, panel, both views, keyboard navigation |
| `Service.qml` | every conversation with the `protonvpn` CLI, plus state |
| `Model.js` | pure parsers and formatters — no QML, fully testable |
| `ProtonIcon.qml` | the shield, drawn natively so it stays crisp in the bar |
| `tests/model-test.mjs` | parser tests |

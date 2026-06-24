# Claudometer

Claude AI usage limits at a glance, as a native KDE Plasma 6 widget.

Two slim meters on your panel show your **5-hour session** and **7-day weekly**
limits. Hover for a tooltip with percentages and reset countdowns; click for the
full breakdown (including per-model buckets and pay-per-use credits, if your
account has them). Desktop notifications fire when you cross 70% / 90%
(configurable).

## Design

The entire app is **one self-contained plasmoid package**. No daemon, no
systemd service, no IPC files, no pip dependencies.

```
widget Timer → runs bundled claudometer.py → JSON on stdout → widget renders
```

- The widget polls only while it exists. Remove the widget, polling stops.
- "Refresh" just runs the helper again — no trigger files.
- The popup refreshes automatically when opened (throttled).
- Rate-limited (HTTP 429)? The widget reads the server's `Retry-After` header
  and waits exactly that long (plus a small margin) before trying again — so it
  can never re-trip the limit by retrying too early. The refresh button is
  disabled, and the popup shows the countdown, until the cooldown clears.
- Default poll interval is 5 minutes: the usage endpoint is rate-limited and a
  5-hour / 7-day meter doesn't need finer resolution.
- Colors follow your Plasma theme by default; custom colors are available in
  settings with native color pickers.

## How it gets your usage

Anthropic's `https://api.anthropic.com/api/oauth/usage` endpoint reports
utilization percentages per limit bucket. It needs an OAuth token, which the
helper borrows from whichever Claude app you already use (it never refreshes
or rotates tokens — it only reads):

1. **Claude Code**: `~/.claude/.credentials.json` (plaintext, mode 600).
2. **Claude Desktop**: `~/.config/Claude/config.json` holds the token
   encrypted with Chromium's OSCrypt v11 scheme. The helper fetches the
   "Chromium Safe Storage" password from KWallet over D-Bus, derives the AES
   key with PBKDF2 (Python stdlib), and decrypts via the `openssl` CLI.

Whichever token is freshest wins.

> **Note** (the price of zero pip dependencies): `openssl enc -K` briefly
> exposes the derived AES key in the process list while decrypting. On a
> single-user desktop this is moot — any local process could derive the same
> key from KWallet — but you should know it's there.

> **Caveat**: the usage endpoint and its `anthropic-beta: oauth-2025-04-20`
> header are undocumented and could change without notice. If the widget
> suddenly shows an HTTP error, that's the first suspect.

## Requirements

KDE Plasma 6, Python 3.10+, `openssl`, `qdbus6`, `notify-send` — all standard
on a Plasma distro. Plus a signed-in Claude Desktop or Claude Code.

## Install

```sh
./install.sh
```

Then right-click your panel → *Add Widgets* → **Claudometer**.

To remove:

```sh
kpackagetool6 -t Plasma/Applet -r com.github.trixles.claudometer
```

## Migrating from Claude Usage Tracker (the old widget)

The old version ran a systemd daemon that polls the same rate-limited
endpoint — don't run both. To retire it completely:

```sh
systemctl --user disable --now claude-usage-tracker.service
rm ~/.config/systemd/user/claude-usage-tracker.service
kpackagetool6 -t Plasma/Applet -r com.github.trixles.claudeusagetracker
rm -r ~/.local/share/cut
rm ~/.config/environment.d/cut.conf
```

## Development

```sh
python3 -m unittest discover tests          # unit tests (stdlib only)
python3 plasmoid/contents/scripts/claudometer.py --debug | jq   # live helper run
./install.sh                                # install/upgrade the widget
```

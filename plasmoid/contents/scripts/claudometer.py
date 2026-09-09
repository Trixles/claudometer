#!/usr/bin/env python3
"""Claudometer helper — fetch Claude usage limits and print them as JSON.

It runs, prints exactly one JSON envelope to stdout, and exits. The plasmoid
invokes it on a timer; the JSON on stdout IS the interface.

Envelope on success:
    {"ok": true, "fetched_at": "...", "buckets": [...], "extra_usage": {...}}
Envelope on failure:
    {"ok": false, "error_type": "...", "error": "human-readable message"}

It keeps one tiny cache file (XDG cache dir) holding the last success and any
active cooldown — either a server-mandated 429 wait or a self-imposed pause
after the API rejects our token. This is the helper's *only* state, and it
earns its keep: it lets cooldowns survive plasmashell restarts and be SHARED
across multiple widget instances, so we never re-poll the API during one.
Retrying a rejected token looks like credential abuse to the server and gets
the account throttled hard, so the expired cooldown matters as much as the
429 one.

Dependencies: Python stdlib only. AES decryption of the Claude Desktop token
is delegated to the `openssl` CLI (universally present) instead of the pip
`cryptography` package, so there is nothing to install.
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
BETA_HEADER = "oauth-2025-04-20"  # undocumented beta header the endpoint requires
HTTP_TIMEOUT = 10  # seconds

CODE_CREDENTIALS = Path.home() / ".claude" / ".credentials.json"
DESKTOP_CONFIG = Path.home() / ".config" / "Claude" / "config.json"

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "claudometer"
CACHE_FILE = CACHE_DIR / "state.json"
SUCCESS_TTL = 30  # seconds; reuse a fresh result so N instances make 1 request
EXPIRED_COOLDOWN = 600  # seconds; after a 401, don't resend the same dead
                        # token — repeated failed auth is what provokes the
                        # hour-long 429 penalties

# Friendly names for the usage buckets Anthropic returns. Unknown bucket ids
# fall back to a prettified version of the id, so new buckets appear
# automatically instead of being silently dropped.
BUCKET_LABELS = {
    "five_hour": "Session",
    "seven_day": "Week",
    "seven_day_sonnet": "Week (Sonnet)",
    "seven_day_opus": "Week (Opus)",
    "seven_day_oauth_apps": "Week (apps)",
    "seven_day_cowork": "Week (Cowork)",
}

DEBUG = "--debug" in sys.argv


def debug(msg):
    """Diagnostics go to stderr so stdout stays a clean JSON document."""
    if DEBUG:
        print(f"[claudometer] {msg}", file=sys.stderr)


# --------------------------------------------------------------------------
# Token acquisition
#
# Two possible sources, and we take whichever token is freshest:
#   1. Claude Code:    ~/.claude/.credentials.json (plaintext, mode 600)
#   2. Claude Desktop: ~/.config/Claude/config.json (encrypted by Electron
#      using Chromium's "OSCrypt v11" scheme, key guarded by KWallet)
# --------------------------------------------------------------------------

def read_code_credentials(path=CODE_CREDENTIALS):
    """Return a token candidate from Claude Code's plaintext credentials.

    Candidates are (source, access_token, expires_at_ms) tuples.
    Returns None if the file is missing or malformed.
    """
    try:
        data = json.loads(path.read_text())
        oauth = data["claudeAiOauth"]
        return ("claude-code", oauth["accessToken"], int(oauth.get("expiresAt", 0)))
    except (OSError, KeyError, ValueError, TypeError):
        return None


def read_kwallet_password():
    """Fetch the Chromium Safe Storage password from KWallet via D-Bus.

    Electron apps (Claude Desktop is one) store their encryption password
    in KWallet under folder "Chromium Keys", entry "Chromium Safe Storage".
    The qdbus6 sequence mirrors what Chromium itself does:
      networkWallet() -> wallet name, open() -> handle, readPassword() -> secret
    """
    qdbus = "/usr/bin/qdbus6"
    service, obj, iface = "org.kde.kwalletd6", "/modules/kwalletd6", "org.kde.KWallet"

    def call(method, *args):
        r = subprocess.run(
            [qdbus, service, obj, f"{iface}.{method}", *args],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            raise RuntimeError(f"kwallet {method}: {r.stderr.strip()}")
        return r.stdout.strip()

    wallet = call("networkWallet")
    handle = call("open", wallet, "0", "claudometer")
    if not handle or int(handle) < 0:
        raise RuntimeError("KWallet refused to open")
    return call("readPassword", handle, "Chromium Keys",
                "Chromium Safe Storage", "claudometer")


def decrypt_token_cache(encrypted_b64, password):
    """Decrypt Claude Desktop's oauth:tokenCache blob (Chromium OSCrypt v11).

    The scheme (fixed by Chromium, not by us):
      key = PBKDF2-HMAC-SHA1(password, salt="saltysalt", iterations=1, 16 bytes)
      AES-128-CBC, IV = 16 spaces, PKCS#7 padding, ciphertext prefixed "v11"
    PBKDF2 comes from hashlib; the AES step is delegated to the openssl CLI
    (which also strips the PKCS#7 padding for us).
    """
    raw = base64.b64decode(encrypted_b64)
    if raw[:3] != b"v11":
        raise ValueError(f"unsupported encryption prefix {raw[:3]!r}")

    key = hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1, dklen=16)
    # NOTE: -K places the key in openssl's argv, briefly visible in /proc.
    # Acceptable on a single-user desktop: the key is re-derivable from the
    # KWallet password by any local process anyway. Documented in README.
    r = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc",
         "-K", key.hex(), "-iv", b" ".hex() * 16],
        input=raw[3:], capture_output=True, timeout=10,
    )
    if r.returncode != 0:
        raise ValueError(f"openssl: {r.stderr.decode(errors='replace').strip()}")
    return json.loads(r.stdout.decode())


# Claude Desktop stores its encrypted OAuth tokens under one of these keys,
# in preference order. Newer builds use "oauth:tokenCacheV2"; the migration
# leaves the old "oauth:tokenCache" behind still populated with ZOMBIE
# tokens — revoked server-side, yet carrying expiresAt dates up to a year
# out. So the caches must never be pooled and compared by expiry (the
# zombies always win); take the first cache that yields a token and only
# fall back to V1 when V2 is absent.
DESKTOP_CACHE_KEYS = ("oauth:tokenCacheV2", "oauth:tokenCache")


def read_desktop_credentials(path=DESKTOP_CONFIG):
    """Return the best token candidate from Claude Desktop, or None."""
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError) as e:  # missing/corrupt config: no Desktop token
        debug(f"desktop config unavailable: {e}")
        return None

    # Fetch the KWallet password lazily — only once, and only if there's
    # actually something to decrypt.
    password = None
    for key in DESKTOP_CACHE_KEYS:
        blob = config.get(key)
        if not blob:
            continue
        try:
            if password is None:
                password = read_kwallet_password()
            cache = decrypt_token_cache(blob, password)
        except Exception as e:  # a bad key shouldn't sink the fallback key
            debug(f"desktop key {key!r} unreadable: {e}")
            continue

        # Within ONE cache, expiry comparison is meaningful: keep the entry
        # that expires last. (A cache maps entry names to token dicts.)
        best = None
        for val in cache.values():
            if not isinstance(val, dict):
                continue
            token = val.get("token") or val.get("accessToken")
            if not token:
                continue
            expires = int(val.get("expiresAt", 0))
            if best is None or expires > best[2]:
                best = ("claude-desktop", token, expires)
        if best:
            debug(f"desktop token taken from {key!r}")
            return best
    return None


def pick_token(candidates, now_ms):
    """Choose the best token: freshest non-expired wins; else freshest overall.

    An expired token is still worth sending — the API's 401 yields a clearer
    error message for the user than failing locally would.
    """
    candidates = [c for c in candidates if c]
    if not candidates:
        return None
    live = [c for c in candidates if c[2] > now_ms]
    return max(live or candidates, key=lambda c: c[2])


def fingerprint(token):
    """Short non-reversible id for a token, safe to store in the cache file.

    Used to remember WHICH token got a 401, so the expired cooldown lifts
    early the moment a different (i.e. refreshed) token appears on disk.
    """
    return hashlib.sha256(token.encode()).hexdigest()[:16]


# --------------------------------------------------------------------------
# Fetch + parse
# --------------------------------------------------------------------------

def parse_retry_after(value):
    """Parse a Retry-After header into integer seconds, or None.

    Anthropic sends an integer second-count; per the HTTP spec it may also be
    an absolute date, which we convert to a remaining-seconds delta.
    """
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return int(value)
    try:
        from email.utils import parsedate_to_datetime
        return max(0, int(parsedate_to_datetime(value).timestamp() - time.time()))
    except (TypeError, ValueError):
        return None


def fetch_usage(token):
    """GET the usage endpoint. Returns (data, None) or (None, err_dict).

    err_dict always has error_type + error; rate-limit errors also carry
    retry_after (seconds) straight from the server, so the widget can wait
    exactly as long as the server demands instead of guessing.
    """
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": BETA_HEADER,
        "Content-Type": "application/json",
        "User-Agent": "Claudometer/1.0 (KDE Plasma widget; Linux)",
    })
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as e:
        if e.code == 429:
            err = {"error_type": "rate_limited",
                   "error": "Rate limited by Anthropic."}
            retry = parse_retry_after(e.headers.get("Retry-After"))
            if retry is not None:
                err["retry_after"] = retry
            return None, err
        if e.code in (401, 403):
            # "claude CLI in a terminal" is deliberate: Claude Code embedded
            # inside Desktop rides Desktop's session and never refreshes the
            # CLI's own credentials file.
            return None, {"error_type": "expired",
                          "error": "Token rejected — open Claude Desktop or "
                                   "run claude in a terminal to sign in again."}
        return None, {"error_type": "http", "error": f"API returned HTTP {e.code}."}
    except Exception as e:
        return None, {"error_type": "network", "error": f"Network error: {e}"}


def parse_usage(raw):
    """Convert the raw API response into our bucket list.

    Ground truth (observed response): top-level keys are bucket ids mapping
    to {"utilization": float 0-100, "resets_at": ISO8601-or-null} — or to
    null entirely when the bucket doesn't apply to this account. There is
    also "extra_usage" (pay-per-use credits), which we pass through.
    """
    buckets = []
    for bucket_id, val in raw.items():
        # extra_usage also carries a "utilization" key, so exclude it by name
        if bucket_id == "extra_usage":
            continue
        if not isinstance(val, dict) or "utilization" not in val:
            continue  # null bucket or future non-bucket field
        label = BUCKET_LABELS.get(bucket_id,
                                  bucket_id.replace("_", " ").title())
        try:
            pct = float(val.get("utilization") or 0.0)
        except (TypeError, ValueError):
            continue
        buckets.append({
            "id": bucket_id,
            "label": label,
            "pct": pct,
            "resets_at": val.get("resets_at"),
        })

    extra = raw.get("extra_usage") or {}
    return {
        "buckets": buckets,
        "extra_usage": {
            "enabled": bool(extra.get("is_enabled")),
            "used_credits": extra.get("used_credits"),
            "monthly_limit": extra.get("monthly_limit"),
        },
    }


# --------------------------------------------------------------------------
# Cache (the helper's only state)
# --------------------------------------------------------------------------

def load_state():
    """Read the cache file, or {} if absent/corrupt. Never raises."""
    try:
        return json.loads(CACHE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state):
    """Atomically write the cache file. Best-effort: failures are ignored."""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = CACHE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(CACHE_FILE)
    except OSError as e:
        debug(f"cache write failed: {e}")


def cached_response(state, now):
    """Decide whether to answer from cache instead of calling the API.

    Returns an envelope to emit, or None to proceed with a live fetch:
      - An unexpired cooldown short-circuits the network entirely. This is
        what makes a cooldown survive restarts and be shared across widget
        instances, so we never re-poll during a penalty. The stored
        cooldown_error (set for 401s) is replayed so the widget shows the
        real problem, not a generic rate-limit message.
      - A success newer than SUCCESS_TTL is reused, so several instances
        polling on the same tick make one request between them.
    """
    cooldown_until = state.get("cooldown_until", 0)
    if cooldown_until and now < cooldown_until:
        err = state.get("cooldown_error") or {
            "error_type": "rate_limited",
            "error": "Rate limited by Anthropic."}
        return {"ok": False, **err, "retry_after": int(cooldown_until - now)}

    last = state.get("last_success")
    if last and 0 <= now - last.get("at", 0) < SUCCESS_TTL:
        return last.get("envelope")
    return None


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def emit(payload):
    print(json.dumps(payload))
    sys.exit(0)  # exit 0 even on error envelopes: the JSON is the protocol


def main():
    now = time.time()
    state = load_state()

    # Answer from cache when we should (active cooldown, or a fresh success).
    early = cached_response(state, now)
    picked = None
    if early is not None and early.get("error_type") == "expired":
        # The expired cooldown only guards against resending a token we KNOW
        # is dead. If the user signed in again since, a DIFFERENT token is on
        # disk — lift the cooldown and try it right away.
        picked = pick_token(
            [read_code_credentials(), read_desktop_credentials()],
            int(now * 1000))
        if picked and fingerprint(picked[1]) != state.get("rejected_token"):
            debug("new token since the 401 — retrying early")
            early = None
    if early is not None:
        debug(f"served from cache: {early.get('error_type', 'ok')}")
        emit(early)

    if picked is None:
        picked = pick_token(
            [read_code_credentials(), read_desktop_credentials()],
            int(now * 1000))
    if picked is None:
        emit({"ok": False, "error_type": "no_credentials",
              "error": "No Claude credentials found — sign in to "
                       "Claude Desktop or Claude Code."})

    source, token, expires = picked
    debug(f"using {source} token, "
          f"expires in {(expires - now * 1000) / 60000:.0f} min")

    raw, err = fetch_usage(token)
    if err:
        # Persist cooldowns so restarts/other instances honor them too.
        if err.get("error_type") == "rate_limited" and "retry_after" in err:
            state["cooldown_until"] = now + err["retry_after"]
            state.pop("cooldown_error", None)  # generic 429 message applies
            save_state(state)
        elif err.get("error_type") == "expired":
            state["cooldown_until"] = now + EXPIRED_COOLDOWN
            state["cooldown_error"] = err
            state["rejected_token"] = fingerprint(token)
            save_state(state)
        emit({"ok": False, **err})

    envelope = {"ok": True,
                "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                **parse_usage(raw)}
    state["last_success"] = {"envelope": envelope, "at": now}
    for stale_key in ("cooldown_until", "cooldown_error", "rejected_token"):
        state.pop(stale_key, None)  # a success clears any prior cooldown
    save_state(state)
    emit(envelope)


if __name__ == "__main__":
    main()

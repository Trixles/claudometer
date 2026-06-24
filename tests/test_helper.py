"""Unit tests for claudometer.py's pure functions (parse_usage, pick_token).

Stdlib unittest only — run from the repo root with:
    python3 -m unittest discover tests
"""

import importlib.util
import sys
import unittest
from pathlib import Path

# The helper lives inside the plasmoid package, not on sys.path — load it
# directly from its file.
HELPER = (Path(__file__).resolve().parent.parent
          / "plasmoid" / "contents" / "scripts" / "claudometer.py")
spec = importlib.util.spec_from_file_location("claudometer", HELPER)
cm = importlib.util.module_from_spec(spec)
sys.modules["claudometer"] = cm
spec.loader.exec_module(cm)


# A trimmed copy of a real /api/oauth/usage response (observed 2026-06-12).
REAL_RESPONSE = {
    "five_hour": {"utilization": 35.0,
                  "resets_at": "2026-06-12T18:20:00.492888+00:00"},
    "seven_day": {"utilization": 20.0,
                  "resets_at": "2026-06-14T19:00:00.492910+00:00"},
    "seven_day_oauth_apps": None,
    "seven_day_opus": None,
    "seven_day_sonnet": {"utilization": 0.0, "resets_at": None},
    "tangelo": None,                      # unknown null bucket → skipped
    "extra_usage": {"is_enabled": True, "monthly_limit": None,
                    "used_credits": 0.0, "utilization": None,
                    "currency": "USD", "disabled_reason": None},
}


class TestParseUsage(unittest.TestCase):
    def test_real_response(self):
        out = cm.parse_usage(REAL_RESPONSE)
        ids = [b["id"] for b in out["buckets"]]
        # null buckets and extra_usage are not buckets
        self.assertEqual(ids, ["five_hour", "seven_day", "seven_day_sonnet"])

    def test_known_labels(self):
        out = cm.parse_usage(REAL_RESPONSE)
        by_id = {b["id"]: b for b in out["buckets"]}
        self.assertEqual(by_id["five_hour"]["label"], "Session")
        self.assertEqual(by_id["seven_day"]["label"], "Week")
        self.assertEqual(by_id["five_hour"]["pct"], 35.0)
        self.assertIsNone(by_id["seven_day_sonnet"]["resets_at"])

    def test_unknown_bucket_gets_prettified_label(self):
        out = cm.parse_usage(
            {"thirty_day_haiku": {"utilization": 5.0, "resets_at": None}})
        self.assertEqual(out["buckets"][0]["label"], "Thirty Day Haiku")

    def test_null_utilization_treated_as_zero(self):
        out = cm.parse_usage({"five_hour": {"utilization": None,
                                            "resets_at": None}})
        self.assertEqual(out["buckets"][0]["pct"], 0.0)

    def test_extra_usage_passthrough(self):
        out = cm.parse_usage(REAL_RESPONSE)
        self.assertTrue(out["extra_usage"]["enabled"])
        self.assertEqual(out["extra_usage"]["used_credits"], 0.0)

    def test_empty_response(self):
        out = cm.parse_usage({})
        self.assertEqual(out["buckets"], [])
        self.assertFalse(out["extra_usage"]["enabled"])


class TestParseRetryAfter(unittest.TestCase):
    def test_integer_seconds(self):
        self.assertEqual(cm.parse_retry_after("871"), 871)

    def test_whitespace(self):
        self.assertEqual(cm.parse_retry_after("  60 "), 60)

    def test_none_and_empty(self):
        self.assertIsNone(cm.parse_retry_after(None))
        self.assertIsNone(cm.parse_retry_after(""))

    def test_garbage(self):
        self.assertIsNone(cm.parse_retry_after("soon-ish"))

    def test_http_date_in_future(self):
        # An HTTP-date far in the future yields a positive second count.
        secs = cm.parse_retry_after("Wed, 21 Oct 2099 07:28:00 GMT")
        self.assertIsNotNone(secs)
        self.assertGreater(secs, 0)


class TestPickToken(unittest.TestCase):
    NOW = 1_000_000

    def test_freshest_live_token_wins(self):
        live_old = ("code", "t1", self.NOW + 1000)
        live_new = ("desktop", "t2", self.NOW + 9000)
        self.assertEqual(cm.pick_token([live_old, live_new], self.NOW),
                         live_new)

    def test_live_beats_expired_even_if_older(self):
        expired = ("desktop", "t1", self.NOW + 999_999_999)  # can't happen,
        expired = ("desktop", "t1", self.NOW - 10)            # but be explicit
        live = ("code", "t2", self.NOW + 10)
        self.assertEqual(cm.pick_token([expired, live], self.NOW), live)

    def test_all_expired_returns_freshest_anyway(self):
        older = ("code", "t1", self.NOW - 5000)
        newer = ("desktop", "t2", self.NOW - 100)
        self.assertEqual(cm.pick_token([older, newer], self.NOW), newer)

    def test_none_candidates_filtered(self):
        live = ("code", "t", self.NOW + 1)
        self.assertEqual(cm.pick_token([None, live, None], self.NOW), live)

    def test_no_candidates(self):
        self.assertIsNone(cm.pick_token([None, None], self.NOW))


class TestCachedResponse(unittest.TestCase):
    NOW = 1_000_000.0

    def test_active_cooldown_short_circuits(self):
        state = {"cooldown_until": self.NOW + 300}
        out = cm.cached_response(state, self.NOW)
        self.assertEqual(out["error_type"], "rate_limited")
        self.assertEqual(out["retry_after"], 300)

    def test_expired_cooldown_proceeds_to_fetch(self):
        state = {"cooldown_until": self.NOW - 1}
        self.assertIsNone(cm.cached_response(state, self.NOW))

    def test_fresh_success_is_reused(self):
        env = {"ok": True, "buckets": []}
        state = {"last_success": {"envelope": env, "at": self.NOW - 5}}
        self.assertEqual(cm.cached_response(state, self.NOW), env)

    def test_stale_success_triggers_fetch(self):
        env = {"ok": True, "buckets": []}
        state = {"last_success": {"envelope": env,
                                  "at": self.NOW - cm.SUCCESS_TTL - 1}}
        self.assertIsNone(cm.cached_response(state, self.NOW))

    def test_cooldown_wins_over_fresh_success(self):
        # If both are present, the cooldown must take precedence.
        env = {"ok": True, "buckets": []}
        state = {"cooldown_until": self.NOW + 100,
                 "last_success": {"envelope": env, "at": self.NOW - 1}}
        self.assertEqual(cm.cached_response(state, self.NOW)["error_type"],
                         "rate_limited")

    def test_empty_state_proceeds(self):
        self.assertIsNone(cm.cached_response({}, self.NOW))


if __name__ == "__main__":
    unittest.main()

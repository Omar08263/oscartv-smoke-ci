"""Kolnovel v6 — MITM 500-injection addon (problem 2, Case C).

Reuses the kolnovel-redroid-mitm.sh plumbing (mitmproxy in Docker, device
global http_proxy, CA in the system trust store). Behaviour differs from
kolnovel-mitm-addon.py: instead of flipping /reader access flags, this
addon returns a REAL HTTP 500 for /reader/* requests AFTER the first N
(N=3 by default, env MITM_500_AFTER), so the export starts, fetches a few
chapters, then hits 500s mid-fetch. /titles/* and /reading-list/* are
passed through untouched, so the failure lands exactly where the export
is fetching chapter bodies.

The Activity's httpGet retries 429/5xx up to 3 times with backoff and
then throws -> fail() toast + finish, never a truncated PDF. The run
proves (or disproves) that on a real device with a real 500.

Logging: every kolnovel.com flow to /tmp/mitm-log.jsonl (env MITM_LOG),
with the 500 injections marked. No auth headers are logged in full.
"""
import json
import os

from mitmproxy import ctx

LOG_PATH = os.environ.get("MITM_LOG", "/tmp/mitm-log.jsonl")
AFTER = int(os.environ.get("MITM_500_AFTER", "3"))

_state = {"reader_seen": 0}


def _log(obj):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except Exception as e:
        try:
            ctx.log.warn(f"mitm500-addon: cannot write {LOG_PATH}: {e}")
        except Exception:
            pass


def request(flow):
    host = flow.request.host or ""
    if "kolnovel.com" not in host:
        return
    path = flow.request.path or ""
    if "/reader/" in path:
        _state["reader_seen"] += 1
        n = _state["reader_seen"]
        if n > AFTER:
            from mitmproxy.http import Response
            flow.response = Response.make(
                500,
                b'{"error": "injected 500 by mitm500-addon"}',
                {"Content-Type": "application/json"},
            )
            _log({"type": "injected-500", "path": path, "n": n})
            try:
                ctx.log.info(f"mitm500-addon: INJECTED 500 for {path} (#{n})")
            except Exception:
                pass
            return
        _log({"type": "request", "method": flow.request.method, "path": path, "n": n})
    else:
        _log({"type": "request", "method": flow.request.method, "path": path})


def response(flow):
    host = flow.request.host or ""
    if "kolnovel.com" not in host:
        return
    path = flow.request.path or ""
    if "/reader/" in path and flow.response.status_code == 200:
        _log({"type": "response", "method": flow.request.method, "path": path,
              "status": 200})

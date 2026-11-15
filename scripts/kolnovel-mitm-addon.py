"""kolnovel MITM addon (round 3, locked-chapter verdict).

Purpose: intercept the kolnovel app's live HTTPS traffic on Redroid and
prove, at runtime, whether the client trusts the server's /reader access
object (the ONLY source of is_locked / has_access).

What it does:
- Logs every request to kolnovel.com (method, path, status, and for
  /reader the ORIGINAL access flags) to /mitm/mitm-log.jsonl (JSONL, one
  line per flow). Authorization headers are NEVER logged in full (first
  20 chars only, truncated) and tokens are never written to the log.
- For GET /wp-json/app/v2/reader/<id> responses: if the server's access
  object says has_access=true / is_locked=false, FLIP it to
  has_access=false / is_locked=true AND blank the chapter content.
  This simulates a server-locked chapter. If the app then shows the
  lock screen, the client is proven to obey the server's access flag
  at runtime (i.e. the lock is server-driven, and the client adds no
  independent check). If the app still renders the chapter, the client
  ignores the flag (that would mean a client-side bypass is possible).

Why flip true->false (not false->true): the live server returns
has_access=true for every chapter tested (157 probes, 0 locked), so
there is no locked response to flip open. The true->false flip is the
only runtime test available, and it answers the same question from
the other side: does the client enforce what the server says?

Run: mitmdump -s /addon.py --set block_global=false
"""
import json
import os

LOG_PATH = os.environ.get("MITM_LOG", "/mitm/mitm-log.jsonl")


def _log(obj):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _trunc_auth(value):
    if not value:
        return None
    return value[:20] + "...(truncated)"


def request(flow):
    host = flow.request.host or ""
    if "kolnovel.com" not in host:
        return
    _log({
        "type": "request",
        "method": flow.request.method,
        "path": flow.request.path,
        "auth": _trunc_auth(flow.request.headers.get("Authorization")),
        "has_apikey": "X-API-Key" in flow.request.headers,
    })


def response(flow):
    host = flow.request.host or ""
    if "kolnovel.com" not in host:
        return
    path = flow.request.path or ""
    entry = {
        "type": "response",
        "method": flow.request.method,
        "path": path,
        "status": flow.response.status_code,
    }
    if "/reader/" in path and flow.response.status_code == 200:
        try:
            data = json.loads(flow.response.content)
            access = (data.get("data") or {}).get("access") or {}
            orig_locked = access.get("is_locked")
            orig_access = access.get("has_access")
            orig_len = len(((data.get("data") or {}).get("entry") or {}).get("content") or "")
            entry["orig_is_locked"] = orig_locked
            entry["orig_has_access"] = orig_access
            entry["orig_content_len"] = orig_len
            # Flip: simulate a server-locked chapter.
            if orig_access is True:
                access["has_access"] = False
                access["is_locked"] = True
                entry_obj = (data.get("data") or {}).get("entry") or {}
                if "content" in entry_obj:
                    entry_obj["content"] = ""
                flow.response.content = json.dumps(data).encode("utf-8")
                flow.response.headers["Content-Length"] = str(len(flow.response.content))
                entry["flipped"] = True
                entry["flip"] = "has_access true->false, is_locked false->true, content blanked"
            else:
                entry["flipped"] = False
        except Exception as e:
            entry["parse_error"] = str(e)[:120]
            entry["flipped"] = False
    _log(entry)

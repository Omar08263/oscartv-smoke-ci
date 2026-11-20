#!/usr/bin/env python3
"""Sticky-window L1 EL fault proxy for the Consensus H1 devnet PoC.

Sits between ONE Base node (the shadow validator) and the devnet L1 EL
(reth) and fails EVERY `eth_getBlockByNumber` request for an armed block
number while the upstream L1 head is inside [min_head, max_head).
Every other request is forwarded verbatim. All decisions are logged as
JSON lines (stdout + --log-file).

This models a transient L1 RPC outage at exactly the block carrying a
SystemConfig `UnsafeBlockSigner` rotation, which is the trigger for
Consensus H1: with `verifier_l1_confs = 15` the watcher fetches the
rotation block only when the L1 head reaches rotation_block + 15, and a
failure there makes it skip that head forever (no backfill).

Why sticky, not one-shot (lesson of run 44723957902): several node
components fetch the same delayed block (the L1 watcher, the derivation
ConfDepthProvider, the derivation traversal) and the proxy cannot tell
them apart by request id. A one-shot fault can be consumed by a
non-watcher fetch while the watcher's own fetch succeeds -- the fault
then silently does nothing (run 5: proxy "fired" once, watcher never
skipped, shadow never stalled). Failing every target request inside a
bounded head window guarantees the watcher's fetch fails whenever it
lands, while letting the derivation recover once the window closes.

Control surface (same port):
  POST /arm    {"block": <int>, "min_head": <int>, "max_head": <int>}
               -- arm the sticky fault (max_head defaults to min_head+11)
  POST /disarm                                           -- disarm + reset state
  GET  /status                                           -- armed/fired state
  GET  /log                                              -- the decision log so far

Standard library only. No requests are fabricated: if the upstream is
unreachable for a non-target request, the upstream error is surfaced.
"""
import argparse
import json
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FaultProxy:
    def __init__(self, upstream, log_file=None):
        self.upstream = upstream.rstrip("/")
        self.lock = threading.Lock()
        self.armed_block = None
        self.min_head = None
        self.max_head = None
        self.fired = False
        self.fired_detail = None
        self.failed_count = 0
        self.target_requests = []  # every request that named the armed block
        self.log_file = log_file
        self._head_cache = (0, 0.0)  # (head, fetched_at)

    def log(self, event):
        event["t"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = json.dumps(event)
        print(line, flush=True)
        if self.log_file:
            try:
                with open(self.log_file, "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def upstream_head(self):
        now = time.monotonic()
        with self.lock:
            head, at = self._head_cache
            if now - at < 1.0:
                return head
        try:
            body = json.dumps(
                {"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1}
            ).encode()
            req = urllib.request.Request(
                self.upstream, data=body, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
            head = int(data["result"], 16)
        except Exception as e:  # noqa: BLE001 - head check must never break forwarding
            self.log({"event": "head_check_failed", "error": str(e)})
            return -1
        with self.lock:
            self._head_cache = (head, now)
        return head

    def forward(self, raw_body):
        req = urllib.request.Request(
            self.upstream, data=raw_body, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:  # noqa: BLE001 - surface upstream failure as JSON-RPC error
            return 200, json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32000, "message": f"proxy upstream error: {e}"},
                }
            ).encode()

    def handle_rpc(self, raw_body):
        """Return (status, body) for one JSON-RPC request (single or batch)."""
        try:
            payload = json.loads(raw_body)
        except Exception:
            return self.forward(raw_body)
        is_batch = isinstance(payload, list)
        items = payload if is_batch else [payload]
        armed, min_head, max_head = self.armed_block, self.min_head, self.max_head
        faulted_ids = set()
        for item in items:
            if (
                isinstance(item, dict)
                and item.get("method") == "eth_getBlockByNumber"
                and isinstance(item.get("params"), list)
                and item["params"]
                and armed is not None
                and min_head is not None
                and max_head is not None
            ):
                try:
                    want = int(str(item["params"][0]), 16)
                except ValueError:
                    want = None
                if want == armed:
                    head = self.upstream_head()
                    # Sticky window: fail every target request while the
                    # upstream head is inside [min_head, max_head).
                    decision = "FAIL" if min_head <= head < max_head else "forward"
                    self.log(
                        {
                            "event": "target_request",
                            "id": item.get("id"),
                            "block": want,
                            "upstream_head": head,
                            "min_head": min_head,
                            "max_head": max_head,
                            "decision": decision,
                        }
                    )
                    with self.lock:
                        self.target_requests.append(
                            {"block": want, "head": head, "decision": decision}
                        )
                        if decision == "FAIL":
                            self.failed_count += 1
                            if not self.fired:
                                self.fired = True
                                self.fired_detail = {
                                    "block": want,
                                    "upstream_head": head,
                                    "id": item.get("id"),
                                }
                            faulted_ids.add(item.get("id"))
        if not faulted_ids:
            # Nothing faulted: forward the original bytes untouched.
            return self.forward(raw_body)
        # At least one item faulted: forward the rest, splice the error in.
        # (The watcher uses single requests; batches are handled for safety.)
        # Forward each non-faulted item individually to keep ids aligned.
        results = {}
        for item in items:
            if item.get("id") in faulted_ids:
                continue
            status, body = self.forward(json.dumps(item).encode())
            try:
                results[item.get("id")] = json.loads(body)
            except Exception:
                results[item.get("id")] = {
                    "jsonrpc": "2.0",
                    "id": item.get("id"),
                    "error": {"code": -32000, "message": "proxy forward error"},
                }
        merged = []
        for item in items:
            if item.get("id") in faulted_ids:
                merged.append(
                    {
                        "jsonrpc": "2.0",
                        "id": item.get("id"),
                        "error": {
                            "code": -32000,
                            "message": (
                                "injected transient L1 fault "
                                "(consensus-h1-poc): eth_getBlockByNumber failed"
                            ),
                        },
                    }
                )
                continue
            merged.append(results.get(item.get("id"), item))
        return 200, json.dumps(merged if is_batch else merged[0]).encode()


def make_handler(proxy):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # keep stdout clean: we log JSON ourselves
            pass

        def _send_json(self, status, obj):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/status":
                with proxy.lock:
                    self._send_json(
                        200,
                        {
                            "armed_block": proxy.armed_block,
                            "min_head": proxy.min_head,
                            "max_head": proxy.max_head,
                            "fired": proxy.fired,
                            "fired_detail": proxy.fired_detail,
                            "failed_count": proxy.failed_count,
                            "target_requests": proxy.target_requests,
                        },
                    )
            elif self.path == "/log":
                self._send_json(200, {"target_requests": proxy.target_requests})
            else:
                self._send_json(404, {"error": "unknown path"})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            if self.path == "/arm":
                try:
                    spec = json.loads(raw)
                    block = int(spec["block"])
                    min_head = int(spec["min_head"])
                    max_head = int(spec.get("max_head", min_head + 11))
                except Exception as e:  # noqa: BLE001
                    self._send_json(400, {"error": f"bad arm spec: {e}"})
                    return
                with proxy.lock:
                    proxy.armed_block = block
                    proxy.min_head = min_head
                    proxy.max_head = max_head
                    proxy.fired = False
                    proxy.fired_detail = None
                    proxy.failed_count = 0
                    proxy.target_requests = []
                proxy.log(
                    {
                        "event": "armed",
                        "block": block,
                        "min_head": min_head,
                        "max_head": max_head,
                    }
                )
                self._send_json(
                    200,
                    {"armed": True, "block": block, "min_head": min_head, "max_head": max_head},
                )
            elif self.path == "/disarm":
                with proxy.lock:
                    proxy.armed_block = None
                    proxy.min_head = None
                    proxy.max_head = None
                    # Reset the fired state so a later control window reads
                    # a fresh "no fault" -- run 44723957902 failed its
                    # CONTROL verdict on a stale fired=true from the fault.
                    proxy.fired = False
                    proxy.fired_detail = None
                    proxy.failed_count = 0
                    proxy.target_requests = []
                proxy.log({"event": "disarmed"})
                self._send_json(200, {"armed": False})
            elif self.path in ("/", ""):
                status, body = proxy.handle_rpc(raw)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self._send_json(404, {"error": "unknown path"})

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    # Default 0.0.0.0: the node container reaches the host proxy via the
    # Docker bridge gateway (host.docker.internal), NOT via loopback -- a
    # 127.0.0.1 bind is unreachable from inside the container (connection
    # refused; the node then fails its startup signer resolution and
    # crash-loops). The runner is ephemeral and not publicly reachable,
    # so binding all interfaces here is acceptable for this PoC.
    ap.add_argument("--listen", default="0.0.0.0:18545")
    ap.add_argument("--upstream", default="http://127.0.0.1:4545")
    ap.add_argument("--log-file", default=None)
    args = ap.parse_args()
    host, port = args.listen.rsplit(":", 1)
    proxy = FaultProxy(args.upstream, args.log_file)
    proxy.log(
        {"event": "proxy_start", "listen": args.listen, "upstream": args.upstream}
    )
    server = ThreadingHTTPServer((host, int(port)), make_handler(proxy))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Consensus H1 devnet PoC driver — Base Everest audit comp.
#
# Drives a live single-sequencer Everest devnet through two signer rotations:
#   ROTATION 1 (FAULT): rotate SystemConfig.unsafeBlockSigner to a new key,
#     restart the builder with that key, and fail EVERY delayed L1 fetch
#     of the rotation block inside a bounded head window (via the host
#     fault proxy, sticky -- not one-shot: run 44723957902 showed a
#     one-shot can be consumed by a non-watcher fetch). Expected: the
#     shadow validator's unsafe head stalls forever (until restart)
#     while the builder advances.
#   HEAL: restart the shadow validator; its startup re-read of the signer
#     must heal it (unsafe head catches up).
#   ROTATION 2 (CONTROL, no fault): same rotation with the proxy disarmed.
#     Expected: the shadow validator stalls ~15 L1 blocks (the configured
#     verifier delay) and then resumes and catches up.
#
# Exit code: 0 only if FAULT verdict + HEAL + CONTROL verdict all hold.
# Evidence is written to $EVIDENCE regardless of outcome.
#
# Prerequisites (done by the workflow before calling this script):
#   - Everest devnet up (just devnet up-single everest), healthy
#   - fault proxy running on 127.0.0.1:18545, upstream http://127.0.0.1:4545
#   - shadow validator re-pointed at the proxy (docker-compose.h1-override.yml)
#   - cast + jq + curl + docker compose available
set -u
BASE_DIR="${BASE_DIR:?set BASE_DIR to the base repo checkout}"
POC_DIR="${POC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EVIDENCE="${EVIDENCE:-$PWD/artifacts}"
L1_RPC="${L1_RPC:-http://127.0.0.1:4545}"
BUILDER_OP="${BUILDER_OP:-http://127.0.0.1:7549}"
SHADOW_OP="${SHADOW_OP:-http://127.0.0.1:8849}"
PROXY="${PROXY:-http://127.0.0.1:18545}"
SHADOW_METRICS="${SHADOW_METRICS:-http://127.0.0.1:8890/metrics}"
COMPOSE="docker compose --env-file etc/docker/devnet-env -f etc/docker/docker-compose.yml -f etc/docker/docker-compose.h1-override.yml"
mkdir -p "$EVIDENCE"
exec > >(tee -a "$EVIDENCE/driver.log") 2>&1

# Devnet test keys (standard Anvil/Hardhat accounts, public in devnet-env).
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SEQUENCER_ADDR="0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
NEW1_ADDR="0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f"   # Anvil account 8
NEW1_KEY="dbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97"
NEW2_ADDR="0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"   # Anvil account 7
NEW2_KEY="4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { log "ERROR: $*"; }

sync_sample() { # <label> — append one JSON line per node to sync-samples.jsonl
  local label="$1" ts now l1 builder shadow
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  l1="$(cast block-number --rpc-url "$L1_RPC" 2>/dev/null || echo null)"
  builder="$(curl -s "$BUILDER_OP" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' 2>/dev/null \
    | jq -c '.result | {unsafe: .unsafe_l2.number, safe: .safe_l2.number} // null')"
  shadow="$(curl -s "$SHADOW_OP" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' 2>/dev/null \
    | jq -c '.result | {unsafe: .unsafe_l2.number, safe: .safe_l2.number} // null')"
  echo "{\"ts\":\"$ts\",\"label\":\"$label\",\"l1\":$l1,\"builder\":$builder,\"shadow\":$shadow}" \
    | tee -a "$EVIDENCE/sync-samples.jsonl"
}

unsafe_of() { # <op-url> -> unsafe L2 number or empty
  curl -s "$1" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' 2>/dev/null \
    | jq -r '.result.unsafe_l2.number // empty'
}

l1_head() { cast block-number --rpc-url "$L1_RPC" 2>/dev/null || echo 0; }

onchain_signer() { cast call "$SYSTEM_CONFIG" "unsafeBlockSigner()(address)" --rpc-url "$L1_RPC" 2>/dev/null; }

invalid_signer_count() { # Prometheus counter for gossip signer rejections (supporting evidence)
  curl -s "$SHADOW_METRICS" 2>/dev/null | grep 'invalid_signer' | awk '{s+=$NF} END {print s+0}'
}

strip_ansi() { # stdin -> stdout with ANSI escape sequences removed (node logs are colored;
  # raw "target=7" never appears: the field name and "=" are wrapped in separate escapes)
  sed 's/\x1b\[[0-9;]*m//g'
}

delayed_fetch_errors() { # Prometheus counter: the watcher's delayed L1 block fetch failures
  # (actor.rs increments it on BOTH the Err and the Ok(None) skip paths).
  # This is the authoritative "did the fault reach the watcher" signal --
  # independent of log tails. The series appears only after the first
  # increment, so compare before/after (delta), not the absolute value.
  curl -s "$SHADOW_METRICS" 2>/dev/null | grep 'l1_verifier_delayed_fetch_errors' | awk '{s+=$NF} END {print s+0}'
}

dump_metrics() { # <file> — save the raw metrics exposition for the evidence pack
  curl -s "$SHADOW_METRICS" 2>/dev/null > "$1" || true
}

verify_builder_key() { # <key-no-0x> — confirm the running builder container carries the key
  local key="$1" waited=0 cid cmd
  while [ "$waited" -lt 120 ]; do
    cid="$(cd "$BASE_DIR" && $COMPOSE ps -q base-builder 2>/dev/null)"
    if [ -n "$cid" ]; then
      cmd="$(docker inspect --format '{{json .Config.Cmd}}' "$cid" 2>/dev/null)"
      if echo "$cmd" | grep -q "$key"; then
        log "builder key verified in container command (cid ${cid:0:12})"
        return 0
      fi
      # Fallback: the key might live elsewhere in the container config.
      if docker inspect "$cid" 2>/dev/null | grep -q "$key"; then
        log "builder key verified in container inspect (cid ${cid:0:12})"
        return 0
      fi
    fi
    sleep 10; waited=$((waited + 10))
  done
  log "ERROR: builder container does NOT carry the new sequencer key after 120s (key=$key)"
  return 1
}

start_log_streams() { # stream both nodes' FULL logs to the evidence dir.
  # A --tail 4000 dump covers only ~1 minute at -vvv (run 44723957902 lost
  # the whole fault window that way); the streams are the primary record.
  (cd "$BASE_DIR" && $COMPOSE logs -f base-shadow-validator > "$EVIDENCE/shadow-validator-full.log" 2>&1 & echo $! > "$EVIDENCE/.shadow-logs-pid")
  (cd "$BASE_DIR" && $COMPOSE logs -f base-builder > "$EVIDENCE/builder-full.log" 2>&1 & echo $! > "$EVIDENCE/.builder-logs-pid")
  sleep 3
  for f in "$EVIDENCE/shadow-validator-full.log" "$EVIDENCE/builder-full.log"; do
    [ -s "$f" ] || log "WARNING: log stream produced no output yet: $f"
  done
  log "full log streams started (shadow + builder)"
}

stop_log_streams() {
  for f in "$EVIDENCE/.shadow-logs-pid" "$EVIDENCE/.builder-logs-pid"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
  done
  sleep 5  # let the streams flush
  log "full log streams stopped"
}

wait_l1_head() { # <target> <timeout_s>
  local target="$1" timeout_s="$2" waited=0 head
  while [ "$waited" -lt "$timeout_s" ]; do
    head="$(l1_head)"; [ "$head" -ge "$target" ] 2>/dev/null && { echo "$head"; return 0; }
    sleep 10; waited=$((waited + 10))
  done
  echo "TIMEOUT waiting L1>=$target (head=$(l1_head))" >&2; return 1
}

wait_builder_advancing() { # <timeout_s> — builder unsafe moves twice
  local timeout_s="$1" waited=0 a b
  a="$(unsafe_of "$BUILDER_OP")"
  while [ "$waited" -lt "$timeout_s" ]; do
    sleep 20; waited=$((waited + 20))
    b="$(unsafe_of "$BUILDER_OP")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then echo "$b"; return 0; fi
    a="$b"
  done
  echo "TIMEOUT builder unsafe not advancing" >&2; return 1
}

wait_shadow_catchup() { # <timeout_s> — shadow unsafe within 5 of builder unsafe
  local timeout_s="$1" waited=0 b s
  while [ "$waited" -lt "$timeout_s" ]; do
    b="$(unsafe_of "$BUILDER_OP")"; s="$(unsafe_of "$SHADOW_OP")"
    if [ -n "$b" ] && [ -n "$s" ] && [ "$((b - s))" -le 5 ]; then echo "$s/$b"; return 0; fi
    sleep 15; waited=$((waited + 15))
  done
  echo "TIMEOUT shadow catchup (shadow=$(unsafe_of "$SHADOW_OP") builder=$(unsafe_of "$BUILDER_OP"))" >&2
  return 1
}

rotate_signer() { # <new-addr> -> prints the DECIMAL L1 block number of the rotation tx
  # NOTE: the log line goes to stderr on purpose — this function's stdout
  # is captured by the caller, so any stdout logging would pollute the
  # returned block number (run 44719570544 died exactly that way).
  local new_addr="$1" receipt block_hex block
  receipt="$(cast send "$SYSTEM_CONFIG" "setUnsafeBlockSigner(address)" "$new_addr" \
    --private-key "$DEPLOYER_KEY" --rpc-url "$L1_RPC" --json 2>/dev/null)"
  block_hex="$(echo "$receipt" | jq -r '.blockNumber // empty')"
  [ -z "$block_hex" ] && { echo ""; return 1; }
  block="$((block_hex))"  # hex (0x..) -> decimal for the proxy + arithmetic
  log "rotation tx: $(echo "$receipt" | jq -r '.transactionHash // "?"') block=$block_hex ($block) status=$(echo "$receipt" | jq -r '.status // "?"')" >&2
  echo "$block"
}

restart_builder_with_key() { # <key-no-0x> — returns 0 only if the new key is in the running container
  local key="$1"
  sed -i "s/^SEQUENCER_KEY=.*/SEQUENCER_KEY=$key/" "$BASE_DIR/etc/docker/devnet-env"
  (cd "$BASE_DIR" && $COMPOSE up -d base-builder > "$EVIDENCE/builder-restart-${key:0:8}.log" 2>&1)
  log "builder restarted with new sequencer key"
  verify_builder_key "$key"
}

VERDICT_FAULT=FAIL; VERDICT_HEAL=FAIL; VERDICT_CONTROL=FAIL
KEY1_OK=PASS; KEY2_OK=PASS  # flipped to FAIL if the builder key switch is not verified

# ---------------- Phase 0: baseline ----------------
log "== Phase 0: baseline =="
SYSTEM_CONFIG="$(jq -r '.SystemConfigProxy' "$BASE_DIR/.devnet/l2/configs/l1-addresses.json")"
log "SystemConfigProxy=$SYSTEM_CONFIG"
log "on-chain unsafeBlockSigner at start: $(onchain_signer) (genesis sequencer: $SEQUENCER_ADDR)"
sync_sample "baseline-start"
waited=0
while [ "$waited" -lt 1200 ]; do
  b="$(unsafe_of "$BUILDER_OP")"; s="$(unsafe_of "$SHADOW_OP")"
  if [ -n "$b" ] && [ -n "$s" ] && [ "$b" -gt 150 ] && [ "$((b - s))" -le 10 ]; then
    log "healthy: builder unsafe=$b shadow unsafe=$s l1=$(l1_head)"
    break
  fi
  sleep 20; waited=$((waited + 20))
done
if [ "$waited" -ge 1200 ]; then
  fail "devnet did not reach healthy baseline"
  sync_sample "baseline-timeout"
  (cd "$BASE_DIR" && $COMPOSE ps > "$EVIDENCE/compose-ps.txt" 2>&1 || true)
  (cd "$BASE_DIR" && $COMPOSE logs --tail 1000 base-builder > "$EVIDENCE/builder-baseline-timeout.log" 2>&1 || true)
  (cd "$BASE_DIR" && $COMPOSE logs --tail 1000 base-shadow-validator > "$EVIDENCE/shadow-validator-baseline-timeout.log" 2>&1 || true)
  { echo "# Consensus H1 devnet PoC — verdict"; echo ""; echo "BASELINE TIMEOUT: devnet never became healthy; no rotations attempted."; } > "$EVIDENCE/VERDICT.md"
  exit 1
fi
sync_sample "baseline-ok"

# ---------------- Phase 1: fault rotation ----------------
log "== Phase 1: FAULT rotation =="
start_log_streams
FETCH_ERR_PRE="$(delayed_fetch_errors)"
log "delayed-fetch-errors baseline (before fault): $FETCH_ERR_PRE"
# The rotation MUST land at an L1 block >= verifier_l1_confs (15). For
# heads below the confirmation depth the watcher scans the head block's
# logs directly (derivation_block = head, no delayed fetch), so a rotation
# at block < 15 is learned immediately and the fault can never matter.
# Run 44732613126 proved it: rotation at block 7 was learned 3s after
# mining (12:26:48, "Unsafe block signer update signer=0x2361..."),
# 4 min BEFORE the delayed-fetch skip at 12:30:48 -- the shadow never
# stalled even though the fault, the skip and the key switch all worked.
log "waiting for L1 head >= 20 so the rotation lands above the confirmation depth..."
wait_l1_head 20 600 || fail "L1 did not reach 20 before the fault rotation"
N1="$(rotate_signer "$NEW1_ADDR")"
[ -z "$N1" ] && { fail "rotation 1 tx produced no block number"; exit 1; }
[ "$N1" -lt 15 ] && { fail "rotation 1 landed at L1 block N1=$N1 (< verifier_l1_confs 15) -- the watcher would learn it via the no-delay path; aborting"; exit 1; }
log "rotation 1 in L1 block N1=$N1; on-chain signer now: $(onchain_signer)"
# Sticky window [N1+14, N1+25): the watcher fetches the rotation block at
# head N1+15; the window covers it even if the watcher's head lags a few
# blocks, and lets the derivation recover once the window closes.
curl -s -X POST "$PROXY/arm" -H 'Content-Type: application/json' \
  --data "{\"block\": $N1, \"min_head\": $((N1 + 14)), \"max_head\": $((N1 + 25))}" | tee -a "$EVIDENCE/proxy-arm-1.json"; echo
restart_builder_with_key "$NEW1_KEY" || KEY1_OK=FAIL
log "waiting for builder to resume producing..."
wait_builder_advancing 600 || fail "builder did not resume after rotation 1"
sync_sample "fault-builder-resumed"
SHADOW_PRE_FAULT="$(unsafe_of "$SHADOW_OP")"
log "shadow unsafe just after builder resume: $SHADOW_PRE_FAULT"
# Sample the shadow's trajectory through the fault window (not just the
# endpoints): a transient stall-then-resume must be visible.
( while true; do sync_sample "fault-sample" > /dev/null 2>&1; sleep 30; done ) &
echo $! > "$EVIDENCE/.fault-sampler-pid"
TARGET_HEAD=$((N1 + 30))
log "waiting for L1 head >= $TARGET_HEAD (N1+30) ..."
wait_l1_head "$TARGET_HEAD" 900 || fail "L1 did not reach N1+30"
sleep 30  # let the last gossip validations settle
kill "$(cat "$EVIDENCE/.fault-sampler-pid")" 2>/dev/null || true
sync_sample "fault-window-end"
SHADOW_POST_FAULT="$(unsafe_of "$SHADOW_OP")"
BUILDER_POST_FAULT="$(unsafe_of "$BUILDER_OP")"
log "fault window end: shadow unsafe=$SHADOW_POST_FAULT (was $SHADOW_PRE_FAULT) builder unsafe=$BUILDER_POST_FAULT"
# Evidence: the FULL streamed log (ANSI-stripped) + the proxy + the metrics.
# The --tail dumps are backup only (4000 lines ~= 1 min at -vvv).
(cd "$BASE_DIR" && $COMPOSE logs --tail 20000 base-shadow-validator > "$EVIDENCE/shadow-validator-fault.log" 2>&1)
(cd "$BASE_DIR" && $COMPOSE logs --tail 20000 base-builder > "$EVIDENCE/builder-fault.log" 2>&1)
SHADOW_FULL="$EVIDENCE/shadow-validator-full.log"
SKIP_COUNT="$(strip_ansi < "$SHADOW_FULL" | grep -c "Failed to fetch delayed L1 block; skipping head update" || true)"
SKIP_N1="$(strip_ansi < "$SHADOW_FULL" | grep "Failed to fetch delayed L1 block; skipping head update" | grep -c "target=$N1" || true)"
SIGNER_REJ="$(strip_ansi < "$SHADOW_FULL" | grep -ci "invalid_signer" || true)"
SIGNER_METRIC_FAULT="$(invalid_signer_count)"
# Negative control: the watcher must NOT have learned NEW1 before the skip
# (it would mean the rotation landed below the confirmation depth and the
# no-delay path scanned it -- the run-6 failure mode).
SIGNER_LEARNED_EARLY="$(strip_ansi < "$SHADOW_FULL" | grep -i "Unsafe block signer update" | grep -ci "${NEW1_ADDR}" || true)"
FETCH_ERR_POST="$(delayed_fetch_errors)"
FETCH_ERR_DELTA=$((FETCH_ERR_POST - FETCH_ERR_PRE))
dump_metrics "$EVIDENCE/shadow-metrics-fault.txt"
PROXY_STATUS="$(curl -s "$PROXY/status")"
echo "$PROXY_STATUS" > "$EVIDENCE/proxy-status-fault.json"
PROXY_FIRED="$(echo "$PROXY_STATUS" | jq -r '.fired')"
PROXY_FIRED_BLOCK="$(echo "$PROXY_STATUS" | jq -r '.fired_detail.block // empty')"
PROXY_FAILED_COUNT="$(echo "$PROXY_STATUS" | jq -r '.failed_count // 0')"
log "fault evidence: proxy fired=$PROXY_FIRED block=$PROXY_FIRED_BLOCK failed_requests=$PROXY_FAILED_COUNT | key_switch=$KEY1_OK | delayed-fetch-errors delta=$FETCH_ERR_DELTA (pre=$FETCH_ERR_PRE post=$FETCH_ERR_POST) | skip-logs=$SKIP_COUNT (target=N1: $SKIP_N1) | watcher learned NEW1 early=$SIGNER_LEARNED_EARLY | invalid_signer lines=$SIGNER_REJ | invalid_signer metric count=$SIGNER_METRIC_FAULT"
if [ "$SIGNER_LEARNED_EARLY" -ge 1 ]; then
  log "DIAGNOSIS: watcher learned NEW1 before the skip (rotation landed below the confirmation depth) — a FAIL here is a design violation, NOT a candidate refutation"
fi
if [ "$FETCH_ERR_DELTA" -lt 1 ] || [ "$SKIP_N1" -lt 1 ]; then
  log "DIAGNOSIS: fault did NOT reach the watcher (delayed-fetch-errors delta=$FETCH_ERR_DELTA, skip-logs for N1=$SKIP_N1) — a FAIL here is a harness miss, NOT a candidate refutation"
fi
if [ "$PROXY_FIRED" = "true" ] && [ "$PROXY_FIRED_BLOCK" = "$N1" ] \
   && [ "$KEY1_OK" = "PASS" ] \
   && [ "$FETCH_ERR_DELTA" -ge 1 ] \
   && [ "$SKIP_N1" -ge 1 ] \
   && [ "$SIGNER_LEARNED_EARLY" = "0" ] \
   && [ -n "$SHADOW_PRE_FAULT" ] && [ -n "$SHADOW_POST_FAULT" ] \
   && [ "$((SHADOW_POST_FAULT - SHADOW_PRE_FAULT))" -le 2 ] \
   && [ -n "$BUILDER_POST_FAULT" ] && [ "$BUILDER_POST_FAULT" -gt "$((SHADOW_POST_FAULT + 20))" ]; then
  VERDICT_FAULT=PASS
  log "VERDICT FAULT: PASS — shadow unsafe stuck at $SHADOW_POST_FAULT while builder advanced to $BUILDER_POST_FAULT"
else
  log "VERDICT FAULT: FAIL (see evidence)"
fi

# ---------------- Phase 2: restart heals ----------------
log "== Phase 2: restart heals =="
(cd "$BASE_DIR" && $COMPOSE restart base-shadow-validator >/dev/null 2>&1)
log "shadow validator restarted; waiting for catch-up..."
if wait_shadow_catchup 600; then
  VERDICT_HEAL=PASS
  log "VERDICT HEAL: PASS — shadow unsafe caught up after restart"
else
  log "VERDICT HEAL: FAIL"
fi
sync_sample "heal-done"

# ---------------- Phase 3: control rotation (no fault) ----------------
log "== Phase 3: CONTROL rotation (proxy disarmed) =="
curl -s -X POST "$PROXY/disarm" | tee -a "$EVIDENCE/proxy-disarm.json"; echo
FETCH_ERR_PRE_CTRL="$(delayed_fetch_errors)"
log "delayed-fetch-errors baseline (before control): $FETCH_ERR_PRE_CTRL"
N2="$(rotate_signer "$NEW2_ADDR")"
[ -z "$N2" ] && { fail "rotation 2 tx produced no block number"; exit 1; }
[ "$N2" -lt 15 ] && { fail "rotation 2 landed at L1 block N2=$N2 (< verifier_l1_confs 15) -- the watcher would learn it via the no-delay path; aborting"; exit 1; }
log "rotation 2 in L1 block N2=$N2; on-chain signer now: $(onchain_signer)"
restart_builder_with_key "$NEW2_KEY" || KEY2_OK=FAIL
wait_builder_advancing 600 || fail "builder did not resume after rotation 2"
sync_sample "control-builder-resumed"
SHADOW_PRE_CTRL="$(unsafe_of "$SHADOW_OP")"
log "shadow unsafe just after builder resume (control): $SHADOW_PRE_CTRL"
# Sample mid-window: at N2+10 the shadow should still be stalled (15-block delay).
wait_l1_head $((N2 + 10)) 600 || fail "L1 did not reach N2+10"
sleep 20
SHADOW_MID_CTRL="$(unsafe_of "$SHADOW_OP")"
sync_sample "control-mid-window"
log "control mid-window (L1=N2+10): shadow unsafe=$SHADOW_MID_CTRL (was $SHADOW_PRE_CTRL)"
wait_l1_head $((N2 + 30)) 900 || fail "L1 did not reach N2+30"
sleep 30
sync_sample "control-window-end"
SHADOW_POST_CTRL="$(unsafe_of "$SHADOW_OP")"
BUILDER_POST_CTRL="$(unsafe_of "$BUILDER_OP")"
log "control window end: shadow unsafe=$SHADOW_POST_CTRL builder unsafe=$BUILDER_POST_CTRL"
(cd "$BASE_DIR" && $COMPOSE logs --tail 20000 base-shadow-validator > "$EVIDENCE/shadow-validator-control.log" 2>&1)
SKIP_N2="$(strip_ansi < "$EVIDENCE/shadow-validator-full.log" | grep "Failed to fetch delayed L1 block; skipping head update" | grep -c "target=$N2" || true)"
FETCH_ERR_POST_CTRL="$(delayed_fetch_errors)"
FETCH_ERR_DELTA_CTRL=$((FETCH_ERR_POST_CTRL - FETCH_ERR_PRE_CTRL))
dump_metrics "$EVIDENCE/shadow-metrics-control.txt"
PROXY_STATUS2="$(curl -s "$PROXY/status")"
echo "$PROXY_STATUS2" > "$EVIDENCE/proxy-status-control.json"
PROXY_FIRED2="$(echo "$PROXY_STATUS2" | jq -r '.fired')"
log "control evidence: proxy fired=$PROXY_FIRED2 | key_switch=$KEY2_OK | delayed-fetch-errors delta=$FETCH_ERR_DELTA_CTRL | skip-logs for N2=$SKIP_N2 | mid-window stall: pre=$SHADOW_PRE_CTRL mid=$SHADOW_MID_CTRL post=$SHADOW_POST_CTRL"
if [ "$PROXY_FIRED2" = "false" ] && [ "$KEY2_OK" = "PASS" ] && [ "$FETCH_ERR_DELTA_CTRL" = "0" ] && [ "$SKIP_N2" = "0" ] \
   && [ -n "$SHADOW_MID_CTRL" ] && [ -n "$SHADOW_PRE_CTRL" ] \
   && [ "$((SHADOW_MID_CTRL - SHADOW_PRE_CTRL))" -le 2 ] \
   && [ -n "$SHADOW_POST_CTRL" ] && [ -n "$BUILDER_POST_CTRL" ] \
   && [ "$((BUILDER_POST_CTRL - SHADOW_POST_CTRL))" -le 5 ]; then
  VERDICT_CONTROL=PASS
  log "VERDICT CONTROL: PASS — shadow stalled ~15 blocks then resumed and caught up"
else
  log "VERDICT CONTROL: FAIL (see evidence)"
fi

# ---------------- Phase 4: evidence pack + verdict ----------------
log "== Phase 4: evidence pack =="
stop_log_streams
(cd "$BASE_DIR" && $COMPOSE ps > "$EVIDENCE/compose-ps.txt" 2>&1 || true)
(cd "$BASE_DIR" && $COMPOSE logs --tail 20000 base-builder > "$EVIDENCE/builder-final.log" 2>&1 || true)
(cd "$BASE_DIR" && $COMPOSE logs --tail 20000 base-shadow-validator > "$EVIDENCE/shadow-validator-final.log" 2>&1 || true)
dump_metrics "$EVIDENCE/shadow-metrics-final.txt"
{
  echo "# Consensus H1 devnet PoC — verdict"
  echo ""
  echo "- Pins: base 689054ee + #6682 + #6680 (ee43b407f); contracts v8.5.0-rc.1 (b9b76d97)"
  echo "- verifier_l1_confs: 15 (devnet default, BASE_NODE_VERIFIER_L1_CONFS)"
  echo "- Rotation 1 (FAULT): L1 block N1=$N1, new signer $NEW1_ADDR"
  echo "- Rotation 2 (CONTROL): L1 block N2=$N2, new signer $NEW2_ADDR"
  echo ""
  echo "## Verdicts"
  echo "- FAULT (rotation lost until restart): $VERDICT_FAULT"
  echo "- HEAL (restart restores the signer): $VERDICT_HEAL"
  echo "- CONTROL (healthy rotation stalls ~15 blocks then resumes): $VERDICT_CONTROL"
  echo ""
  echo "## Key numbers"
  echo "- Fault window: shadow unsafe $SHADOW_PRE_FAULT -> $SHADOW_POST_FAULT; builder unsafe $BUILDER_POST_FAULT"
  echo "- Control window: shadow unsafe $SHADOW_PRE_CTRL -> mid $SHADOW_MID_CTRL -> $SHADOW_POST_CTRL; builder $BUILDER_POST_CTRL"
  echo "- Proxy fault fired: $PROXY_FIRED (block $PROXY_FIRED_BLOCK, failed requests: $PROXY_FAILED_COUNT, sticky window [N1+14, N1+25))"
  echo "- Builder key switch verified: rotation 1 $KEY1_OK, rotation 2 $KEY2_OK"
  echo "- delayed-fetch-errors delta: fault $FETCH_ERR_DELTA (pre=$FETCH_ERR_PRE post=$FETCH_ERR_POST), control $FETCH_ERR_DELTA_CTRL"
  echo "- watcher learned NEW1 before the skip: $SIGNER_LEARNED_EARLY (must be 0; rotation must land at L1 >= verifier_l1_confs 15)"
  echo "- skip-logs for N1: $SKIP_N1 (all skip-logs: $SKIP_COUNT); invalid_signer log lines: $SIGNER_REJ; invalid_signer metric count at fault end: $SIGNER_METRIC_FAULT; skip-logs for N2: $SKIP_N2"
  echo "- Full logs: shadow-validator-full.log / builder-full.log (streamed, whole run); metrics: shadow-metrics-fault.txt / shadow-metrics-control.txt"
} > "$EVIDENCE/VERDICT.md"
cat "$EVIDENCE/VERDICT.md"
if [ "$VERDICT_FAULT" = "PASS" ] && [ "$VERDICT_HEAL" = "PASS" ] && [ "$VERDICT_CONTROL" = "PASS" ]; then
  log "DEVNET POC: ALL VERDICTS PASS"
  exit 0
else
  log "DEVNET POC: NOT ALL VERDICTS PASS (fault=$VERDICT_FAULT heal=$VERDICT_HEAL control=$VERDICT_CONTROL)"
  exit 1
fi

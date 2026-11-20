#!/usr/bin/env bash
# Consensus H1 devnet PoC driver — Base Everest audit comp.
#
# Drives a live single-sequencer Everest devnet through two signer rotations:
#   ROTATION 1 (FAULT): rotate SystemConfig.unsafeBlockSigner to a new key,
#     restart the builder with that key, and fail the shadow validator's
#     delayed L1 fetch of the rotation block exactly once (via the host
#     fault proxy). Expected: the shadow validator's unsafe head stalls
#     forever (until restart) while the builder advances.
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

rotate_signer() { # <new-addr> -> prints the L1 block number of the rotation tx
  local new_addr="$1" receipt block
  receipt="$(cast send "$SYSTEM_CONFIG" "setUnsafeBlockSigner(address)" "$new_addr" \
    --private-key "$DEPLOYER_KEY" --rpc-url "$L1_RPC" --json 2>/dev/null)"
  block="$(echo "$receipt" | jq -r '.blockNumber // empty')"
  log "rotation tx: $(echo "$receipt" | jq -r '.transactionHash // "?"') block=$block status=$(echo "$receipt" | jq -r '.status // "?"')"
  echo "$block"
}

restart_builder_with_key() { # <key-no-0x>
  local key="$1"
  sed -i "s/^SEQUENCER_KEY=.*/SEQUENCER_KEY=$key/" "$BASE_DIR/etc/docker/devnet-env"
  (cd "$BASE_DIR" && $COMPOSE up -d base-builder >/dev/null 2>&1)
  log "builder restarted with new sequencer key"
}

VERDICT_FAULT=FAIL; VERDICT_HEAL=FAIL; VERDICT_CONTROL=FAIL

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
N1="$(rotate_signer "$NEW1_ADDR")"
[ -z "$N1" ] && { fail "rotation 1 tx produced no block number"; exit 1; }
log "rotation 1 in L1 block N1=$N1; on-chain signer now: $(onchain_signer)"
curl -s -X POST "$PROXY/arm" -H 'Content-Type: application/json' \
  --data "{\"block\": $N1, \"min_head\": $((N1 + 14))}" | tee -a "$EVIDENCE/proxy-arm-1.json"; echo
restart_builder_with_key "$NEW1_KEY"
log "waiting for builder to resume producing..."
wait_builder_advancing 600 || fail "builder did not resume after rotation 1"
sync_sample "fault-builder-resumed"
SHADOW_PRE_FAULT="$(unsafe_of "$SHADOW_OP")"
log "shadow unsafe just after builder resume: $SHADOW_PRE_FAULT"
TARGET_HEAD=$((N1 + 30))
log "waiting for L1 head >= $TARGET_HEAD (N1+30) ..."
wait_l1_head "$TARGET_HEAD" 900 || fail "L1 did not reach N1+30"
sleep 30  # let the last gossip validations settle
sync_sample "fault-window-end"
SHADOW_POST_FAULT="$(unsafe_of "$SHADOW_OP")"
BUILDER_POST_FAULT="$(unsafe_of "$BUILDER_OP")"
log "fault window end: shadow unsafe=$SHADOW_POST_FAULT (was $SHADOW_PRE_FAULT) builder unsafe=$BUILDER_POST_FAULT"
# Evidence from the two logs + the proxy.
SHADOW_LOGS="$EVIDENCE/shadow-validator-fault.log"
BUILDER_LOGS="$EVIDENCE/builder-fault.log"
(cd "$BASE_DIR" && $COMPOSE logs --tail 4000 base-shadow-validator > "$SHADOW_LOGS" 2>&1)
(cd "$BASE_DIR" && $COMPOSE logs --tail 4000 base-builder > "$BUILDER_LOGS" 2>&1)
SKIP_COUNT="$(grep -c "Failed to fetch delayed L1 block; skipping head update" "$SHADOW_LOGS" || true)"
SKIP_N1="$(grep "Failed to fetch delayed L1 block; skipping head update" "$SHADOW_LOGS" | grep -c "target=$N1" || true)"
SIGNER_REJ="$(grep -ci "invalid_signer" "$SHADOW_LOGS" || true)"
SIGNER_METRIC_FAULT="$(invalid_signer_count)"
PROXY_STATUS="$(curl -s "$PROXY/status")"
echo "$PROXY_STATUS" > "$EVIDENCE/proxy-status-fault.json"
PROXY_FIRED="$(echo "$PROXY_STATUS" | jq -r '.fired')"
PROXY_FIRED_BLOCK="$(echo "$PROXY_STATUS" | jq -r '.fired_detail.block // empty')"
log "fault evidence: proxy fired=$PROXY_FIRED block=$PROXY_FIRED_BLOCK | skip-logs=$SKIP_COUNT (target=N1: $SKIP_N1) | invalid_signer lines=$SIGNER_REJ | invalid_signer metric count=$SIGNER_METRIC_FAULT"
if [ "$PROXY_FIRED" = "true" ] && [ "$PROXY_FIRED_BLOCK" = "$N1" ] \
   && [ "$SKIP_N1" -ge 1 ] \
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
N2="$(rotate_signer "$NEW2_ADDR")"
[ -z "$N2" ] && { fail "rotation 2 tx produced no block number"; exit 1; }
log "rotation 2 in L1 block N2=$N2; on-chain signer now: $(onchain_signer)"
restart_builder_with_key "$NEW2_KEY"
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
(cd "$BASE_DIR" && $COMPOSE logs --tail 4000 base-shadow-validator > "$EVIDENCE/shadow-validator-control.log" 2>&1)
SKIP_N2="$(grep "Failed to fetch delayed L1 block; skipping head update" "$EVIDENCE/shadow-validator-control.log" | grep -c "target=$N2" || true)"
PROXY_STATUS2="$(curl -s "$PROXY/status")"
echo "$PROXY_STATUS2" > "$EVIDENCE/proxy-status-control.json"
PROXY_FIRED2="$(echo "$PROXY_STATUS2" | jq -r '.fired')"
log "control evidence: proxy fired=$PROXY_FIRED2 | skip-logs for N2=$SKIP_N2 | mid-window stall: pre=$SHADOW_PRE_CTRL mid=$SHADOW_MID_CTRL post=$SHADOW_POST_CTRL"
if [ "$PROXY_FIRED2" = "false" ] && [ "$SKIP_N2" = "0" ] \
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
(cd "$BASE_DIR" && $COMPOSE ps > "$EVIDENCE/compose-ps.txt" 2>&1 || true)
(cd "$BASE_DIR" && $COMPOSE logs --tail 2000 base-builder > "$EVIDENCE/builder-final.log" 2>&1 || true)
(cd "$BASE_DIR" && $COMPOSE logs --tail 2000 base-shadow-validator > "$EVIDENCE/shadow-validator-final.log" 2>&1 || true)
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
  echo "- Proxy fault fired: $PROXY_FIRED (block $PROXY_FIRED_BLOCK); skip-logs for N1: $SKIP_N1; invalid_signer log lines: $SIGNER_REJ; invalid_signer metric count at fault end: $SIGNER_METRIC_FAULT; skip-logs for N2: $SKIP_N2"
} > "$EVIDENCE/VERDICT.md"
cat "$EVIDENCE/VERDICT.md"
if [ "$VERDICT_FAULT" = "PASS" ] && [ "$VERDICT_HEAL" = "PASS" ] && [ "$VERDICT_CONTROL" = "PASS" ]; then
  log "DEVNET POC: ALL VERDICTS PASS"
  exit 0
else
  log "DEVNET POC: NOT ALL VERDICTS PASS (fault=$VERDICT_FAULT heal=$VERDICT_HEAL control=$VERDICT_CONTROL)"
  exit 1
fi

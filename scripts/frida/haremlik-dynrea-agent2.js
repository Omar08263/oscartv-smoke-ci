/*
 * Haremlik Al-Sultan (com.dc.hwsj 7.804) — DYNREA AGENT 2 Frida script.
 *
 * Targets (see work/dynrea/agent2/STATIC-PREP.md for the full static pin-down):
 *   (1) wife-call 10401 cTime trust — does the server honour a client-sent
 *       cTime larger than its own VigorCount?
 *   (2) VIP validation on one-key actions — 10605 (visit), 10211 (chapter
 *       sweep), 10703 (government), 12005 (tribute), 10001 (levy collect),
 *       10807 (court multi-award), 16340/16342 (pet one-key collect).
 *       NOTE (static fact): NONE of these requests carries a VipLv param
 *       (see STATIC-PREP.md §2), so the server cannot see the client's
 *       forced VIP 16 in the bytes at all — a v4 accept proves it does not
 *       check VIP; a reject proves it checks its own VIP record.
 *   (3) other client-computed counts/amounts — 10603 ItemCount, 10206
 *       SilverNum, 10002 RecoverTimes, 12004 UseNum.
 *
 * Method — TWO independent layers, both logging with the [DYNREA] prefix:
 *   A. TRAFFIC (ground truth, adapted from agent1's baseline): hooks
 *      KSecureValidation.flip(KSNetMeta) — dir=1 OUT dt-before = plaintext
 *      request JSON; dir=0 IN dt-after = plaintext response JSON.
 *      Bodies are REDACTED before logging (jwt / Token values replaced —
 *      agent1's baseline logged them in full; this script does not).
 *   B. LUA (probe driver, same harness pattern as agent3's caps script):
 *      hooks lua_pcall in liblua.so, captures the game's lua_State, and
 *      runs Lua chunks via luaL_loadstring + lua_pcall with strict stack
 *      discipline + a re-entrancy guard. One bootstrap chunk wraps
 *      netProtocol.action (logs the game payload, applies the forge table)
 *      and exposes DYNREA.call / DYNREA.status / DYNREA.forge. A sequencer
 *      then fires ONE probe step per tick (15 s) — baseline reads, unforged
 *      one-key calls, then forged-count calls — gated on VipLv==16 (proves
 *      home entry + the v4 force is live, so probes never fire mid-story).
 *
 * Forge = numeric-field overrides ONLY (cTime / IsFree / Num / ItemCount /
 * SilverNum / RecoverTimes / UseNum) on actions the client already sends.
 * Investigation ONLY. Fresh/throwaway account only. NO purchases, NO forged
 * Play receipts, NO purchase fraud, NO exploit/grant mechanism. If a
 * server-trust gap is PROVEN, the log shows it and the script STOPS there.
 *
 * Output: console.log lines (frida.log via `frida -o`) + Lua print() lines
 * (logcat, tag Corona) — both prefixed [DYNREA] / [DYNREA2]. Bodies are
 * truncated with an explicit [TRUNCATED total=N] marker.
 * If Lua injection never succeeds, probe steps are SKIPPED with a clear log
 * line and the run still yields the traffic capture (layer A).
 */
'use strict';

/* ============================== config ============================== */
var MAX_BODY_CHARS = 6000;        // per-body log cap (target actions' bodies are small, well under this)
var MAX_HEX_BYTES = 256;
var TICK_MS = 15000;              // probe sequencer tick
var SOAK_GATE_VIP = 16;           // probes start only when VipLv reads 16
var TARGET_ACTIONS = {
  10401: 1, 10605: 1, 10211: 1, 10703: 1, 12005: 1, 10001: 1, 10807: 1,
  16340: 1, 16342: 1, 10602: 1, 10603: 1, 10604: 1, 10206: 1, 10002: 1,
  12004: 1, 12001: 1, 11514: 1, 10000: 1
};

/* ============================== logging ============================= */
var seq = 0;
function ts() { return new Date().toISOString(); }
function log(tag, msg) {
  seq += 1;
  try { console.log('[DYNREA][' + ts() + '][#' + seq + '][' + tag + '] ' + msg); }
  catch (e) { /* never let logging kill the game */ }
}

/* Redact live session secrets from any text BEFORE it is logged.
 * The outer envelope carries "jwt" and the inner payload "Token"; keep only
 * the length so a reader can tell a value was present. */
function redact(text) {
  if (!text || typeof text !== 'string') return text;
  try {
    return text
      .replace(/("jwt"\s*:\s*")[^"]*(")/g, '$1<REDACTED-JWT>$2')
      .replace(/("Token"\s*:\s*")[^"]*(")/g, '$1<REDACTED>$2')
      .replace(/("Sess"\s*:\s*")[^"]*(")/g, '$1<REDACTED>$2');
  } catch (e) { return text; }
}

function decodeBytes(bytes, cap) {
  var out = { text: '', truncated: false, total: 0, printable: false };
  try {
    if (!bytes) return out;
    var len = bytes.length;
    out.total = len;
    if (len === 0) return out;
    var n = Math.min(len, cap || MAX_BODY_CHARS);
    var slice = [];
    for (var i = 0; i < n; i++) slice.push(bytes[i]);
    var jarr = Java.array('byte', slice);
    var s = Java.use('java.lang.String').$new(jarr, 'UTF-8');
    out.text = s;
    out.truncated = len > n;
    var printable = 0, checked = Math.min(s.length, 500);
    for (var j = 0; j < checked; j++) {
      var c = s.charCodeAt(j);
      if ((c >= 0x20 && c <= 0x7e) || c === 0x09 || c === 0x0a || c === 0x0d || c >= 0x80) printable++;
    }
    out.printable = checked === 0 || (printable / checked) > 0.95;
    if (!out.printable) out.text = hexPreview(bytes, Math.min(len, MAX_HEX_BYTES));
    if (out.truncated) out.text += '\n...[TRUNCATED total=' + len + ' bytes]';
  } catch (e) {
    out.text = '<decode-error: ' + e + '>';
  }
  return out;
}

function hexPreview(bytes, n) {
  var h = '';
  for (var i = 0; i < n; i++) {
    var v = bytes[i] & 0xff;
    h += (v < 16 ? '0' : '') + v.toString(16);
    if (i % 16 === 15) h += '\n';
    else h += ' ';
  }
  return '<non-utf8 hex first ' + n + ' bytes>\n' + h;
}

/* Pull an action id out of a plaintext JSON body, if present. Handles both
 * the outer envelope {"data":"{...inner...}"} and a bare inner object. */
function extractAction(text) {
  try {
    var obj = JSON.parse(text);
    if (obj && typeof obj === 'object') {
      var id = obj.actionid || obj.ActId || obj.actionId || obj.action || obj.ActionId;
      if (id !== undefined && id !== null) return String(id);
      if (typeof obj.data === 'string') {
        try {
          var inner = JSON.parse(obj.data);
          var id2 = inner.actionid || inner.ActId || inner.actionId;
          if (id2 !== undefined && id2 !== null) return String(id2);
        } catch (e2) { /* inner not JSON */ }
      } else if (obj.data && typeof obj.data === 'object') {
        var d = obj.data;
        var id3 = d.actionid || d.ActId || d.actionId;
        if (id3 !== undefined && id3 !== null) return String(id3);
      }
    }
  } catch (e) { /* not JSON — fine */ }
  return null;
}

function logBody(tag, dirLabel, dec, state) {
  var action = dec.printable ? extractAction(dec.text) : null;
  var line = dirLabel + ' len=' + dec.total + ' state=' + state;
  if (dec.truncated) line += ' TRUNCATED';
  if (action !== null) line += ' action=' + action + (TARGET_ACTIONS[action] ? ' [TARGET]' : '');
  log(tag, line + '\n' + redact(dec.text));
  if (action !== null) {
    log('ACTION', 'id=' + action + ' ' + dirLabel + ' len=' + dec.total +
      (TARGET_ACTIONS[action] ? ' [TARGET]' : ''));
  }
  return action;
}

/* ==================== layer A: KSecure traffic hooks ==================== */
var hooksAttached = {};

/* Wire-level forge (SECONDARY, normally OFF). Armed only if the Lua layer
 * never comes up: rewrites the inner `data` JSON of an OUT request before
 * flip() encrypts it. Lua-level forge is primary; this exists so a run
 * without Lua still has a forge path for game-driven requests. */
var wireForge = {};   /* actionId -> {field: value, ...} */
var luaOk = false;    /* set true once the Lua wrapper is installed */

function applyWireForge(plainText) {
  /* plainText = outer envelope JSON string. Returns {text, forged} — the
   * (possibly) rewritten envelope, or the original on any failure. */
  try {
    var outer = JSON.parse(plainText);
    if (!outer || typeof outer.data !== 'string') return { text: plainText, forged: false };
    var inner = JSON.parse(outer.data);
    var aid = inner.actionid || inner.ActId;
    var spec = wireForge[aid];
    if (!spec) return { text: plainText, forged: false };
    var before = JSON.stringify(inner);
    for (var k in spec) inner[k] = spec[k];
    outer.data = JSON.stringify(inner);
    var after = JSON.stringify(outer);
    log('FORGE-WIRE', 'action=' + aid + ' rewrote request\nBEFORE-INNER: ' + before +
      '\nAFTER-INNER: ' + JSON.stringify(inner));
    return { text: after, forged: true };
  } catch (e) {
    log('FORGE-WIRE', 'forge failed (sending original): ' + e);
    return { text: plainText, forged: false };
  }
}

function hookFlip() {
  try {
    var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
    var flip = KSV.flip.overload('com.dc.angry.plugin_libs_ksc.KSNetMeta');
    flip.implementation = function (meta) {
      var dir = 0, ct = 0, stateBefore = -1;
      var inDec = { text: '', total: 0, truncated: false, printable: false };
      try { dir = meta.dir.value; } catch (e) {}
      try { ct = meta.ct.value; } catch (e) {}
      try { stateBefore = meta.state.value; } catch (e) {}
      try { inDec = decodeBytes(meta.dt.value, MAX_BODY_CHARS); } catch (e) {}
      var dirLabel = (dir === 1) ? 'OUT' : (dir === 0 ? 'IN' : 'DIR' + dir);
      if (dir === 1) {
        var plainLabel = 'REQ-PLAIN';
        var action = logBody('flip', plainLabel + ' dir=' + dirLabel + ' ct=' + ct, inDec, stateBefore);
        /* Wire forge: only when Lua is unavailable, and only for OUT. */
        if (!luaOk && action !== null && wireForge[action] && inDec.printable) {
          var res = applyWireForge(inDec.text);
          if (res.forged) {
            try {
              var bytes = [];
              var utf8 = Java.use('java.lang.String').$new(res.text).getBytes('UTF-8');
              for (var i = 0; i < utf8.length; i++) bytes.push(utf8[i]);
              meta.dt.value = Java.array('byte', bytes);
              log('FORGE-WIRE', 'action=' + action + ' dt replaced, new_len=' + bytes.length);
            } catch (e2) {
              log('FORGE-WIRE', 'dt replace FAILED, sending original: ' + e2);
            }
          }
        }
      }
      var ret;
      try {
        ret = flip.call(this, meta);
      } catch (e) {
        log('flip', 'ORIGINAL flip() THREW dir=' + dirLabel + ' ct=' + ct + ' err=' + e);
        throw e;
      }
      var stateAfter = -1, outDec = { text: '', total: 0, truncated: false, printable: false };
      try { stateAfter = meta.state.value; } catch (e) {}
      try { outDec = decodeBytes(meta.dt.value, MAX_BODY_CHARS); } catch (e) {}
      if (dir === 0) logBody('flip', 'RESP-PLAIN dir=' + dirLabel + ' ct=' + ct, outDec, stateAfter);
      else log('flip', 'OUT ct=' + ct + ' state=' + stateAfter + ' cipher_len=' + outDec.total);
      return ret;
    };
    hooksAttached.flip = true;
    log('init', 'hook attached: KSecureValidation.flip(KSNetMeta)');
  } catch (e) {
    log('init', 'hook FAILED (will retry): KSecureValidation.flip err=' + e);
  }
}

function hookFlip2() {
  try {
    var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
    var flip2 = KSV.flip2.overload('[B');
    flip2.implementation = function (input) {
      var inDec = decodeBytes(input, MAX_BODY_CHARS);
      var ret = flip2.call(this, input);
      var outDec = decodeBytes(ret, MAX_BODY_CHARS);
      if (inDec.printable) logBody('flip2', 'IN-PLAIN', inDec, '?');
      if (outDec.printable) logBody('flip2', 'OUT-PLAIN', outDec, '?');
      if (!inDec.printable && !outDec.printable) {
        log('flip2', 'both sides non-utf8 in_len=' + inDec.total + ' out_len=' + outDec.total);
      }
      return ret;
    };
    hooksAttached.flip2 = true;
    log('init', 'hook attached: KSecureValidation.flip2([B)[B');
  } catch (e) {
    log('init', 'hook FAILED (will retry): KSecureValidation.flip2 err=' + e);
  }
}

function hookIntercept() {
  try {
    var KSInterceptor = Java.use('com.dc.angry.plugin_libs_ksc.interceptor.KSInterceptor');
    var intercept = KSInterceptor.intercept.overload('okhttp3.Interceptor$Chain');
    intercept.implementation = function (chain) {
      var url = '?', encType = '-', reqBodyInfo = 'no-body', reqBodyDec = null;
      try {
        var req = chain.request();
        url = req.url().toString();
        var headers = req.headers();
        var h = headers.get('Gw-Encrypt-Type');
        if (h) encType = h;
        var body = req.body();
        if (body) {
          var Buffer = Java.use('okio.Buffer');
          var buf = Buffer.$new();
          body.writeTo(buf);
          var bytes = buf.readByteArray();
          reqBodyInfo = 'len=' + bytes.length;
          reqBodyDec = decodeBytes(bytes, MAX_BODY_CHARS);
        }
      } catch (e) {
        reqBodyInfo = 'read-error: ' + e;
      }
      log('http', 'REQ url=' + url + ' Gw-Encrypt-Type=' + encType + ' body ' + reqBodyInfo);
      if (reqBodyDec && reqBodyDec.printable) {
        log('http', 'REQ-BODY url=' + url + '\n' + redact(reqBodyDec.text));
        var action = extractAction(reqBodyDec.text);
        if (action !== null) log('ACTION', 'id=' + action + ' dir=OUT url=' + url);
      }
      var resp = intercept.call(this, chain);
      try {
        var code = resp.code();
        var respEnc = resp.header('Gw-Encrypt-Type');
        var clen = -1;
        try { clen = resp.body().contentLength(); } catch (e2) {}
        log('http', 'RESP url=' + url + ' code=' + code + ' Gw-Encrypt-Type=' + (respEnc || '-') + ' contentLength=' + clen);
      } catch (e) {
        log('http', 'RESP url=' + url + ' (post-log error: ' + e + ')');
      }
      return resp;
    };
    hooksAttached.intercept = true;
    log('init', 'hook attached: KSInterceptor.intercept(Chain)');
  } catch (e) {
    log('init', 'hook FAILED (will retry): KSInterceptor.intercept err=' + e);
  }
}

function hookLifecycle() {
  try {
    var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
    try {
      var init = KSV.init.overload('android.content.Context');
      init.implementation = function (ctx) {
        log('lifecycle', 'KSecureValidation.init(Context) called');
        return init.call(this, ctx);
      };
      hooksAttached.init = true;
      log('init', 'hook attached: KSecureValidation.init(Context)');
    } catch (e) { log('init', 'hook FAILED: KSecureValidation.init err=' + e); }
    try {
      var enable = KSV.enable.overload('java.lang.String');
      enable.implementation = function (s) {
        var len = -1;
        try { len = s.length; } catch (e2) {}
        log('lifecycle', 'KSecureValidation.enable(String) called arg_len=' + len);
        return enable.call(this, s);
      };
      hooksAttached.enable = true;
      log('init', 'hook attached: KSecureValidation.enable(String)');
    } catch (e) { log('init', 'hook FAILED: KSecureValidation.enable err=' + e); }
  } catch (e) {
    log('init', 'hook FAILED (will retry): KSecureValidation lifecycle err=' + e);
  }
}

var tries = 0;
function tryHookAll() {
  tries += 1;
  if (!hooksAttached.flip) hookFlip();
  if (!hooksAttached.flip2) hookFlip2();
  if (!hooksAttached.intercept) hookIntercept();
  if (!hooksAttached.init || !hooksAttached.enable) hookLifecycle();
  var done = hooksAttached.flip && hooksAttached.flip2 && hooksAttached.intercept;
  if (done) {
    log('init', 'ALL PRIMARY HOOKS ATTACHED after ' + tries + ' attempt(s)');
  } else if (tries < 24) {
    log('init', 'attempt ' + tries + ': hooks pending (flip=' + !!hooksAttached.flip +
      ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
      ') — retrying in 5s (class may not be loaded yet)');
    setTimeout(tryHookAll, 5000);
  } else {
    log('init', 'GIVING UP after 24 attempts: flip=' + !!hooksAttached.flip +
      ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
      ' — see errors above; traffic capture NOT VERIFIED');
  }
}

/* ==================== layer B: Lua probe driver ==================== */
/* liblua.so exports the full Lua 5.1 C API (verified on the APK's own
 * liblua.so: lua_pcall, luaL_loadstring, lua_gettop, lua_settop). The game
 * calls lua_pcall constantly, so hooking it captures the game's lua_State
 * even when attaching after launch. Stack discipline: every probe saves
 * lua_gettop, runs its chunk, restores lua_settop — on every path,
 * including loadstring failure. A re-entrancy guard skips the tick while
 * a probe chunk is running (the chunk's own pcall re-enters this hook). */

var lua_pcall = null, luaL_loadstring = null, lua_gettop = null, lua_settop = null;
var lua_getfield = null, lua_toboolean = null, lua_type = null;
var luaState = null;
var inProbe = false;
var luaInstalled = false;
var lastTickMs = 0;
var gatePassSeen = false;

/* Read a boolean out of the Lua state: _G[table][key]. Uses the Lua 5.1 C
 * API directly (lua_getfield + lua_toboolean), with stack discipline.
 * LUA_GLOBALSINDEX = -10002, LUA_TBOOLEAN = 1. */
function luaGlobalBool(L, table, key) {
  var top0 = lua_gettop(L);
  try {
    lua_getfield(L, -10002, table);
    if (lua_type(L, -1) !== 5) return false; /* 5 = LUA_TTABLE */
    lua_getfield(L, -1, key);
    var v = lua_toboolean(L, -1) === 1;
    return v;
  } catch (e) {
    return false;
  } finally {
    try { lua_settop(L, top0); } catch (e2) {}
  }
}

/* Run one Lua chunk string on the captured state. Returns {ok, err}. */
function runLua(L, chunk) {
  if (inProbe) return { ok: false, err: 're-entrant' };
  inProbe = true;
  var top0 = -1;
  try {
    top0 = lua_gettop(L);
    var cstr = Memory.allocUtf8String(chunk);
    var loadStatus = luaL_loadstring(L, cstr);
    if (loadStatus !== 0) {
      lua_settop(L, top0);
      return { ok: false, err: 'loadstring status=' + loadStatus };
    }
    var callStatus = lua_pcall(L, 0, 0, 0);
    lua_settop(L, top0);
    if (callStatus !== 0) return { ok: false, err: 'pcall status=' + callStatus };
    return { ok: true };
  } catch (e) {
    try { if (top0 >= 0) lua_settop(L, top0); } catch (e2) {}
    return { ok: false, err: 'exception: ' + e };
  } finally {
    inProbe = false;
  }
}

/* Bootstrap chunk: wraps netProtocol.action (+actionForCross) and exposes
 * the DYNREA probe API. Runs ONCE, the first tick where `netProtocol`
 * exists as a table. The wrapper logs the game payload (no secrets — the
 * envelope fields Sess/Token are added later by generateNormalParams),
 * applies DYNREA.forge overrides, and wraps callbacks to log the response.
 * All logging goes through Lua print() -> logcat [DYNREA2-*] lines. */
var BOOTSTRAP_LUA = [
  'if _G.DYNREA2 and _G.DYNREA2.installed then return end',
  'local np = netProtocol',
  'if type(np) ~= "table" or type(np.action) ~= "function" then',
  '  print("[DYNREA2-BOOT] netProtocol.action not ready")',
  '  return',
  'end',
  'local json = json',
  'local function redactedCopy(t)',
  '  local c = {}',
  '  for k, v in pairs(t) do c[k] = v end',
  '  c.Token = nil c.Sess = nil',
  '  return c',
  'end',
  '_G.DYNREA2 = { installed = true, forge = {}, lastResp = {} }',
  'local origAction = np.action',
  'local origCross = np.actionForCross',
  'local function wrap(orig, actionId, dataTable, cb, errCb)',
  '  local payload = redactedCopy(dataTable or {})',
  '  local f = _G.DYNREA2.forge[actionId]',
  '  if f then',
  '    for k, v in pairs(f) do dataTable[k] = v end',
  '    print("[DYNREA2-FORGE] action=" .. tostring(actionId) .. " applied " .. json.encode(f) .. " -> payload " .. json.encode(redactedCopy(dataTable)))',
  '  end',
  '  print("[DYNREA2-REQ] action=" .. tostring(actionId) .. " payload=" .. json.encode(payload))',
  '  local function cbWrap(respond)',
  '    _G.DYNREA2.lastResp[actionId] = respond',
  '    local s = "<unencodable>"',
  '    local ok, enc = pcall(json.encode, respond)',
  '    if ok then s = enc end',
  '    if #s > 12000 then s = string.sub(s, 1, 12000) .. "...[TRUNCATED total=" .. #s .. "]" end',
  '    print("[DYNREA2-RESP] action=" .. tostring(actionId) .. " code=" .. tostring(respond and respond.Code) .. " body=" .. s)',
  '    if cb then cb(respond) end',
  '  end',
  '  local function errWrap(respond)',
  '    print("[DYNREA2-ERR] action=" .. tostring(actionId) .. " body=" .. tostring(respond and json.encode(respond) or "nil"))',
  '    if errCb then errCb(respond) end',
  '  end',
  '  return orig(actionId, dataTable, cbWrap, errWrap)',
  'end',
  'np.action = function(actionId, dataTable, cb, errCb) return wrap(origAction, actionId, dataTable, cb, errCb) end',
  'if type(origCross) == "function" then',
  '  np.actionForCross = function(actionId, dataTable, cb, errCb) return wrap(origCross, actionId, dataTable, cb, errCb) end',
  'end',
  'function _G.DYNREA2.status()',
  '  local ok, err = pcall(function()',
  '    local vip = modManager.roleMod.getRoleData("VipLv")',
  '    local row = modManager.dataMod.filterTcData("TcVIP", {Level = vip}, 1)',
  '    local td = modManager.dataMod.getTbData()',
  '    local rd = td and td.RoleData or {}',
  '    local now = modManager.dataMod.getNowTime()',
  '    local cd = modManager.dataMod.getEnvCfg("VigorCd") or 1800',
  '    local maxV = row and row.MaxVigor or -1',
  '    local legit = 0',
  '    if rd.VigorTimeUnix and now then',
  '      legit = math.min(math.floor((now - rd.VigorTimeUnix) / cd), maxV)',
  '      if rd.VigorCount and maxV <= rd.VigorCount then legit = rd.VigorCount end',
  '    end',
  '    print("[DYNREA2-STATUS] vip=" .. tostring(vip)',
  '      .. " maxVigor=" .. tostring(maxV)',
  '      .. " transfer=" .. tostring(row and row.TransferNum)',
  '      .. " maxVitality=" .. tostring(row and row.MaxVitality)',
  '      .. " vigorCount=" .. tostring(rd.VigorCount)',
  '      .. " vigorTimeUnix=" .. tostring(rd.VigorTimeUnix)',
  '      .. " now=" .. tostring(now)',
  '      .. " vigorCd=" .. tostring(cd)',
  '      .. " legitCtime=" .. tostring(legit))',
  '  end)',
  '  if not ok then print("[DYNREA2-STATUS] ERROR " .. tostring(err)) end',
  'end',
  'print("[DYNREA2-BOOT] wrapper installed on netProtocol.action")',
].join('\n');

/* One probe step = one self-contained Lua chunk. Each chunk pcalls its
 * module call and prints PROBE-STEP / PROBE-RESULT lines. The flip hook
 * (layer A) independently logs the full wire request + response, which is
 * the evidence that decides each verdict — the Lua prints are the index. */
var PROBE_STEPS = [
  { id: 'S0-status', lua: '_G.DYNREA2.status()' },
  { id: 'S1-visit-data-10602', lua: [
    'print("[DYNREA2-PROBE-STEP] S1-visit-data-10602 (read-only fetch)")',
    'local ok, err = pcall(modManager._findMod.action10602, function()',
    '  print("[DYNREA2-PROBE-RESULT] S1-visit-data-10602 done (see [DYNREA2-RESP] 10602 for VisitData.Vitality/TransferNum)")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S1-visit-data-10602 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S2-wife-call-10401-legit', lua: [
    'print("[DYNREA2-PROBE-STEP] S2-wife-call-10401-legit (cTime = getCallTimes(), unforged)")',
    'local ok, err = pcall(modManager._wivesMod.action10401, function(o)',
    '  print("[DYNREA2-PROBE-RESULT] S2-wife-call-10401-legit beautyId=" .. tostring(o and o.beautyId) .. " miracle=" .. tostring(o and o.miracleTrigger) .. " (full body in [DYNREA2-RESP] 10401: VigorCount/VigorTimeUnix after)")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S2-wife-call-10401-legit LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S3-onekey-visit-10605', lua: [
    'print("[DYNREA2-PROBE-STEP] S3-onekey-visit-10605 (IsFree=1, Num=remaining transfers; v4-normal)")',
    'local ok, err = pcall(function()',
    '  local fd = modManager._findMod.getFindData()',
    '  local num = (fd and fd.transferNum and fd.transferNum > 0) and fd.transferNum or 7',
    '  modManager._findMod.action10605({IsFree = 1, Num = num}, function(r)',
    '    print("[DYNREA2-PROBE-RESULT] S3-onekey-visit-10605 num=" .. tostring(num) .. " respond.TransferNum=" .. tostring(r and r.TransferNum))',
    '  end)',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S3-onekey-visit-10605 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S4-onekey-sweep-10211', lua: [
    'print("[DYNREA2-PROBE-STEP] S4-onekey-sweep-10211 (v4-normal, gParent=nil)")',
    'local ok, err = pcall(modManager._stageMod.action10211, nil, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S4-onekey-sweep-10211 section=" .. tostring(r and r.SectionRecord and r.SectionRecord.SectionId))',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S4-onekey-sweep-10211 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S5-onekey-government-10703', lua: [
    'print("[DYNREA2-PROBE-STEP] S5-onekey-government-10703 (select=nil, EnterType=2 — privilege-card values)")',
    'local ok, err = pcall(modManager._governmentMod.actionOneKeyGovernment, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S5-onekey-government-10703 awards=" .. tostring(r and r.AllAwardList and #r.AllAwardList))',
    'end, nil, 2)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S5-onekey-government-10703 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S6-onekey-tribute-12005', lua: [
    'print("[DYNREA2-PROBE-STEP] S6-onekey-tribute-12005 (EnterType=2)")',
    'local ok, err = pcall(modManager._tributeMod.action12005, {EnterType = 2}, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S6-onekey-tribute-12005 done")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S6-onekey-tribute-12005 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S7-onekey-levy-10001', lua: [
    'print("[DYNREA2-PROBE-STEP] S7-onekey-levy-10001 (collectType=4, enterType=2 — privilege-card values)")',
    'local ok, err = pcall(modManager._manageAssetsMod.action10001, {collectType = 4, enterType = 2}, function(m, r)',
    '  print("[DYNREA2-PROBE-RESULT] S7-onekey-levy-10001 miracle=" .. tostring(m))',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S7-onekey-levy-10001 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S8-onekey-court-10807', lua: [
    'print("[DYNREA2-PROBE-STEP] S8-onekey-court-10807 netMultiAward (empty params)")',
    'local ok, err = pcall(modManager._courtMod.netMultiAward, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S8-onekey-court-10807 done")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S8-onekey-court-10807 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S9-pet-preview-16340', lua: [
    'print("[DYNREA2-PROBE-STEP] S9-pet-preview-16340 (read-only preview)")',
    'local ok, err = pcall(modManager.petMod.actionOneKeyFightRewardPreview, function()',
    '  print("[DYNREA2-PROBE-RESULT] S9-pet-preview-16340 done")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S9-pet-preview-16340 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S10-pet-claim-16342', lua: [
    'print("[DYNREA2-PROBE-STEP] S10-pet-claim-16342 (EnterType=2, IsEnjoyPrivilege=false)")',
    'local ok, err = pcall(modManager.petMod.actionOneKeyFightReward, {EnterType = 2, IsEnjoyPrivilege = false}, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S10-pet-claim-16342 done")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S10-pet-claim-16342 LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S11-wife-call-10401-FORGED-cTime19', lua: [
    'print("[DYNREA2-PROBE-STEP] S11-wife-call-10401-FORGED cTime=19 (server VigorCount is small — see S0/S2)")',
    '_G.DYNREA2.forge[10401] = { cTime = 19 }',
    'local ok, err = pcall(modManager._wivesMod.action10401, function(o)',
    '  print("[DYNREA2-PROBE-RESULT] S11-wife-call-10401-FORGED beautyId=" .. tostring(o and o.beautyId) .. " miracle=" .. tostring(o and o.miracleTrigger))',
    '  _G.DYNREA2.forge[10401] = nil',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S11-wife-call-10401-FORGED LUA-ERROR " .. tostring(err)) _G.DYNREA2.forge[10401] = nil end',
  ].join('\n') },
  { id: 'S12-visit-10605-FORGED-Num99', lua: [
    'print("[DYNREA2-PROBE-STEP] S12-visit-10605-FORGED IsFree=1 Num=99 (cap is 7 at VIP 16)")',
    '_G.DYNREA2.forge[10605] = { IsFree = 1, Num = 99 }',
    'local ok, err = pcall(modManager._findMod.action10605, {IsFree = 1, Num = 99}, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S12-visit-10605-FORGED respond.TransferNum=" .. tostring(r and r.TransferNum))',
    '  _G.DYNREA2.forge[10605] = nil',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S12-visit-10605-FORGED LUA-ERROR " .. tostring(err)) _G.DYNREA2.forge[10605] = nil end',
  ].join('\n') },
  { id: 'S13-vitality-item-10603-FORGED-99', lua: [
    'print("[DYNREA2-PROBE-STEP] S13-vitality-item-10603-FORGED ItemCount=99 (tests server item-ownership check)")',
    'local ok, err = pcall(modManager._findMod.action10603, 99, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S13-vitality-item-10603-FORGED respond.RecoverVitality=" .. tostring(r and r.RecoverVitality))',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S13-vitality-item-10603-FORGED LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S14-cannon-10206-FORGED-SilverNum', lua: [
    'print("[DYNREA2-PROBE-STEP] S14-cannon-10206-FORGED SilverNum=999999999 (tests server silver-balance check)")',
    'local ok, err = pcall(modManager._stageMod.action10206, 999999999, nil, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S14-cannon-10206-FORGED ArtilleryLv=" .. tostring(r and r.ArtilleryLv))',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S14-cannon-10206-FORGED LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S15-levy-recover-10002-FORGED-99', lua: [
    'print("[DYNREA2-PROBE-STEP] S15-levy-recover-10002-FORGED RecoverTimes=99 (tests server count/cost check)")',
    'local ok, err = pcall(modManager._manageAssetsMod.recover, 1, 99, function()',
    '  print("[DYNREA2-PROBE-RESULT] S15-levy-recover-10002-FORGED done")',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S15-levy-recover-10002-FORGED LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S16-tribute-use-12004-FORGED-99', lua: [
    'print("[DYNREA2-PROBE-STEP] S16-tribute-use-12004-FORGED CountryId=1 UseNum=99 (tests server count check)")',
    'local ok, err = pcall(modManager._tributeMod.action12004, {countryId = 1, useNum = 99, IsEnjoyPrivilege = false}, function(r)',
    '  print("[DYNREA2-PROBE-RESULT] S16-tribute-use-12004-FORGED HasMaidNum=" .. tostring(r and r.HasMaidNum))',
    'end)',
    'if not ok then print("[DYNREA2-PROBE-RESULT] S16-tribute-use-12004-FORGED LUA-ERROR " .. tostring(err)) end',
  ].join('\n') },
  { id: 'S17-status-after', lua: '_G.DYNREA2.status()' },
];

var stepIndex = -1;      /* -1 = gate not yet passed; >=0 = running steps */

/* One sequencer tick. Called from the lua_pcall hook (throttled). */
function tick(L) {
  try {
    if (!luaInstalled) {
      var r = runLua(L, BOOTSTRAP_LUA);
      if (r.ok) {
        /* Verify the wrapper really installed: DYNREA2.installed is only
         * set by the bootstrap chunk itself. */
        var r2 = runLua(L, 'if _G.DYNREA2 and _G.DYNREA2.installed then print("[DYNREA2-BOOT] verified installed") else print("[DYNREA2-BOOT] NOT installed (netProtocol not ready?)") end');
        if (r2.ok) {
          luaInstalled = true;
          luaOk = true;
          log('lua', 'bootstrap chunk ran; wrapper install verification queued (see logcat [DYNREA2-BOOT])');
        }
      } else {
        log('lua', 'bootstrap chunk FAILED: ' + r.err + ' (will retry next tick)');
      }
      return;
    }
    if (stepIndex === -1) {
      /* Gate: the probe chunk sets _G.DYNREA2.__gatePass = (vip == 16);
       * read it back through the C API. Probes NEVER fire before home
       * entry + the v4 force is live — firing 10401 mid-story could
       * corrupt the walk. If the gate never passes, steps never run and
       * the log says exactly why (see the [DYNREA2-GATE] prints). */
      var g = runLua(L, [
        'local ok, err = pcall(function()',
        '  local vip = modManager.roleMod.getRoleData("VipLv")',
        '  print("[DYNREA2-GATE] vip=" .. tostring(vip))',
        '  if _G.DYNREA2 then _G.DYNREA2.__gatePass = (vip == 16) end',
        'end)',
        'if not ok then print("[DYNREA2-GATE] ERROR " .. tostring(err)) end',
      ].join('\n'));
      if (!g.ok) { log('lua', 'gate chunk FAILED: ' + g.err); return; }
      gatePassSeen = luaGlobalBool(L, 'DYNREA2', '__gatePass');
      if (!gatePassSeen) {
        log('lua', 'gate NOT passed yet (VipLv ~= 16 — still in story/loading, or v4 force did not run); waiting for next tick');
        return;
      }
      stepIndex = 0;
      log('lua', 'GATE PASSED (VipLv==16 read back from Lua state) — starting probe steps');
      runLua(L, '_G.DYNREA2.status()');
      return;
    }
    if (stepIndex < PROBE_STEPS.length) {
      var step = PROBE_STEPS[stepIndex];
      log('probe', 'firing step ' + (stepIndex + 1) + '/' + PROBE_STEPS.length + ': ' + step.id);
      var res = runLua(L, step.lua);
      if (!res.ok) log('probe', 'step ' + step.id + ' CHUNK FAILED: ' + res.err);
      stepIndex += 1;
    } else if (stepIndex === PROBE_STEPS.length) {
      stepIndex += 1;
      log('probe', 'ALL PROBE STEPS FIRED (' + PROBE_STEPS.length + ' steps) — responses arrive via [DYNREA2-RESP] + flip RESP-PLAIN; see REPORT for verdict rules');
      try { runLua(L, '_G.DYNREA2.forge = {} print("[DYNREA2-PROBE] forge table cleared")'); } catch (e) {}
    }
  } catch (e) {
    log('lua', 'tick EXCEPTION: ' + e);
  }
}

function setupLua() {
  try {
    var mod = Process.findModuleByName('liblua.so');
    if (!mod) {
      log('lua', 'FATAL: liblua.so not loaded — Lua probe layer unavailable (traffic layer A still runs)');
      return;
    }
    lua_pcall = new NativeFunction(Module.getExportByName('liblua.so', 'lua_pcall'), 'int', ['pointer', 'int', 'int', 'int']);
    luaL_loadstring = new NativeFunction(Module.getExportByName('liblua.so', 'luaL_loadstring'), 'int', ['pointer', 'pointer']);
    lua_gettop = new NativeFunction(Module.getExportByName('liblua.so', 'lua_gettop'), 'int', ['pointer']);
    lua_settop = new NativeFunction(Module.getExportByName('liblua.so', 'lua_settop'), 'void', ['pointer', 'int']);
    lua_getfield = new NativeFunction(Module.getExportByName('liblua.so', 'lua_getfield'), 'void', ['pointer', 'int', 'pointer']);
    lua_toboolean = new NativeFunction(Module.getExportByName('liblua.so', 'lua_toboolean'), 'int', ['pointer', 'int']);
    lua_type = new NativeFunction(Module.getExportByName('liblua.so', 'lua_type'), 'int', ['pointer', 'int']);
    Interceptor.attach(lua_pcall, {
      onEnter: function (args) {
        try {
          var L = args[0];
          if (!luaState) {
            luaState = L;
            log('lua', 'captured lua_State=' + L + ' from lua_pcall');
          }
          var now = Date.now();
          if (!inProbe && luaState && now - lastTickMs >= TICK_MS) {
            lastTickMs = now;
            tick(luaState);
          }
        } catch (e) { /* never break the game's own pcall */ }
      }
    });
    log('init', 'hook attached: lua_pcall (liblua.so) — probe tick every ' + (TICK_MS / 1000) + 's');
    hooksAttached.lua = true;
  } catch (e) {
    log('lua', 'setup FAILED: ' + e + ' — Lua probe layer unavailable (traffic layer A still runs)');
  }
}

/* ============================== RPC (manual driving) ============================== */
rpc.exports = {
  /* Arm a wire-level forge (used only if Lua is unavailable). */
  wireforge: function (actionId, fieldsJson) {
    try {
      wireForge[actionId] = JSON.parse(fieldsJson);
      return 'wire forge armed for ' + actionId + ': ' + fieldsJson;
    } catch (e) { return 'wireforge error: ' + e; }
  },
  clearwireforge: function () {
    wireForge = {};
    return 'wire forge cleared';
  },
  status: function () {
    return JSON.stringify({
      luaState: luaState ? String(luaState) : null,
      luaInstalled: luaInstalled, luaOk: luaOk,
      stepIndex: stepIndex, stepsTotal: PROBE_STEPS.length,
      hooks: hooksAttached, wireForge: wireForge,
    });
  },
  /* Run an arbitrary Lua chunk on the captured state (manual probes). */
  runlua: function (chunk) {
    if (!luaState) return 'no lua_State captured yet';
    var r = runLua(luaState, chunk);
    return JSON.stringify(r);
  },
};

/* ============================== boot ============================== */
Java.perform(function () {
  log('init', 'dynrea agent2 script loaded; pid=' + Process.id + ' arch=' + Process.arch);
  tryHookAll();
  setupLua();
  log('init', 'agent2 ready: traffic layer A (flip/flip2/intercept) + Lua probe layer B (lua_pcall tick ' + (TICK_MS / 1000) + 's, ' + PROBE_STEPS.length + ' steps, gate VipLv==16)');
});

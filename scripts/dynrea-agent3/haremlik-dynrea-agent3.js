// dynrea agent3 — Haremlik (com.dc.hwsj 7.804) COMBINED probe:
//   (A) plaintext gateway traffic via KSecureValidation.flip / flip2 / intercept
//   (B) live VIP-caps probe inside the game's Lua state via liblua.so lua_pcall
//
// (A) WHY flip() IS SUFFICIENT (verified statically, 2026-11-15):
//  * netAdapter.encrypt(data) in the shipped CAR is the IDENTITY function
//    (sdkAdapter/netAdapter.lua: `function M.encrypt(data) return data end`)
//    and decrypt_decompress() is a no-op — NO Lua-side encryption exists.
//  * netSendMod.httpRequest posts json.encode({version="1.8",
//    data=json.encode(sendData), server_id, app_id}) with the inner `data`
//    field in PLAINTEXT; KSInterceptor reads that body and calls flip()
//    (dir=OUT=1) to encrypt it, and flip() (dir=IN=0) to decrypt responses.
//  * KSNetMeta.dir: enum a/c {a="IN"(0), b="OUT"(1)}; request ctor ([B) -> OUT,
//    response ctor ([B,J) -> IN (smali-verified). state=0 means the crypto op
//    succeeded. So in flip(): dir==OUT on ENTRY => plaintext REQUEST;
//    dir==IN on RETURN => plaintext RESPONSE. Full JSON both ways.
//  * mitmproxy alone sees only ChaCha20 ciphertext; this hook sees plaintext.
//
// (B) WHY A LUA PROBE: the caps live in Lua tables (roleMod.tbRoleData.VipLv,
// TcVIP rows via dataMod.filterTcData); no Java field mirrors them. The probe
// re-evaluates the EXACT expressions the game uses. Limits (static, not bugs):
//  * _wivesMod.get_max_vigor() and _childrenMod.get_max_energy() are
//    MODULE-LOCAL (not M.*) — not callable externally; their bodies are exactly
//    the TcVIP row lookups the probe performs (+ a minister-treasure bonus for
//    children energy, additive, unmeasured here).
//  * findLogic.getMaxVitality(vipLv) IS exported (M.*) and IS called live:
//    returns TcVIP.MaxVitality + treasure bonus, so >19 means the bonus applied.
//  * Wife vigor / visit vitality CURRENT values are server-synced: live
//    RoleData.VigorCount/VigorTimeUnix (dataMod) and the 10602/10604 response
//    VisitData.Vitality (traffic hook). findData itself is module-local.
//
// SECRETS: Sess/Token/JWT values are REDACTED before logging (key-name match,
// recursive). KSecureValidation.enable()'s argument is never logged (length
// only). Bodies are truncated (6000 chars; 20000 for 18281/18283) with an
// explicit marker. No request is sent, modified, replayed or forged.
// OBSERVE ONLY. No purchases, no forged receipts, no grant mechanism.
// No ResponseBody is ever read in the intercept hook (single-use).
//
// USAGE: FRIDA_SCRIPT=scripts/frida/haremlik-dynrea-agent3.js on the dynrea
// infra (agent1 READY.md). Emits [DYNREA] lines via send() (frida.log) and
// mirrors the init/attach sentinels to console.log. The harness greps
// frida.log for "ALL PRIMARY HOOKS ATTACHED".

'use strict';

var MAX_BODY_CHARS = 6000;
var MAX_TARGET_CHARS = 20000; // 18281/18283 bodies only (small, grant-relevant)
var TARGET_ACTIONS = { 18281: 1, 18283: 1, 10401: 1, 10602: 1, 10604: 1, 11514: 1 };
var seq = 0;

function ts() { return new Date().toISOString(); }
function log(tag, msg) {
    seq += 1;
    var line = '[DYNREA][' + ts() + '][#' + seq + '][' + tag + '] ' + msg;
    try { send(line); } catch (e) {}
    try { console.log(line); } catch (e2) {}
}

var SECRET_KEY = /^(sess|token|jwt|authorization|password|secret|access_?token|refresh_?token)$/i;
function redact(obj, depth) {
    if (depth > 4) return obj;
    if (obj && typeof obj === 'object') {
        var out = Array.isArray(obj) ? [] : {};
        for (var k in obj) {
            if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
            if (SECRET_KEY.test(k)) out[k] = '<redacted>';
            else out[k] = redact(obj[k], depth + 1);
        }
        return out;
    }
    return obj;
}

function decodeBytes(bytes, cap) {
    var out = { text: '', truncated: false, total: 0, printable: false };
    try {
        if (!bytes) return out;
        var len = bytes.length;
        out.total = len;
        if (len === 0) return out;
        var n = Math.min(len, cap);
        var slice = [];
        for (var i = 0; i < n; i++) slice.push(bytes[i]);
        var jarr = Java.array('byte', slice);
        out.text = Java.use('java.lang.String').$new(jarr, 'UTF-8').toString();
        out.truncated = len > cap;
        var printable = 0, checked = Math.min(out.text.length, 500);
        for (var j = 0; j < checked; j++) {
            var c = out.text.charCodeAt(j);
            if ((c >= 0x20 && c <= 0x7e) || c === 0x09 || c === 0x0a || c === 0x0d || c >= 0x80) printable++;
        }
        out.printable = checked === 0 || (printable / checked) > 0.95;
        if (out.truncated) out.text += '\n...[TRUNCATED total=' + len + ' bytes]';
    } catch (e) { out.text = '<decode-error: ' + e + '>'; }
    return out;
}

// Parse a gateway body: outer {version, data:"<inner json>", ...}.
// Returns {actionId, inner, innerText} with secrets redacted in innerText.
function parseBody(text) {
    if (!text) return { actionId: null, inner: null, innerText: '' };
    try {
        var outer = JSON.parse(text);
        if (outer && typeof outer.data === 'string') {
            try {
                var inner = JSON.parse(outer.data);
                var id = inner.actionid || inner.ActId || null;
                return { actionId: id, inner: inner, innerText: JSON.stringify(redact(inner, 0)) };
            } catch (e) {
                return { actionId: null, inner: null, innerText: outer.data.slice(0, MAX_BODY_CHARS) };
            }
        }
        return { actionId: null, inner: outer, innerText: JSON.stringify(redact(outer, 0)).slice(0, MAX_BODY_CHARS) };
    } catch (e) {
        return { actionId: null, inner: null, innerText: text.slice(0, MAX_BODY_CHARS) };
    }
}

var lastReqByThread = {}; // OkHttp dispatcher threads handle one call at a time
// and flip() runs synchronously inside intercept(), so a RESP on thread T
// belongs to the last REQ seen on T. Response envelopes carry no actionid.
function emitAction(parsed, dir, tid) {
    var id = parsed.actionId;
    if (dir === 'REQ') {
        if (id !== null && id !== undefined) lastReqByThread[tid] = id;
    } else if (dir === 'RESP') {
        if ((id === null || id === undefined) && lastReqByThread[tid] !== undefined) {
            id = lastReqByThread[tid];
            delete lastReqByThread[tid];
        }
    }
    var idStr = (id === null || id === undefined) ? '?' : String(id);
    var cap = TARGET_ACTIONS[id] ? MAX_TARGET_CHARS : MAX_BODY_CHARS;
    var body = (parsed.innerText || '').slice(0, cap);
    if (parsed.innerText && parsed.innerText.length > cap) body += '\n...[TRUNCATED]';
    log('ACTION', 'id=' + idStr + ' dir=' + dir + ' thread=' + tid + ' len=' + (parsed.innerText || '').length + '\n' + body);
    if (id === 18281 || id === 18283) log('AD', dir + ' id=' + idStr + ' thread=' + tid + '\n' + body);
    // 10000 login snapshot: pull the server-side role facts out of the noise.
    if (id === 10000 && parsed.inner) {
        try {
            var d = parsed.inner.Data || parsed.inner.data || {};
            var rd = d.RoleData || d.roleData || {};
            var ri = d.RoleItem || [];
            log('SNAPSHOT', 'dir=' + dir + ' serverVipLv=' + rd.VipLv + ' vigorCount=' + rd.VigorCount +
                ' vigorTimeUnix=' + rd.VigorTimeUnix + ' roleItemEntries=' + (ri.length || 0));
        } catch (e) {}
    }
}

var hooksAttached = {};

function hookFlip() {
    try {
        var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
        var flip = KSV.flip.overload('com.dc.angry.plugin_libs_ksc.KSNetMeta');
        flip.implementation = function (meta) {
            var tid = Process.getCurrentThreadId();
            var dir = -1, ct = 0;
            try { dir = meta.dir.value; } catch (e) {}
            try { ct = meta.ct.value; } catch (e) {}
            var inText = '';
            try { inText = decodeBytes(meta.dt.value, MAX_TARGET_CHARS).text; } catch (e) {}
            if (dir === 1) emitAction(parseBody(inText), 'REQ', tid);
            var ret;
            try { ret = flip.call(this, meta); }
            catch (e) { log('flip', 'ORIGINAL flip() THREW dir=' + dir + ' ct=' + ct + ' err=' + e); throw e; }
            var stateAfter = -1;
            try { stateAfter = meta.state.value; } catch (e) {}
            if (stateAfter !== 0) log('flip', 'FLIP-ERR dir=' + dir + ' thread=' + tid + ' ct=' + ct + ' state=' + stateAfter);
            if (dir === 0) {
                var outText = '';
                try { outText = decodeBytes(meta.dt.value, MAX_TARGET_CHARS).text; } catch (e) {}
                emitAction(parseBody(outText), 'RESP', tid);
            } else {
                log('flip', 'OUT ct=' + ct + ' state=' + stateAfter);
            }
            return ret;
        };
        hooksAttached.flip = true;
        log('init', 'hook attached: KSecureValidation.flip(KSNetMeta)');
    } catch (e) { log('init', 'hook FAILED (will retry): flip err=' + e); }
}

function hookFlip2() {
    try {
        var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
        var flip2 = KSV.flip2.overload('[B');
        flip2.implementation = function (input) {
            var ret = flip2.call(this, input);
            var inDec = decodeBytes(input, 600);
            var outDec = decodeBytes(ret, 600);
            if (inDec.printable) log('flip2', 'IN-PLAIN len=' + inDec.total + '\n' + inDec.text);
            if (outDec.printable) log('flip2', 'OUT-PLAIN len=' + outDec.total + '\n' + outDec.text);
            if (!inDec.printable && !outDec.printable) log('flip2', 'both sides non-utf8 in_len=' + inDec.total + ' out_len=' + outDec.total);
            return ret;
        };
        hooksAttached.flip2 = true;
        log('init', 'hook attached: KSecureValidation.flip2([B)[B');
    } catch (e) { log('init', 'hook FAILED (will retry): flip2 err=' + e); }
}

function hookIntercept() {
    try {
        var KSInterceptor = Java.use('com.dc.angry.plugin_libs_ksc.interceptor.KSInterceptor');
        var intercept = KSInterceptor.intercept.overload('okhttp3.Interceptor$Chain');
        intercept.implementation = function (chain) {
            var url = '?', encType = '-', reqBodyInfo = 'no-body';
            try {
                var req = chain.request();
                url = req.url().toString();
                var h = req.headers().get('Gw-Encrypt-Type');
                if (h) encType = h;
                var body = req.body();
                if (body) {
                    var Buffer = Java.use('okio.Buffer');
                    var buf = Buffer.$new();
                    body.writeTo(buf);
                    reqBodyInfo = 'len=' + buf.readByteArray().length;
                }
            } catch (e) { reqBodyInfo = 'read-error: ' + e; }
            log('http', 'REQ url=' + url + ' Gw-Encrypt-Type=' + encType + ' body ' + reqBodyInfo);
            var resp = intercept.call(this, chain);
            try {
                log('http', 'RESP url=' + url + ' code=' + resp.code() + ' Gw-Encrypt-Type=' + (resp.header('Gw-Encrypt-Type') || '-'));
            } catch (e) { log('http', 'RESP url=' + url + ' (post-log error: ' + e + ')'); }
            return resp;
        };
        hooksAttached.intercept = true;
        log('init', 'hook attached: KSInterceptor.intercept(Chain)');
    } catch (e) { log('init', 'hook FAILED (will retry): intercept err=' + e); }
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
        } catch (e) { log('init', 'hook FAILED: init err=' + e); }
        try {
            var enable = KSV.enable.overload('java.lang.String');
            enable.implementation = function (s) {
                var len = -1;
                try { len = s.length; } catch (e2) {}
                log('lifecycle', 'KSecureValidation.enable(String) called arg_len=' + len + ' (value never logged)');
                return enable.call(this, s);
            };
            hooksAttached.enable = true;
            log('init', 'hook attached: KSecureValidation.enable(String)');
        } catch (e) { log('init', 'hook FAILED: enable err=' + e); }
    } catch (e) { log('init', 'hook FAILED (will retry): lifecycle err=' + e); }
}

// ---- (B) Lua caps probe ---------------------------------------------------
var PROBE_EVERY_MS = 25000;
var PROBE_LUA = [
    'local ok, err = pcall(function()',
    '  local vip = modManager.roleMod.getRoleData("VipLv")',
    '  local row = modManager.dataMod.filterTcData("TcVIP", {Level = vip}, 1)',
    '  local gv = nil',
    '  local ok2, fl = pcall(require, "scene.findScene.logic.findLogic")',
    '  if ok2 and fl and fl.getMaxVitality then',
    '    local ok3, v = pcall(fl.getMaxVitality, vip)',
    '    if ok3 then gv = v end',
    '  end',
    '  local td = modManager.dataMod.getTbData()',
    '  local rd = td and td.RoleData or {}',
    '  print("DYNREA3-CAPS vip=" .. tostring(vip)',
    '    .. " maxVigor=" .. tostring(row and row.MaxVigor)',
    '    .. " maxVitality=" .. tostring(row and row.MaxVitality)',
    '    .. " childMaxVitality=" .. tostring(row and row.ChildMaxVitality)',
    '    .. " transfer=" .. tostring(row and row.TransferNum)',
    '    .. " getMaxVitality=" .. tostring(gv)',
    '    .. " vigorCount=" .. tostring(rd.VigorCount)',
    '    .. " vigorTimeUnix=" .. tostring(rd.VigorTimeUnix)',
    '    .. " now=" .. tostring(modManager.dataMod.getNowTime()))',
    'end)',
    'if not ok then print("DYNREA3-CAPS ERROR " .. tostring(err)) end',
].join('\n');

var luaFns = null, inProbe = false, lastProbeMs = 0, probeRuns = 0;

function setupLua() {
    try {
        var lua = Process.findModuleByName('liblua.so');
        if (lua === null) { log('caps', 'liblua.so not loaded yet — will retry'); return false; }
        luaFns = {
            pcall: new NativeFunction(Module.getExportByName('liblua.so', 'lua_pcall'), 'int', ['pointer', 'int', 'int', 'int']),
            loadstring: new NativeFunction(Module.getExportByName('liblua.so', 'luaL_loadstring'), 'int', ['pointer', 'pointer']),
            gettop: new NativeFunction(Module.getExportByName('liblua.so', 'lua_gettop'), 'int', ['pointer']),
            settop: new NativeFunction(Module.getExportByName('liblua.so', 'lua_settop'), 'void', ['pointer', 'int'])
        };
        Interceptor.attach(luaFns.pcall, {
            onEnter: function (args) {
                if (inProbe) return;
                var now = Date.now();
                if (now - lastProbeMs < PROBE_EVERY_MS) return;
                lastProbeMs = now;
                inProbe = true;
                try {
                    var L = args[0];
                    var top0 = luaFns.gettop(L);
                    var ls = luaFns.loadstring(L, Memory.allocUtf8String(PROBE_LUA));
                    if (ls !== 0) { luaFns.settop(L, top0); log('caps', 'probe loadstring failed status=' + ls); return; }
                    var cs = luaFns.pcall(L, 0, 0, 0);
                    if (cs !== 0) { luaFns.settop(L, top0); log('caps', 'probe pcall failed status=' + cs); return; }
                    luaFns.settop(L, top0);
                    probeRuns++;
                    log('caps', 'probe run #' + probeRuns + ' ok (see DYNREA3-CAPS lines in logcat)');
                } catch (e) {
                    log('caps', 'probe exception: ' + e);
                    try { luaFns.settop(args[0], 0); } catch (e2) {}
                } finally { inProbe = false; }
            }
        });
        hooksAttached.lua = true;
        log('init', 'hook attached: liblua lua_pcall -> caps probe every ' + (PROBE_EVERY_MS / 1000) + 's');
        return true;
    } catch (e) {
        log('init', 'hook FAILED (will retry): lua caps err=' + e);
        return false;
    }
}

var tries = 0;
function tryHookAll() {
    tries += 1;
    if (!hooksAttached.flip) hookFlip();
    if (!hooksAttached.flip2) hookFlip2();
    if (!hooksAttached.intercept) hookIntercept();
    if (!hooksAttached.init || !hooksAttached.enable) hookLifecycle();
    if (!hooksAttached.lua) setupLua();
    var done = hooksAttached.flip && hooksAttached.flip2 && hooksAttached.intercept && hooksAttached.lua;
    if (done) {
        log('init', 'ALL PRIMARY HOOKS ATTACHED after ' + tries + ' attempt(s)');
    } else if (tries < 24) {
        log('init', 'attempt ' + tries + ': hooks pending (flip=' + !!hooksAttached.flip +
            ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
            ' lua=' + !!hooksAttached.lua + ') — retrying in 5s');
        setTimeout(tryHookAll, 5000);
    } else {
        log('init', 'GIVING UP after 24 attempts: flip=' + !!hooksAttached.flip +
            ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
            ' lua=' + !!hooksAttached.lua + ' — traffic/caps capture NOT VERIFIED');
    }
}

Java.perform(function () {
    log('init', 'dynrea agent3 combined script loaded; pid=' + Process.id + ' arch=' + Process.arch);
    tryHookAll();
});

// haremlik-dynrea-wireforge.js — Haremlik (com.dc.hwsj 7.804) JS-only wire forge.
//
// WHAT IT DOES
//   (A) Traffic layer: the proven agent-3 hooks (KSecureValidation.flip /
//       flip2 / KSInterceptor.intercept / init+enable lifecycle). Gateway
//       traffic is plaintext JSON over TLS; the crypto layer is dormant, so
//       flip() never fires and intercept() sees the real bodies.
//   (B) Session-template capture: from the first observed gameserver request
//       (and refreshed on EVERY later one) the script keeps, IN MEMORY ONLY,
//       the live request URL, headers, and envelope fields. Nothing from the
//       template is ever logged except key NAMES, a host name, and counts.
//   (C) Home-entry gate, checked in JS every 10 s. The sequencer arms only
//       when all four conditions hold (see checkGate). Prefer late or never
//       over firing mid-story.
//   (D) JS sequencer: 18 steps S0-S17, one per 15 s tick. Each request step
//       builds a fresh request from the live template and sends it with a
//       FRESH OkHttpClient via enqueue() + a registered callback. No game UI
//       is touched, no in-game function is called, no scripting-engine
//       injection of any kind is used anywhere in this file.
//
// GROUND TRUTH THAT SHAPES THIS SCRIPT (live run 43760083386 + 43766177036)
//   * Wire bodies are the INNER JSON directly, e.g.
//     {"RetailId":2,"HotVersion":1794552909,"appId":1023,"ActId":10000,
//      "actionid":10000,"T":1794775940,"serverId":21299,"Lang":"en",
//      "Token":"..."} — there is NO outer {version,data,jwt} wrapper on the
//     wire for gameserver calls, even though netSendMod builds one in the
//     client (the gateway layer evidently sends the inner JSON as the body).
//     The script therefore sends in the SAME shape it observes: if a run
//     ever shows the outer shape, it switches to the outer shape (see
//     buildRequestBody). Never assume; copy what the wire shows.
//   * 15000 heartbeats fire every ~60 s THROUGH the whole story walk, and
//     13901 guide steps arrive in bursts (startScene1..5, gaps of 44-177 s,
//     worst gap 177 s in BOTH runs). A 120 s quiet window would fire
//     mid-story, so the gate uses 300 s (see SPEC.md).
//   * The 10000 snapshot RESPONSE body and the 15000 heartbeat responses
//     arrive Zstd-compressed (magic 28 b5 2f fd; 6411 bytes for the 10000
//     response in run 43766177036) — the publisher SDK compresses some
//     gameserver responses with zstd
//     (com.dc.angry.sdk_client.processor.ZSTDCompressProcessor, backed by
//     the app's own native zstdwrap lib). peekBody returns the raw zstd
//     bytes, so the intercept RESP path decodes them with the app's own
//     processor before parsing. Without that, the snapshot (RoleData /
//     VigorCount / VigorTimeUnix) is never seen.
//   * Sess values ROTATE between requests (run 43766177036) — hence the
//     refresh-on-every-request rule for the template.
//   * No post-home action distinguishes home from story in the traffic:
//     after the last guide step the wire shows only 15000 heartbeats. The
//     gate therefore cannot key on a "home action" and relies on the quiet
//     window + elapsed time instead (see SPEC.md).
//
// SECRETS: Sess / Token / jwt / any *token* value is REDACTED before logging
// (substring match on the key name, recursive). Template values live in
// memory only and are never written to any file. Bodies are truncated at
// 6000 chars with an explicit marker. No request body is ever logged raw.
// No purchase actions anywhere (no billing). Forged
// fields are numeric counts ONLY on actions the client already sends.
// Fresh/throwaway account only (the workflow's guest flow).
// INVESTIGATION ONLY. No grant mechanism, no forged receipt, no purchase.
//
// USAGE: FRIDA_SCRIPT=scripts/frida/haremlik-dynrea-wireforge.js on the
// dynrea infra. Emits [DYNREA] lines (traffic) and [DYNREA-WIRE] lines
// (template / gate / steps) via send() (frida.log). The harness greps
// frida.log for "ALL PRIMARY HOOKS ATTACHED".

'use strict';

var MAX_BODY_CHARS = 6000;
var MAX_TARGET_CHARS = 20000;
var TARGET_ACTIONS = { 18281: 1, 18283: 1, 10401: 1, 10602: 1, 10604: 1, 11514: 1 };
var STEP_MS = 15000;
var GATE_CHECK_MS = 10000;
var GATE_QUIET_MS = 300000;      // 300 s with no non-heartbeat gameserver action
var GATE_MIN_ELAPSED_MS = 480000; // 480 s since first gameserver request
var GATE_NEVER_MS = 1800000;      // 30 min: then log NEVER PASSED once, stop
var MAX_VIGOR = 19;               // TcVIP VIP-16 row
var VIGOR_CD = 1800;              // seconds per vigor, ConfigEnvSet
var MAX_TRANSFER = 7;             // TcVIP VIP-16 TransferNum
var seq = 0;

function ts() { return new Date().toISOString(); }
function log(tag, msg) {
    seq += 1;
    var line = '[DYNREA][' + ts() + '][#' + seq + '][' + tag + '] ' + msg;
    try { send(line); } catch (e) {}
    try { console.log(line); } catch (e2) {}
}
function wlog(tag, msg) {
    seq += 1;
    var line = '[DYNREA-WIRE][' + ts() + '][#' + seq + '][' + tag + '] ' + msg;
    try { send(line); } catch (e) {}
    try { console.log(line); } catch (e2) {}
}

// Any key whose NAME contains one of these substrings is a secret: its
// VALUE is never logged. This is a substring match on purpose — the
// game's keys include longe_token / user_token / third_token /
// refresh_token, which an exact-match list misses (agent-3's list missed
// them and a full jwt reached its log; this list does not).
var SECRET_KEY = /sess|token|jwt|auth|password|secret|key/i;
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

// Decompression-aware body decode for the intercept RESP path and for
// forged responses. Some gameserver responses arrive Zstd-compressed
// (magic 28 b5 2f fd — the publisher SDK's ZSTDCompressProcessor; the
// 10000 snapshot is 6411 zstd bytes in run 43766177036, and every 15000
// heartbeat response is ~7.1 KB of zstd). Others arrive plain JSON, and
// a gzip body (magic 1f 8b) is handled too. Decoding uses the app's own
// SDK processor for zstd — the same code the game itself uses for these
// exact bytes. If every attempt fails, the plain decode is returned and
// the caller treats it as unparsable.
var zstdProc = null;
function decodeBodyBytes(rbytes, cap) {
    var plain = decodeBytes(rbytes, cap);
    if (plain.printable && plain.text) return plain;
    if (!rbytes || rbytes.length < 4) return plain;
    try {
        var b0 = rbytes[0] & 0xff, b1 = rbytes[1] & 0xff, b2 = rbytes[2] & 0xff, b3 = rbytes[3] & 0xff;
        if (b0 === 0x28 && b1 === 0xb5 && b2 === 0x2f && b3 === 0xfd) {
            try {
                if (!zstdProc) zstdProc = Java.use('com.dc.angry.sdk_client.processor.ZSTDCompressProcessor').$new();
                var outBytes = zstdProc.decompress(rbytes);
                var dec = decodeBytes(outBytes, cap);
                if (dec.printable && dec.text) {
                    log('http', 'RESP body was zstd, decompressed len=' + dec.total);
                    return dec;
                }
            } catch (e) { log('http', 'zstd decompress attempt failed: ' + e); }
            return plain;
        }
        if (b0 === 0x1f && b1 === 0x8b) {
            var jarr = Java.array('byte', (function () {
                var a = [];
                for (var i = 0; i < rbytes.length; i++) a.push(rbytes[i]);
                return a;
            })());
            var ByteArrayInputStream = Java.use('java.io.ByteArrayInputStream');
            var GZIPInputStream = Java.use('java.util.zip.GZIPInputStream');
            var ByteArrayOutputStream = Java.use('java.io.ByteArrayOutputStream');
            var gz = GZIPInputStream.$new(ByteArrayInputStream.$new(jarr));
            var bos = ByteArrayOutputStream.$new();
            var buf = Java.array('byte', (function () {
                var b = [];
                for (var k = 0; k < 4096; k++) b.push(0);
                return b;
            })());
            var n = 0;
            while ((n = gz.read(buf)) !== -1) { bos.write(buf, 0, n); }
            try { gz.close(); } catch (e0) {}
            var outBytes2 = bos.toByteArray();
            var dec2 = decodeBytes(outBytes2, cap);
            if (dec2.printable && dec2.text) {
                log('http', 'RESP body was gzip, decompressed len=' + dec2.total);
                return dec2;
            }
        }
    } catch (e) { log('http', 'decompress attempt failed: ' + e); }
    return plain;
}

// Parse a gateway body. Two shapes occur on the wire:
//   outer:  {"version":"1.8","jwt":...,"data":"<inner json>","server_id":..}
//   inner-direct (the shape actually observed for gameserver calls in
//   runs 43760083386 / 43766177036): the body IS the action JSON itself.
// Returns {actionId, inner, innerText, outer, bodyShape}.
function parseBody(text) {
    if (!text) return { actionId: null, inner: null, innerText: '', outer: null, bodyShape: 'none' };
    try {
        var outer = JSON.parse(text);
        if (outer && typeof outer.data === 'string') {
            try {
                var inner = JSON.parse(outer.data);
                var id = inner.actionid || inner.ActId || null;
                return { actionId: id, inner: inner, innerText: JSON.stringify(redact(inner, 0)), outer: outer, bodyShape: 'outer' };
            } catch (e) {
                return { actionId: null, inner: null, innerText: outer.data.slice(0, MAX_BODY_CHARS), outer: outer, bodyShape: 'outer-unparsable' };
            }
        }
        var id0 = outer.actionid || outer.ActId || null;
        return { actionId: id0, inner: outer, innerText: JSON.stringify(redact(outer, 0)).slice(0, MAX_BODY_CHARS), outer: null, bodyShape: 'inner-direct' };
    } catch (e) {
        return { actionId: null, inner: null, innerText: '', outer: null, bodyShape: 'unparsable' };
    }
}

// ---- shared live state (memory only; secrets never logged) ---------------
var template = null;        // {url, headers[[name,value]..], outer, inner, bodyShape, at}
var scriptLoadMs = Date.now();
var firstGameReqMs = null;  // first /gameserver request seen
var snapshotReqSeen = false;
var snapshotSeen = false;   // 10000 RESP with RoleData parsed
var snapshotWeak = false;   // fallback form of condition 1 (see checkGate)
var heartbeatReqTimes = []; // 15000 REQ times
var heartbeatRespTimes = []; // 15000 REQ + HTTP 200 RESP observed
var lastOtherActionMs = null;
var lastOtherActionId = null;
var observedCompetitionRankId = null;
var lastVigor = null;       // {count, time} from latest 10000/10401 data
var last10401 = null;       // {vigorCount, vigorTimeUnix} from latest 10401 RESP
var transferUsed = null;    // VisitData.TransferNum (USED count) from 10602
var transferRemaining = MAX_TRANSFER;
var s2resp = null;          // {vigorCount, vigorTimeUnix} from OUR S2 response
var gateArmed = false;
var gateLogged = {};
var gateNeverLogged = false;
var halted = false;
var sendMode = 'async';     // 'async' (enqueue) or 'sync' (execute fallback)
var sendModeLogged = false;
var pendingCallbacks = {};  // stepId -> callback instance (kept alive)
var mediaTypeLogged = false;

function nowSec() { return Math.floor(Date.now() / 1000); }

function computeLegitCtime() {
    if (!lastVigor || lastVigor.count === undefined || lastVigor.count === null ||
        lastVigor.time === undefined || lastVigor.time === null) return null;
    if (lastVigor.count >= MAX_VIGOR) return lastVigor.count;
    var c = Math.floor((nowSec() - lastVigor.time) / VIGOR_CD);
    if (c < 0) c = 0;
    if (c > MAX_VIGOR) c = MAX_VIGOR;
    return c;
}

function updateVigorFrom(obj) {
    if (!obj || typeof obj !== 'object') return;
    var vc = obj.VigorCount, vt = obj.VigorTimeUnix;
    if (vc !== undefined && vt !== undefined) {
        lastVigor = { count: vc, time: vt };
    }
}

function updateTransferRemaining(usedCount) {
    if (usedCount === undefined || usedCount === null) return;
    transferUsed = usedCount;
    var rem = MAX_TRANSFER - usedCount;
    if (rem < 0) rem = 0;
    transferRemaining = rem;
}

// ---- session-template capture (memory only) ------------------------------
function captureTemplate(url, headers, bodyText) {
    var parsed = parseBody(bodyText);
    if (!parsed.inner) return;
    var outerKeys = [], innerKeys = [];
    var k;
    for (k in parsed.inner) innerKeys.push(k);
    if (parsed.outer) for (k in parsed.outer) outerKeys.push(k);
    template = {
        url: url,
        headers: headers ? headers.slice() : [],
        outer: parsed.outer || null,
        inner: parsed.inner,
        bodyShape: parsed.bodyShape,
        at: Date.now()
    };
    var host = url.replace(/^https?:\/\//, '').split('/')[0];
    wlog('template', 'template captured (host=' + host + ' shape=' + parsed.bodyShape +
        ' headers=' + template.headers.length +
        ' outerKeys=[' + outerKeys.join(',') + ']' +
        ' innerKeys=[' + innerKeys.join(',') + '])');
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
    // Gate / state tracking from the live traffic (REQ and RESP).
    try {
        if (dir === 'REQ') {
            if (id === 10000) snapshotReqSeen = true;
            if (id === 15000) heartbeatReqTimes.push(Date.now());
            if (id !== null && id !== undefined && id !== 15000 && id !== 10000) {
                lastOtherActionMs = Date.now();
                lastOtherActionId = id;
            }
            if ((id === 10211 || id === 10206) && parsed.inner &&
                typeof parsed.inner.CompetitionRankId === 'number') {
                observedCompetitionRankId = parsed.inner.CompetitionRankId;
            }
        } else if (dir === 'RESP' && parsed.inner) {
            var d = parsed.inner.Data || parsed.inner.data || {};
            if (id === 10000) {
                var rd = d.RoleData || d.roleData || {};
                if (rd.VigorTimeUnix !== undefined) {
                    if (!snapshotSeen) wlog('GATE', 'snapshot: 10000 RESP RoleData seen vigorCount=' + rd.VigorCount + ' vigorTimeUnix=' + rd.VigorTimeUnix + ' serverVipLv=' + rd.VipLv);
                    snapshotSeen = true;
                    updateVigorFrom(rd);
                }
            }
            if (id === 10401) {
                var v10401 = (d && d.VigorCount !== undefined) ? d : parsed.inner;
                if (v10401.VigorCount !== undefined) {
                    last10401 = { vigorCount: v10401.VigorCount, vigorTimeUnix: v10401.VigorTimeUnix };
                    updateVigorFrom(v10401);
                }
            }
            if (id === 10602) {
                var vd = d.VisitData || parsed.inner.VisitData || null;
                if (vd && vd.TransferNum !== undefined) updateTransferRemaining(vd.TransferNum);
            }
            if (id === 10605) {
                if (d.TransferNum !== undefined) updateTransferRemaining(d.TransferNum);
            }
        }
    } catch (e) {}
    // 10000 login snapshot: pull the server-side role facts out of the noise.
    if (id === 10000 && parsed.inner) {
        try {
            var dd = parsed.inner.Data || parsed.inner.data || {};
            var rrd = dd.RoleData || dd.roleData || {};
            var ri = dd.RoleItem || [];
            log('SNAPSHOT', 'dir=' + dir + ' serverVipLv=' + rrd.VipLv + ' vigorCount=' + rrd.VigorCount +
                ' vigorTimeUnix=' + rrd.VigorTimeUnix + ' roleItemEntries=' + (ri.length || 0));
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
            var tid = Process.getCurrentThreadId();
            var reqHeaders = null;
            var isGame = false;
            try {
                var req = chain.request();
                url = req.url().toString();
                isGame = url.indexOf('/gameserver') !== -1;
                if (isGame && firstGameReqMs === null) firstGameReqMs = Date.now();
                var h = req.headers().get('Gw-Encrypt-Type');
                if (h) encType = h;
                try {
                    var hdrs = req.headers();
                    var n = hdrs.size();
                    reqHeaders = [];
                    for (var i = 0; i < n; i++) reqHeaders.push([hdrs.name(i), hdrs.value(i)]);
                } catch (e0) { reqHeaders = null; }
                var body = req.body();
                if (body) {
                    var Buffer = Java.use('okio.Buffer');
                    var buf = Buffer.$new();
                    body.writeTo(buf);
                    var bytes = buf.readByteArray();
                    reqBodyInfo = 'len=' + bytes.length;
                    // The body bytes as handed to OkHttp ARE the bytes sent.
                    // On this client no request carries Gw-Encrypt-Type: chacha20,
                    // so flip() never engages and this body is the PLAINTEXT
                    // outer JSON (netAdapter.encrypt is the identity fn).
                    var dec = decodeBytes(bytes, MAX_TARGET_CHARS);
                    if (dec.printable && dec.text) {
                        emitAction(parseBody(dec.text), 'REQ', tid);
                        if (isGame) captureTemplate(url, reqHeaders, dec.text);
                    } else {
                        log('http', 'REQ-BODY non-utf8 url=' + url + ' len=' + bytes.length);
                    }
                }
            } catch (e) { reqBodyInfo = 'read-error: ' + e; }
            log('http', 'REQ url=' + url + ' Gw-Encrypt-Type=' + encType + ' body ' + reqBodyInfo);
            var resp = intercept.call(this, chain);
            try {
                log('http', 'RESP url=' + url + ' code=' + resp.code() + ' Gw-Encrypt-Type=' + (resp.header('Gw-Encrypt-Type') || '-'));
                if (isGame) {
                    // Heartbeat RESP, counted by HTTP status, NOT by parsed
                    // body: in run 43760083386 no 15000 RESP body was ever
                    // captured (peekBody empty), while the HTTP 200 lines
                    // were always there. Read the thread mapping BEFORE
                    // emitAction below deletes it.
                    var lastId = lastReqByThread[tid];
                    if (lastId === 15000 && resp.code() === 200) heartbeatRespTimes.push(Date.now());
                }
                // peekBody() copies without consuming — the game still gets
                // its full body. Only used when the response is NOT
                // ChaCha20-encrypted (encrypted responses come via flip IN).
                if (!resp.header('Gw-Encrypt-Type')) {
                    try {
                        var peek = resp.peekBody(20000);
                        var rbytes = peek.bytes();
                        var rdec = decodeBodyBytes(rbytes, MAX_TARGET_CHARS);
                        if (rdec.printable && rdec.text) emitAction(parseBody(rdec.text), 'RESP', tid);
                    } catch (e2) { log('http', 'RESP peek failed url=' + url + ' ' + e2); }
                }
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

// ---- wire forge: request building ---------------------------------------
// Envelope keys, exactly generateNormalParams (netSendMod): actionid,
// ActId, Ver, serverId, appId, Sess, Token, Lang, T, HotVersion, RetailId.
// Any other key in the template inner object is a GAME-payload key of
// whatever action was last observed (GuideStage, QueryRedpoint, UId,
// DeviceId, ...) and is DROPPED — it must never leak into a forged step.
var ENVELOPE_KEYS = ['actionid', 'ActId', 'Ver', 'serverId', 'appId', 'Sess', 'Token', 'Lang', 'T', 'HotVersion', 'RetailId'];

function buildRequestBody(action, payload) {
    var inner = {};
    var i, k;
    for (i = 0; i < ENVELOPE_KEYS.length; i++) {
        k = ENVELOPE_KEYS[i];
        if (template.inner && template.inner[k] !== undefined) inner[k] = template.inner[k];
    }
    inner.actionid = action;
    inner.ActId = action;
    inner.T = nowSec();
    // On the wire, Token appears only on the 10000 login request; every
    // other gameserver request carries Sess and no Token. Drop Token here.
    if (action !== 10000 && action !== 9010) delete inner.Token;
    for (k in payload) inner[k] = payload[k];
    var bodyText;
    if (template.bodyShape === 'outer' && template.outer) {
        var outer = {};
        for (k in template.outer) outer[k] = template.outer[k];
        outer.data = JSON.stringify(inner);
        if (outer.jwt === undefined && template.inner && template.inner.Token !== undefined) outer.jwt = template.inner.Token;
        bodyText = JSON.stringify(outer);
    } else {
        // Observed shape on the wire in runs 43760083386 / 43766177036:
        // the inner JSON itself is the body (no outer wrapper).
        bodyText = JSON.stringify(inner);
    }
    return { inner: inner, bodyText: bodyText };
}

function observedContentType() {
    if (!template || !template.headers) return null;
    for (var i = 0; i < template.headers.length; i++) {
        if (template.headers[i][0].toLowerCase() === 'content-type') return template.headers[i][1];
    }
    return null;
}

function makeRequestBody(mediaType, text) {
    var RB = Java.use('okhttp3.RequestBody');
    try { return RB.create(mediaType, text); } catch (e1) {
        try { return RB.create(text, mediaType); } catch (e2) {
            try {
                var bytes = Java.use('java.lang.String').$new(text).getBytes('UTF-8');
                return RB.create(mediaType, bytes);
            } catch (e3) {
                throw new Error('RequestBody.create failed all orders: ' + e1 + ' / ' + e2 + ' / ' + e3);
            }
        }
    }
}

function handleForgeResponse(stepId, action, httpCode, bodyText) {
    var parsed = null, code = 'n/a', bodyLog = '';
    try { parsed = JSON.parse(bodyText); } catch (e) { parsed = null; }
    if (parsed && typeof parsed === 'object') {
        if (parsed.Code !== undefined) code = parsed.Code;
        else if (parsed.code !== undefined) code = parsed.code;
        var red = JSON.stringify(redact(parsed, 0));
        bodyLog = red.length > MAX_BODY_CHARS ? red.slice(0, MAX_BODY_CHARS) + '\n...[TRUNCATED total=' + red.length + ' chars]' : red;
    } else {
        bodyLog = '[non-JSON response body, len=' + (bodyText ? bodyText.length : 0) + ', not shown]';
    }
    wlog('RESP', stepId + ' action=' + action + ' code=' + code + ' body=' + bodyLog);
    if (parsed && typeof parsed === 'object') {
        var d = parsed.Data || parsed.data || {};
        if (code === 2 || code === 3) {
            halted = true;
            wlog('HALT', 'code=' + code + ' — stopping, further requests meaningless');
            return;
        }
        if (action === 10401) {
            var v = (d && d.VigorCount !== undefined) ? d : parsed;
            if (v.VigorCount !== undefined) {
                last10401 = { vigorCount: v.VigorCount, vigorTimeUnix: v.VigorTimeUnix };
                updateVigorFrom(v);
            }
            if (stepId === 'S2' && last10401) s2resp = { vigorCount: last10401.vigorCount, vigorTimeUnix: last10401.vigorTimeUnix };
        }
        if (action === 10602) {
            var vd = d.VisitData || parsed.VisitData || null;
            if (vd && vd.TransferNum !== undefined) updateTransferRemaining(vd.TransferNum);
        }
        if (action === 10605) {
            if (d.TransferNum !== undefined) updateTransferRemaining(d.TransferNum);
        }
    }
}

function sendStepSync(stepId, action, payload) {
    Java.perform(function () {
        try {
            var built = buildRequestBody(action, payload);
            var ct = observedContentType();
            var mtStr = (ct && ct.indexOf('json') !== -1) ? ct : 'application/json; charset=utf-8';
            if (!mediaTypeLogged) { wlog('SEND', 'content-type=' + mtStr + ' (observed=' + (ct || 'none') + ') mode=sync-fallback'); mediaTypeLogged = true; }
            var MediaType = Java.use('okhttp3.MediaType');
            var mt = MediaType.parse(mtStr);
            var Duration = Java.use('java.time.Duration');
            var Builder = Java.use('okhttp3.OkHttpClient$Builder');
            var client = Builder.$new().connectTimeout(Duration.ofSeconds(10)).readTimeout(Duration.ofSeconds(10)).build();
            var Request = Java.use('okhttp3.Request');
            var reqBuilder = Java.use('okhttp3.Request$Builder').$new();
            reqBuilder.url(template.url);
            var excluded = { 'content-length': 1, 'host': 1, 'connection': 1, 'accept-encoding': 1, 'content-type': 1 };
            for (var i = 0; i < template.headers.length; i++) {
                var hn = template.headers[i][0];
                if (!excluded[hn.toLowerCase()]) reqBuilder.addHeader(hn, template.headers[i][1]);
            }
            reqBuilder.post(makeRequestBody(mt, built.bodyText));
            var req = reqBuilder.build();
            var resp = client.newCall(req).execute();
            var httpCode = resp.code();
            var bodyText = '';
            // Read raw bytes, not string(): if the server answers our
            // fresh client with zstd (as it does for some game actions),
            // string() would return the raw compressed bytes. The
            // decoder below handles zstd (via the app's own SDK
            // processor), gzip, and plain JSON.
            try { var b = resp.body(); if (b) bodyText = decodeBodyBytes(b.bytes(), 1000000).text; } catch (e0) { bodyText = ''; }
            try { resp.close(); } catch (e1) {}
            handleForgeResponse(stepId, action, httpCode, bodyText);
        } catch (e) {
            wlog('STEP-ERROR', stepId + ' action=' + action + ' sync send failed: ' + e);
        }
    });
}

function sendStep(stepId, action, payload) {
    if (!template) {
        wlog('STEP-ERROR', stepId + ' action=' + action + ' no session template yet — not sent');
        return;
    }
    var built = buildRequestBody(action, payload);
    var innerRed = JSON.stringify(redact(built.inner, 0));
    wlog('STEP', stepId + ' action=' + action + ' sent-inner=' + innerRed);
    if (sendMode === 'sync') { sendStepSync(stepId, action, payload); return; }
    Java.perform(function () {
        try {
            var ct = observedContentType();
            var mtStr = (ct && ct.indexOf('json') !== -1) ? ct : 'application/json; charset=utf-8';
            if (!mediaTypeLogged) { wlog('SEND', 'content-type=' + mtStr + ' (observed=' + (ct || 'none') + ') mode=async-enqueue'); mediaTypeLogged = true; }
            var MediaType = Java.use('okhttp3.MediaType');
            var mt = MediaType.parse(mtStr);
            var Duration = Java.use('java.time.Duration');
            var Builder = Java.use('okhttp3.OkHttpClient$Builder');
            var client = Builder.$new().connectTimeout(Duration.ofSeconds(10)).readTimeout(Duration.ofSeconds(10)).build();
            var Request = Java.use('okhttp3.Request');
            var reqBuilder = Java.use('okhttp3.Request$Builder').$new();
            reqBuilder.url(template.url);
            // Template headers verbatim, except the ones OkHttp manages
            // itself. Accept-Encoding is deliberately NOT copied: with it
            // absent OkHttp adds its own gzip header and decompresses
            // transparently, so body().string() is plaintext.
            var excluded = { 'content-length': 1, 'host': 1, 'connection': 1, 'accept-encoding': 1, 'content-type': 1 };
            for (var i = 0; i < template.headers.length; i++) {
                var hn = template.headers[i][0];
                if (!excluded[hn.toLowerCase()]) reqBuilder.addHeader(hn, template.headers[i][1]);
            }
            reqBuilder.post(makeRequestBody(mt, built.bodyText));
            var req = reqBuilder.build();
            var Callback = Java.use('okhttp3.Callback');
            var clsName = 'com.dynrea.WireCallback_' + stepId;
            var CbClass = Java.registerClass({
                name: clsName,
                implements: [Callback],
                methods: {
                    onFailure: function (call, err) {
                        try { delete pendingCallbacks[stepId]; } catch (e0) {}
                        wlog('STEP-ERROR', stepId + ' action=' + action + ' onFailure: ' + err);
                    },
                    onResponse: function (call, response) {
                        try { delete pendingCallbacks[stepId]; } catch (e0) {}
                        try {
                            var httpCode = response.code();
                            var bodyText = '';
                            try { var b = response.body(); if (b) bodyText = decodeBodyBytes(b.bytes(), 1000000).text; } catch (e1) { bodyText = ''; }
                            try { response.close(); } catch (e2) {}
                            handleForgeResponse(stepId, action, httpCode, bodyText);
                        } catch (e3) {
                            wlog('STEP-ERROR', stepId + ' action=' + action + ' onResponse threw: ' + e3);
                        }
                    }
                }
            });
            var cb = CbClass.$new();
            pendingCallbacks[stepId] = cb;
            client.newCall(req).enqueue(cb);
        } catch (e) {
            // registerClass / enqueue unworkable: fall back to a synchronous
            // execute() for this and all later steps, and say so plainly.
            sendMode = 'sync';
            wlog('SEND', 'async path FAILED (' + e + ') — falling back to sync execute() for this and all later steps');
            sendStepSync(stepId, action, payload);
        }
    });
}

// ---- sequencer: 18 steps S0-S17, one per 15 s tick -----------------------
function vigorLine() {
    var c = lastVigor ? lastVigor.count : 'unknown';
    var t = lastVigor ? lastVigor.time : 'unknown';
    var legit = computeLegitCtime();
    return 'vigorCount=' + c + ' vigorTimeUnix=' + t + ' now=' + nowSec() +
        ' legitCtime=' + (legit === null ? 'unknown' : legit);
}

function stepS0() {
    wlog('S0', vigorLine());
    if (computeLegitCtime() === null) wlog('S0', 'baseline UNKNOWN (no 10000 snapshot RoleData captured) — S2/S11 stay precondition-gated, see SPEC.md');
}

function stepS17() {
    wlog('S17', vigorLine());
    wlog('SEQ', 'ALL PROBE STEPS FIRED (18 steps)');
}

var STEPS = [
    { id: 'S0', run: function () { stepS0(); } },
    { id: 'S1', run: function () { sendStep('S1', 10602, {}); } },
    { id: 'S2', run: function () {
        var legit = computeLegitCtime();
        if (legit === null) { legit = 0; wlog('S2', 'legit cTime UNKNOWN, sending fallback cTime=0'); }
        sendStep('S2', 10401, { cTime: legit });
    } },
    { id: 'S3', run: function () {
        var rem = transferRemaining;
        if (transferUsed === null) wlog('S3', 'S1 response not seen yet, using default remaining transfers=7');
        sendStep('S3', 10605, { IsFree: rem > 0 ? 1 : 0, Num: rem });
    } },
    // S4: CompetitionRankId is present in the stageMod table only as a nil
    // (beforeActivity10Second usually returns nil) — a nil field is absent
    // on the wire, so the payload is {}. It is added only if a real id was
    // observed in live traffic.
    { id: 'S4', run: function () {
        var p = {};
        if (observedCompetitionRankId !== null) p.CompetitionRankId = observedCompetitionRankId;
        sendStep('S4', 10211, p);
    } },
    // S5: OptionNum is nil for one-key-all in the governmentMod call, so it
    // is absent on the wire; only EnterType is sent.
    { id: 'S5', run: function () { sendStep('S5', 10703, { EnterType: 2 }); } },
    { id: 'S6', run: function () { sendStep('S6', 12005, { EnterType: 2 }); } },
    // S7: wire casing is PascalCase (manageAssetsMod builds
    // {CollectType, EnterType} at the netProtocol call) — see SPEC.md.
    { id: 'S7', run: function () { sendStep('S7', 10001, { CollectType: 4, EnterType: 2 }); } },
    { id: 'S8', run: function () { sendStep('S8', 10807, {}); } },
    { id: 'S9', run: function () { sendStep('S9', 16340, {}); } },
    { id: 'S10', run: function () { sendStep('S10', 16342, { EnterType: 2, IsEnjoyPrivilege: false }); } },
    { id: 'S11', run: function () {
        var base = s2resp || (last10401 ? { vigorCount: last10401.vigorCount, vigorTimeUnix: last10401.vigorTimeUnix } : null);
        if (base) {
            var saved = lastVigor;
            lastVigor = { count: base.vigorCount, time: base.vigorTimeUnix };
            var legitNow = computeLegitCtime();
            lastVigor = saved;
            wlog('S11-CTX', 'postS2 vigorCount=' + base.vigorCount + ' vigorTimeUnix=' + base.vigorTimeUnix + ' legitCtimeNow=' + legitNow + (s2resp ? ' (from S2 response)' : ' (from game traffic, S2 response missing)'));
        } else {
            wlog('S11-CTX', 'postS2 vigorCount=unknown vigorTimeUnix=unknown legitCtimeNow=unknown — S2 never ran or never answered, so S11 alone proves nothing (see SPEC.md)');
        }
        sendStep('S11', 10401, { cTime: 19 });
    } },
    { id: 'S12', run: function () { sendStep('S12', 10605, { IsFree: 1, Num: 99 }); } },
    { id: 'S13', run: function () { sendStep('S13', 10603, { ItemCount: 99 }); } },
    // S14: CompetitionRankId omitted unless a real one was observed live.
    { id: 'S14', run: function () {
        var p = { SilverNum: 999999999 };
        if (observedCompetitionRankId !== null) p.CompetitionRankId = observedCompetitionRankId;
        sendStep('S14', 10206, p);
    } },
    { id: 'S15', run: function () {
        wlog('S15-NOTE', 'RecoverType=1 is a best-guess enum value (see SPEC.md) — a Code==1 here is INCONCLUSIVE, not a server-side proof');
        sendStep('S15', 10002, { RecoverType: 1, RecoverTimes: 99 });
    } },
    // S16: wire casing is PascalCase (tributeMod builds
    // {CountryId, UseNum, IsEnjoyPrivilege}) — see SPEC.md. CountryId=1
    // is a best guess.
    { id: 'S16', run: function () {
        wlog('S16-NOTE', 'CountryId=1 is a best-guess value (see SPEC.md)');
        sendStep('S16', 12004, { CountryId: 1, UseNum: 99, IsEnjoyPrivilege: false });
    } },
    { id: 'S17', run: function () { stepS17(); } }
];

function runStep(idx) {
    if (halted) { wlog('SEQ', 'halted — step ' + (STEPS[idx] ? STEPS[idx].id : '?') + ' not fired'); return; }
    if (idx >= STEPS.length) return;
    try { STEPS[idx].run(); } catch (e) { wlog('STEP-ERROR', STEPS[idx].id + ' run threw: ' + e); }
    if (idx + 1 < STEPS.length) {
        setTimeout(function () { runStep(idx + 1); }, STEP_MS);
    }
}

// ---- home-entry gate (JS-side, conservative) -----------------------------
// Timeline evidence (runs 43760083386 / 43766177036): 15000 heartbeats fire
// every ~60 s THROUGH the story walk, and 13901 guide steps arrive in
// bursts with gaps of 44-177 s (worst gap 177 s in both runs). A 120 s
// quiet window would therefore fire mid-story (between startScene1 and
// startScene2). The gate uses 300 s of quiet — 123 s of margin over the
// worst observed inter-guide gap — plus 480 s since the first gameserver
// request. It prefers firing late or never over firing mid-story.
function gateConditions() {
    var now = Date.now();
    var c1 = snapshotSeen || (snapshotReqSeen && heartbeatRespTimes.length >= 1);
    var c2 = false;
    var times = heartbeatRespTimes.length >= 2 ? heartbeatRespTimes : heartbeatReqTimes;
    if (times.length >= 2) {
        for (var i = 1; i < times.length; i++) {
            if (times[i] - times[0] >= 60000) { c2 = true; break; }
        }
    }
    var c3 = (lastOtherActionMs === null) || (now - lastOtherActionMs >= GATE_QUIET_MS);
    var c4 = (firstGameReqMs !== null) && (now - firstGameReqMs >= GATE_MIN_ELAPSED_MS);
    return { c1: c1, c2: c2, c3: c3, c4: c4 };
}

function checkGate() {
    if (gateArmed) return;
    if (firstGameReqMs === null) {
        if (Date.now() - scriptLoadMs >= GATE_NEVER_MS && !gateNeverLogged) {
            gateNeverLogged = true;
            wlog('GATE', 'NEVER PASSED — all probe steps SKIPPED (no gameserver request seen in 30 min)');
        } else {
            setTimeout(checkGate, GATE_CHECK_MS);
        }
        return;
    }
    var g = gateConditions();
    if (g.c1 && !gateLogged.c1) { gateLogged.c1 = true; wlog('GATE', 'condition 1 TRUE: 10000 snapshot' + (snapshotSeen ? ' RoleData seen' : ' (WEAK form: 10000 REQ + heartbeat RESP, RoleData body not captured)')); }
    if (g.c2 && !gateLogged.c2) { gateLogged.c2 = true; wlog('GATE', 'condition 2 TRUE: two 15000 heartbeats >=60 s apart'); }
    if (g.c3 && !gateLogged.c3) { gateLogged.c3 = true; wlog('GATE', 'condition 3 TRUE: no story-walk action for >=300 s (last other action=' + (lastOtherActionId === null ? 'none' : lastOtherActionId) + ')'); }
    if (g.c4 && !gateLogged.c4) { gateLogged.c4 = true; wlog('GATE', 'condition 4 TRUE: >=480 s since first gameserver request'); }
    if (g.c1 && g.c2 && g.c3 && g.c4) {
        gateArmed = true;
        wlog('GATE', 'PASSED — arming sequencer (first step in 5 s)');
        setTimeout(function () { runStep(0); }, 5000);
        return;
    }
    if (Date.now() - firstGameReqMs >= GATE_NEVER_MS && !gateNeverLogged) {
        gateNeverLogged = true;
        wlog('GATE', 'NEVER PASSED — all probe steps SKIPPED (c1=' + g.c1 + ' c2=' + g.c2 + ' c3=' + g.c3 + ' c4=' + g.c4 + ')');
        return;
    }
    setTimeout(checkGate, GATE_CHECK_MS);
}

// ---- hook attach / init ----------------------------------------------------
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
        wlog('GATE', 'gate checker started (needs: 10000 snapshot + 2x15000 >=60 s apart + 300 s quiet + 480 s elapsed)');
        setTimeout(checkGate, GATE_CHECK_MS);
    } else if (tries < 24) {
        log('init', 'attempt ' + tries + ': hooks pending (flip=' + !!hooksAttached.flip +
            ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
            ') — retrying in 5s');
        setTimeout(tryHookAll, 5000);
    } else {
        log('init', 'GIVING UP after 24 attempts: flip=' + !!hooksAttached.flip +
            ' flip2=' + !!hooksAttached.flip2 + ' intercept=' + !!hooksAttached.intercept +
            ' — traffic capture NOT VERIFIED');
        wlog('GATE', 'NEVER PASSED — all probe steps SKIPPED (traffic hooks never attached)');
    }
}

Java.perform(function () {
    log('init', 'dynrea wireforge script loaded; pid=' + Process.id + ' arch=' + Process.arch);
    tryHookAll();
});

/*
 * Haremlik Al-Sultan (com.dc.hwsj 7.804) — DYNREA BASELINE Frida script v2.
 *
 * Purpose: capture the PLAINTEXT gateway traffic (action requests +
 * responses) that the static sweep could not see. Investigation + infra
 * ONLY. No purchases, no forged receipts, no exploit, no grant mechanism.
 *
 * v2 changes vs v1 (2026-11-15, after run 43757292835):
 * - v1 BUG (root cause of the 0-action run): decodeBytes() called
 *   `.length` / `.charCodeAt()` on a JAVA String object — both are
 *   undefined there, so every body was scored non-printable and silently
 *   dropped. The bodies were almost certainly PLAINTEXT JSON all along
 *   (e.g. FindProvince body len=20 == exactly `{"language":"zh-CN"}`).
 *   v2 converts to a real JS string with `.toString()` FIRST, and
 *   self-tests the decoder at init (logs DYNREA-SELFTEST).
 * - v1 also read KSNetMeta fields as `meta.dir.value` — Frida fields are
 *   accessed directly (`meta.dir`); fixed.
 * - v2 NEVER silently drops a body: non-printable bodies are logged as a
 *   hex preview + a gzip-magic check + a gunzip attempt.
 * - v2 adds the GATEWAY-LAYER taps, the layer ABOVE the transport, where
 *   plaintext provably exists (traced in Lua, netSendMod/httpRequest):
 *     netProtocol.action(id, data) -> dataNetMod.callFunc ->
 *     netSendMod.request -> tdata = json.encode(sendData) [PLAINTEXT,
 *     carries actionid/ActId] -> gatewayAdapter.distribute({body=tdata})
 *     -> SDK.GameGatewayService():distribute({servicePath, header, body})
 *     -> GatewayRequestInfo.setBody(tdata) [data = tdata.getBytes()]
 *     -> OkHttp POST to <pool>/gameserver (or /gameroute via distributeTo).
 *   The Lua `netAdapter.encrypt()` is an IDENTITY function in this build
 *   (`return data`) and `decrypt_decompress()` is a no-op (decompiled
 *   sdkAdapter/netAdapter.luac) — Lua does NO encryption. The KSecure
 *   flip() path was NEVER called in run 1 (0 invocations), so the
 *   KSInterceptor/ChaCha20 layer is dormant for this traffic; the
 *   gateway-layer hooks are the real plaintext tap.
 *
 * Hook points (all verified against the decoded smali, 2026-11-15):
 * 1. PRIMARY — GatewayRequestInfo.setBody(String): the EXACT body string
 *    the gateway sends (plaintext action JSON). One call per request.
 * 2. PRIMARY — GatewayServiceImpl.distribute(GatewayRequestInfo) and
 *    .distributeTo(GatewayRequestInfo, String): servicePath / httpPath /
 *    header map + getBodyByte() decoded. Gameroute uses distributeTo.
 * 3. TRANSPORT — KSInterceptor.intercept(Chain): URL + headers +
 *    request body (private okio.Buffer copy — never consumes the real
 *    body). Response BODY is deliberately NOT read here (single-use
 *    ResponseBody); response plaintext comes from hook 4 instead.
 * 4. RESPONSE — okhttp3.ResponseBody.string() / .bytes(): POST-call
 *    logging only — the original call runs first (the app consumes the
 *    body itself), we log its return value and hand it back unchanged.
 * 5. KSecure — KSecureValidation.flip(KSNetMeta) / flip2([B)[B /
 *    init / enable: kept from v1 (dormant in run 1, but if any call
 *    ever carries Gw-Encrypt-Type traffic this is where it shows).
 *    The `enable` argument value is NEVER logged (may be key material).
 *
 * Output: console.log lines, all prefixed [DYNREA]. Bodies truncated at
 * MAX_BODY_CHARS with an explicit [TRUNCATED total=N] marker. Action ids
 * are also emitted as single-line [DYNREA][ACTION] records for grepping.
 */
'use strict';

var MAX_BODY_CHARS = 6000;   // per-body log cap; truncation is always marked
var MAX_HEX_BYTES = 256;     // hex-preview cap for non-UTF8 bodies

var seq = 0;
function ts() { return new Date().toISOString(); }
function log(tag, msg) {
  seq += 1;
  console.log('[DYNREA][' + ts() + '][#' + seq + '][' + tag + '] ' + msg);
}

/* Decode a Java byte[] to a JS string. Returns
 * { text, truncated, total, printable, decodeError } — never throws.
 * FIX v2: the String is converted with .toString() FIRST so .length and
 * .charCodeAt() are real JS-string operations (v1 read them off the Java
 * object, where both are undefined, and scored every body non-printable). */
function decodeBytes(bytes) {
  var out = { text: '', truncated: false, total: 0, printable: false, decodeError: null };
  try {
    if (!bytes) return out;
    var len = bytes.length;
    out.total = len;
    if (len === 0) return out;
    var n = Math.min(len, MAX_BODY_CHARS);
    var slice = [];
    for (var i = 0; i < n; i++) slice.push(bytes[i]);
    var jarr = Java.array('byte', slice);
    var jsStr = Java.use('java.lang.String').$new(jarr, 'UTF-8').toString();
    out.text = jsStr;
    out.truncated = len > MAX_BODY_CHARS;
    var printable = 0, checked = Math.min(jsStr.length, 500);
    for (var j = 0; j < checked; j++) {
      var c = jsStr.charCodeAt(j);
      if ((c >= 0x20 && c <= 0x7e) || c === 0x09 || c === 0x0a || c === 0x0d || c >= 0x80) printable++;
    }
    out.printable = checked === 0 || (printable / checked) > 0.95;
    if (!out.printable) {
      out.text = hexPreview(bytes, Math.min(len, MAX_HEX_BYTES));
    }
    if (out.truncated) out.text += '\n...[TRUNCATED total=' + len + ' bytes]';
  } catch (e) {
    out.decodeError = String(e);
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

/* Try gunzipping a Java byte[] (gzip magic 1f 8b). Returns a JS string or null. */
function tryGunzip(bytes) {
  try {
    if (!bytes || bytes.length < 2) return null;
    if ((bytes[0] & 0xff) !== 0x1f || (bytes[1] & 0xff) !== 0x8b) return null;
    var ByteArrayInputStream = Java.use('java.io.ByteArrayInputStream');
    var GZIPInputStream = Java.use('java.util.zip.GZIPInputStream');
    var ByteArrayOutputStream = Java.use('java.io.ByteArrayOutputStream');
    var jarr = Java.array('byte', Array.prototype.slice.call(bytes, 0, Math.min(bytes.length, 1048576)));
    var gz = GZIPInputStream.$new(ByteArrayInputStream.$new(jarr));
    var out = ByteArrayOutputStream.$new();
    var buf = Java.array('byte', new Array(4096).fill(0));
    var r;
    while ((r = gz.read(buf, 0, 4096)) !== -1) { out.write(buf, 0, r); }
    gz.close();
    return Java.use('java.lang.String').$new(out.toByteArray(), 'UTF-8').toString();
  } catch (e) {
    return null;
  }
}

/* Pull an action id out of a plaintext JSON body, if present. */
function extractAction(text) {
  try {
    if (typeof text !== 'string') return null;
    var obj = JSON.parse(text);
    if (obj && typeof obj === 'object') {
      var id = obj.actionid || obj.ActId || obj.actionId || obj.action || obj.ActionId;
      if (id !== undefined && id !== null) return String(id);
      if (obj.data && typeof obj.data === 'object') {
        var d = obj.data;
        var id2 = d.actionid || d.ActId || d.actionId;
        if (id2 !== undefined && id2 !== null) return String(id2);
      }
    }
  } catch (e) { /* not JSON — fine */ }
  return null;
}

/* Log one captured body, ALWAYS (text when printable, hex + gunzip attempt
 * when not). Never silently drops. Emits a separate [ACTION] line when an
 * action id parses out of the plaintext. */
function logBody(tag, label, dec, rawBytesForGunzip) {
  var line = label + ' len=' + dec.total;
  if (dec.truncated) line += ' TRUNCATED';
  if (dec.decodeError) line += ' DECODE-ERROR=' + dec.decodeError;
  if (dec.printable) {
    log(tag, line + '\n' + dec.text);
    var action = extractAction(dec.text);
    if (action !== null) log('ACTION', 'id=' + action + ' ' + label + ' len=' + dec.total);
  } else {
    var gz = rawBytesForGunzip ? tryGunzip(rawBytesForGunzip) : null;
    if (gz !== null) {
      var gzDec = { text: gz, total: gz.length, truncated: false, printable: true, decodeError: null };
      log(tag, line + ' [gunzip OK]\n' + gz);
      var action2 = extractAction(gz);
      if (action2 !== null) log('ACTION', 'id=' + action2 + ' ' + label + ' len=' + dec.total + ' [gunzipped]');
    } else {
      log(tag, line + ' [non-utf8]\n' + dec.text);
    }
  }
}

var hooksAttached = {};

function hookSetBody() {
  try {
    var ReqInfo = Java.use('com.dc.angry.api.gateway.IBaseGatewayService$GatewayRequestInfo');
    var setBody = ReqInfo.setBody.overload('java.lang.String');
    setBody.implementation = function (s) {
      var bodyStr = '';
      try { bodyStr = s.toString(); } catch (e) { bodyStr = '<toString-error: ' + e + '>'; }
      var dec = { text: bodyStr, total: bodyStr.length, truncated: bodyStr.length > MAX_BODY_CHARS, printable: true, decodeError: null };
      if (dec.truncated) dec.text = bodyStr.substring(0, MAX_BODY_CHARS) + '\n...[TRUNCATED total=' + bodyStr.length + ' chars]';
      log('gw', 'setBody len=' + bodyStr.length + (dec.truncated ? ' TRUNCATED' : '') + '\n' + dec.text);
      var action = extractAction(bodyStr);
      if (action !== null) log('ACTION', 'id=' + action + ' dir=OUT via=setBody len=' + bodyStr.length);
      return setBody.call(this, s);
    };
    hooksAttached.setBody = true;
    log('init', 'hook attached: GatewayRequestInfo.setBody(String)');
  } catch (e) {
    log('init', 'hook FAILED (will retry): GatewayRequestInfo.setBody err=' + e);
  }
}

function hookDistribute() {
  try {
    var Gw = Java.use('com.dc.angry.gateway.GatewayServiceImpl');
    var logReq = function (info, extra) {
      try {
        var sp = '?', hp = '?', hdr = '?', bodyDec = null;
        try { sp = String(info.servicePath); } catch (e) {}
        try { hp = String(info.httpPath); } catch (e) {}
        try { hdr = String(info.header); } catch (e) {}
        try { bodyDec = decodeBytes(info.getBodyByte()); } catch (e2) {}
        log('gw', 'distribute' + (extra || '') + ' servicePath=' + sp + ' httpPath=' + hp + ' header=' + hdr);
        if (bodyDec) logBody('gw', 'distribute-body servicePath=' + sp, bodyDec, info.getBodyByte());
      } catch (e) {
        log('gw', 'distribute log-error: ' + e);
      }
    };
    try {
      var d1 = Gw.distribute.overload('com.dc.angry.api.gateway.IBaseGatewayService$GatewayRequestInfo');
      d1.implementation = function (info) {
        logReq(info, '');
        return d1.call(this, info);
      };
      hooksAttached.distribute = true;
      log('init', 'hook attached: GatewayServiceImpl.distribute(GatewayRequestInfo)');
    } catch (e) { log('init', 'hook FAILED: distribute(1-arg) err=' + e); }
    try {
      var d2 = Gw.distributeTo.overload('com.dc.angry.api.gateway.IBaseGatewayService$GatewayRequestInfo', 'java.lang.String');
      d2.implementation = function (info, region) {
        var r = '?';
        try { r = String(region); } catch (e) {}
        logReq(info, 'To region=' + r);
        return d2.call(this, info, region);
      };
      hooksAttached.distributeTo = true;
      log('init', 'hook attached: GatewayServiceImpl.distributeTo(GatewayRequestInfo, String)');
    } catch (e) { log('init', 'hook FAILED: distributeTo err=' + e); }
  } catch (e) {
    log('init', 'hook FAILED (will retry): GatewayServiceImpl distribute err=' + e);
  }
}

function hookFlip() {
  try {
    var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
    var flip = KSV.flip.overload('com.dc.angry.plugin_libs_ksc.KSNetMeta');
    flip.implementation = function (meta) {
      // FIX v2: Frida fields are accessed directly (meta.dir), not .value.
      var dir = -1, ct = 0, stateBefore = -1, inDec = { text: '', total: 0, truncated: false, printable: false, decodeError: null };
      try { dir = meta.dir; } catch (e) {}
      try { ct = meta.ct; } catch (e) {}
      try { stateBefore = meta.state; } catch (e) {}
      try { inDec = decodeBytes(meta.dt); } catch (e) {}
      var dirLabel = (dir === 1) ? 'OUT' : (dir === 0 ? 'IN' : 'DIR' + dir);
      var plainLabel = (dir === 1) ? 'REQ-PLAIN' : 'RESP-PLAIN';
      if (dir === 1) logBody('flip', plainLabel + ' dir=' + dirLabel + ' ct=' + ct, inDec, meta.dt);
      var ret;
      try {
        ret = flip.call(this, meta);
      } catch (e) {
        log('flip', 'ORIGINAL flip() THREW dir=' + dirLabel + ' ct=' + ct + ' err=' + e);
        throw e;
      }
      var stateAfter = -1, outDec = { text: '', total: 0, truncated: false, printable: false, decodeError: null };
      try { stateAfter = meta.state; } catch (e) {}
      try { outDec = decodeBytes(meta.dt); } catch (e) {}
      if (dir === 0) logBody('flip', plainLabel + ' dir=' + dirLabel + ' ct=' + ct, outDec, meta.dt);
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
      var inDec = decodeBytes(input);
      var ret = flip2.call(this, input);
      var outDec = decodeBytes(ret);
      if (inDec.printable) logBody('flip2', 'IN-PLAIN', inDec, input);
      if (outDec.printable) logBody('flip2', 'OUT-PLAIN', outDec, ret);
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
      var url = '?', encType = '-', reqBodyInfo = 'no-body', reqBodyDec = null, reqBytes = null;
      try {
        var req = chain.request();
        url = req.url().toString();
        var headers = req.headers();
        var h = headers.get('Gw-Encrypt-Type');
        if (h) encType = String(h);
        var body = req.body();
        if (body) {
          var Buffer = Java.use('okio.Buffer');
          var buf = Buffer.$new();
          body.writeTo(buf);
          reqBytes = buf.readByteArray();
          reqBodyInfo = 'len=' + reqBytes.length;
          reqBodyDec = decodeBytes(reqBytes);
        }
      } catch (e) {
        reqBodyInfo = 'read-error: ' + e;
      }
      log('http', 'REQ url=' + url + ' Gw-Encrypt-Type=' + encType + ' body ' + reqBodyInfo);
      if (reqBodyDec) logBody('http', 'REQ-BODY url=' + url, reqBodyDec, reqBytes);
      var resp = intercept.call(this, chain);
      try {
        var code = resp.code();
        var respEnc = resp.header('Gw-Encrypt-Type');
        var clen = -1;
        try { clen = resp.body().contentLength(); } catch (e2) {}
        log('http', 'RESP url=' + url + ' code=' + code + ' Gw-Encrypt-Type=' + (respEnc ? String(respEnc) : '-') + ' contentLength=' + clen);
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

function hookResponseBody() {
  try {
    var RB = Java.use('okhttp3.ResponseBody');
    try {
      var strFn = RB.string.overload();
      strFn.implementation = function () {
        var r = strFn.call(this);
        var jsStr = '';
        try { jsStr = r.toString(); } catch (e) { jsStr = '<toString-error: ' + e + '>'; }
        var dec = { text: jsStr, total: jsStr.length, truncated: jsStr.length > MAX_BODY_CHARS, printable: true, decodeError: null };
        if (dec.truncated) dec.text = jsStr.substring(0, MAX_BODY_CHARS) + '\n...[TRUNCATED total=' + jsStr.length + ' chars]';
        log('http', 'RESP-BODY[string] len=' + jsStr.length + (dec.truncated ? ' TRUNCATED' : '') + '\n' + dec.text);
        return r;
      };
      hooksAttached.respString = true;
      log('init', 'hook attached: okhttp3.ResponseBody.string()');
    } catch (e) { log('init', 'hook FAILED: ResponseBody.string err=' + e); }
    try {
      var bytesFn = RB.bytes.overload();
      bytesFn.implementation = function () {
        var r = bytesFn.call(this);
        var dec = decodeBytes(r);
        logBody('http', 'RESP-BODY[bytes]', dec, r);
        return r;
      };
      hooksAttached.respBytes = true;
      log('init', 'hook attached: okhttp3.ResponseBody.bytes()');
    } catch (e) { log('init', 'hook FAILED: ResponseBody.bytes err=' + e); }
  } catch (e) {
    log('init', 'hook FAILED (will retry): okhttp3.ResponseBody err=' + e);
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
        // NEVER log the argument value — it may be key material.
        var len = -1;
        try { len = s.length(); } catch (e2) {}
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
  if (!hooksAttached.setBody) hookSetBody();
  if (!hooksAttached.distribute && !hooksAttached.distributeTo) hookDistribute();
  if (!hooksAttached.flip) hookFlip();
  if (!hooksAttached.flip2) hookFlip2();
  if (!hooksAttached.intercept) hookIntercept();
  if (!hooksAttached.respString || !hooksAttached.respBytes) hookResponseBody();
  if (!hooksAttached.init || !hooksAttached.enable) hookLifecycle();
  var done = hooksAttached.setBody && (hooksAttached.distribute || hooksAttached.distributeTo) &&
    hooksAttached.flip && hooksAttached.flip2 && hooksAttached.intercept;
  if (done) {
    log('init', 'ALL PRIMARY HOOKS ATTACHED after ' + tries + ' attempt(s)');
  } else if (tries < 24) {
    log('init', 'attempt ' + tries + ': hooks pending (setBody=' + !!hooksAttached.setBody +
      ' distribute=' + !!hooksAttached.distribute + ' distributeTo=' + !!hooksAttached.distributeTo +
      ' flip=' + !!hooksAttached.flip + ' flip2=' + !!hooksAttached.flip2 +
      ' intercept=' + !!hooksAttached.intercept + ' respString=' + !!hooksAttached.respString +
      ' respBytes=' + !!hooksAttached.respBytes + ') — retrying in 5s (class may not be loaded yet)');
    setTimeout(tryHookAll, 5000);
  } else {
    log('init', 'GIVING UP after 24 attempts: setBody=' + !!hooksAttached.setBody +
      ' distribute=' + !!hooksAttached.distribute + ' distributeTo=' + !!hooksAttached.distributeTo +
      ' flip=' + !!hooksAttached.flip + ' flip2=' + !!hooksAttached.flip2 +
      ' intercept=' + !!hooksAttached.intercept + ' respString=' + !!hooksAttached.respString +
      ' respBytes=' + !!hooksAttached.respBytes + ' — see errors above; traffic capture NOT VERIFIED');
  }
}

Java.perform(function () {
  log('init', 'dynrea baseline script v2 loaded; pid=' + Process.id + ' arch=' + Process.arch);
  // Self-test the decoder (v1 bug check): decode a known ASCII byte array.
  try {
    var testBytes = Java.array('byte', [68, 89, 78, 82, 69, 65, 45, 83, 69, 76, 70, 84, 69, 83, 84]);
    var t = decodeBytes(testBytes);
    log('init', 'decoder self-test: text=' + t.text + ' printable=' + t.printable + ' total=' + t.total + (t.decodeError ? ' DECODE-ERROR=' + t.decodeError : ''));
  } catch (e) {
    log('init', 'decoder self-test THREW: ' + e);
  }
  tryHookAll();
});

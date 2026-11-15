/*
 * Haremlik Al-Sultan (com.dc.hwsj 7.804) — DYNREA BASELINE Frida script.
 *
 * Purpose: capture the PLAINTEXT gateway traffic that the static sweep could
 * not see (app-layer KSecure ChaCha20 encryption — plain mitmproxy sees only
 * ciphertext). Investigation + infra ONLY. No purchases, no forged receipts,
 * no exploit, no grant mechanism.
 *
 * Hook points (all verified against the decoded smali, 2026-11-15):
 *
 * 1. PRIMARY — KSecureValidation.flip(KSNetMeta)  [native, via Java]
 *    com.dc.angry.plugin_libs_ksc.KSecureValidation.flip(Lcom/dc/angry/plugin_libs_ksc/KSNetMeta;)V
 *    Called from KSInterceptor.intercept() for every encrypted gateway call.
 *    KSNetMeta fields: dt:[B (buffer, mutated in place), ct:J (timestamp),
 *    dir:B (0 = IN / decrypt inbound response, 1 = OUT / encrypt outbound
 *    request — enum com.dc.angry.plugin_libs_ksc.a.c: a="IN"(0), b="OUT"(1)),
 *    state:I (0 = ok), pt:String, flip:Z, of:I.
 *      dir=1 (OUT): dt BEFORE flip = PLAINTEXT request JSON (what
 *        net.netProtocol.action(id, data, cb) built); dt AFTER = ciphertext.
 *      dir=0 (IN):  dt BEFORE flip = ciphertext response; dt AFTER =
 *        PLAINTEXT response JSON.
 *    So ONE hook yields full request + response plaintext with direction.
 *
 * 2. SECONDARY — KSecureValidation.flip2([B)[B : same crypto, other call
 *    sites (returns a new byte[] instead of mutating in place).
 *
 * 3. METADATA — KSInterceptor.intercept(Interceptor$Chain): logs URL +
 *    headers (Gw-Encrypt-Type / Gw-Encrypt-Timestamp) + request-body
 *    PLAINTEXT (read via a private okio.Buffer copy — never consumes the
 *    real body) + response code/headers. The response BODY is deliberately
 *    NOT read here: ResponseBody is single-use and reading it would starve
 *    the game. Response plaintext comes from hook 1 (dir=0) instead.
 *
 * 4. LIFECYCLE — KSecureValidation.init(Context) / enable(String): logs
 *    that KSecure initialised (enable's argument is NOT logged — it may be
 *    key material; only its length is recorded).
 *
 * Lua net layer (net.netProtocol.action) is NOT hooked directly: Lua runs
 * inside the Corona native runtime (no Java entry point) and the bytes
 * netProtocol builds are exactly the dir=1 plaintext captured by hook 1.
 * See work/dynrea/infra/READY.md for the sibling-agent contract.
 *
 * Output: console.log lines, all prefixed [DYNREA]. Bodies are truncated
 * to MAX_BODY_CHARS with an explicit [TRUNCATED total=N] marker.
 * Action numbers are also emitted as single-line [DYNREA][ACTION] records
 * for easy grepping:  [DYNREA][ACTION] id=10000 dir=OUT ...
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

/* Decode a Java byte[] (or JS number array) to a string. Returns an object
 * { text, truncated, total, printable } — never throws. */
function decodeBytes(bytes) {
  var out = { text: '', truncated: false, total: 0, printable: false };
  try {
    if (!bytes) return out;
    var len = bytes.length;
    out.total = len;
    if (len === 0) return out;
    var n = Math.min(len, MAX_BODY_CHARS);
    var slice = [];
    for (var i = 0; i < n; i++) slice.push(bytes[i]);
    var jarr = Java.array('byte', slice);
    var s = Java.use('java.lang.String').$new(jarr, 'UTF-8');
    out.text = s;
    out.truncated = len > MAX_BODY_CHARS;
    // printable? (allow whitespace + common punctuation; JSON is ASCII)
    var printable = 0, checked = Math.min(s.length, 500);
    for (var j = 0; j < checked; j++) {
      var c = s.charCodeAt(j);
      if ((c >= 0x20 && c <= 0x7e) || c === 0x09 || c === 0x0a || c === 0x0d || c >= 0x80) printable++;
    }
    out.printable = checked === 0 || (printable / checked) > 0.95;
    if (!out.printable) {
      out.text = hexPreview(bytes, Math.min(len, MAX_HEX_BYTES));
    }
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

/* Pull an action id out of a plaintext JSON body, if present. */
function extractAction(text) {
  try {
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

function logBody(tag, dirLabel, dec, state) {
  var line = dirLabel + ' len=' + dec.total + ' state=' + state;
  if (dec.truncated) line += ' TRUNCATED';
  log(tag, line + '\n' + dec.text);
  var action = dec.printable ? extractAction(dec.text) : null;
  if (action !== null) {
    log('ACTION', 'id=' + action + ' ' + dirLabel + ' len=' + dec.total);
  }
}

var hooksAttached = {};

function hookFlip() {
  try {
    var KSV = Java.use('com.dc.angry.plugin_libs_ksc.KSecureValidation');
    var flip = KSV.flip.overload('com.dc.angry.plugin_libs_ksc.KSNetMeta');
    flip.implementation = function (meta) {
      var dir = 0, ct = 0, stateBefore = -1, inDec = { text: '', total: 0, truncated: false, printable: false };
      try { dir = meta.dir.value; } catch (e) {}
      try { ct = meta.ct.value; } catch (e) {}
      try { stateBefore = meta.state.value; } catch (e) {}
      try { inDec = decodeBytes(meta.dt.value); } catch (e) {}
      var dirLabel = (dir === 1) ? 'OUT' : (dir === 0 ? 'IN' : 'DIR' + dir);
      var plainLabel = (dir === 1) ? 'REQ-PLAIN' : 'RESP-PLAIN';
      // Log the PLAINTEXT side: OUT -> input is plaintext; IN -> output is plaintext.
      if (dir === 1) logBody('flip', plainLabel + ' dir=' + dirLabel + ' ct=' + ct, inDec, stateBefore);
      var ret;
      try {
        ret = flip.call(this, meta);
      } catch (e) {
        log('flip', 'ORIGINAL flip() THREW dir=' + dirLabel + ' ct=' + ct + ' err=' + e);
        throw e;
      }
      var stateAfter = -1, outDec = { text: '', total: 0, truncated: false, printable: false };
      try { stateAfter = meta.state.value; } catch (e) {}
      try { outDec = decodeBytes(meta.dt.value); } catch (e) {}
      if (dir === 0) logBody('flip', plainLabel + ' dir=' + dirLabel + ' ct=' + ct, outDec, stateAfter);
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
      // flip2 has no direction field: log whichever side looks like plaintext.
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
          reqBodyDec = decodeBytes(bytes);
        }
      } catch (e) {
        reqBodyInfo = 'read-error: ' + e;
      }
      log('http', 'REQ url=' + url + ' Gw-Encrypt-Type=' + encType + ' body ' + reqBodyInfo);
      if (reqBodyDec && reqBodyDec.printable) {
        log('http', 'REQ-BODY url=' + url + '\n' + reqBodyDec.text);
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
        // NEVER log the argument value — it may be key material.
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

Java.perform(function () {
  log('init', 'dynrea baseline script loaded; pid=' + Process.id + ' arch=' + Process.arch);
  tryHookAll();
});

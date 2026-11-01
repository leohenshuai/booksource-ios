// Legado 规则 JS 运行时：在 JavaScriptCore（App）或 node vm（测试）里执行。
// 宿主需提供全局：__http(url,optJSON)->JSON字符串 {body,headers,status,url}；__md5(s)；__hmac(alg,key,data,enc)；__b64e(s)；__b64d(s)；__uuid()
var __store = {};
function __un(n) { return function () { throw new Error('UNSUPPORTED:' + n); }; }
function __resp(r) {
  return {
    body: function () { return r.body; }, toString: function () { return r.body; },
    statusCode: function () { return r.status; }, code: function () { return r.status; },
    headers: function (n) { if (n === undefined) return r.headers; var v = r.headers[String(n).toLowerCase()]; return v ? [v] : []; },
    header: function (n) { return r.headers[String(n).toLowerCase()] || ''; },
    raw: function () { return { request: function () { return { url: function () { return r.url; } }; }, code: function () { return r.status; } }; },
    url: function () { return r.url; }, cookies: function () { return {}; }
  };
}
function __do(u, opt) { return JSON.parse(__http(String(u), JSON.stringify(opt || {}))); }
var java = {
  md5Encode: function (s) { return __md5(String(s)); },
  md5Encode16: function (s) { return __md5(String(s)).slice(8, 24); },
  base64Encode: function (s) { return __b64e(String(s)); },
  base64Decode: function (s) { return __b64d(String(s)); },
  encodeURI: function (s) { return encodeURIComponent(String(s)); },
  encodeURIComponent: function (s) { return encodeURIComponent(String(s)); },
  HMacHex: function (d, alg, k) { return __hmac(String(alg), String(k), String(d), 'hex'); },
  HMacBase64: function (d, alg, k) { return __hmac(String(alg), String(k), String(d), 'base64'); },
  randomUUID: function () { return __uuid(); },
  log: function () { return ''; }, longToast: function () { return ''; }, toast: function () { return ''; },
  timeFormat: function (t) { return new Date(+t).toISOString(); },
  timeFormatUTC: function (t) { return new Date(+t).toISOString(); },
  getTime: function () { return Date.now(); },
  ajax: function (u, opt) { if (Array.isArray(u)) { opt = u[1]; u = u[0]; } return __do(u, opt).body; },
  ajaxAll: function (us) { return us.map(function (u) { return __resp(__do(u)); }); },
  get: function (a, b) { if (b === undefined && !/^https?:/i.test(String(a))) return __store[a] || ''; return __resp(__do(a, { headers: b })); },
  post: function (u, body, h) { return __resp(__do(u, { method: 'POST', body: body, headers: h })); },
  connect: function (u, h) { return __resp(__do(u, { headers: h })); },
  put: function (k, v) { __store[k] = v; return v; },
  getCookie: function () { return ''; },
  startBrowser: __un('startBrowser'), webView: __un('webView'),
  createSymmetricCrypto: __un('createSymmetricCrypto'), desEncodeToBase64String: __un('desEncode'),
  aesEncodeToBase64String: __un('aesEncode'), aesDecodeToString: __un('aesDecode'),
  s2t: function (s) { return s; }, t2s: function (s) { return s; }, getString: function () { return ''; }, getElements: function () { return []; }
};
var cookie = { removeCookie: function () { return ''; }, setCookie: function () { return ''; }, getCookie: function () { return ''; }, replaceCookie: function () { return ''; } };
var source = { key: '', bookSourceUrl: '', getKey: function () { return ''; }, getVariable: function () { return __store.__var || ''; }, setVariable: function (v) { __store.__var = v; },
  get: function (k) { return __store[k] || ''; }, put: function (k, v) { __store[k] = v; }, getLoginInfoMap: function () { return {}; }, getLoginInfo: function () { return ''; }, getHeaderMap: function () { return {}; } };
var org = { jsoup: { Jsoup: { parse: __un('jsoup') } } };
var getVariable = function () { return ''; }, getArguments = function () { return {}; };
var cache = { get: function () { return null; }, put: function () { return ''; } };
var book = {}, speakText = '', title = '', result = '', key = '', page = 1, baseUrl = '';
var btoa = function (s) { return __b64e(String(s)); }, atob = function (s) { return __b64d(String(s)); };

function __run(inp) {
  var o;
  try { o = JSON.parse(inp); } catch (e) { return JSON.stringify({ ok: false, err: 'bad input' }); }
  var src = o.src || {}, base = src.bookSourceUrl || '';
  key = o.key; page = o.page || 1; baseUrl = base;
  source.key = base; source.bookSourceUrl = base; source.getKey = function () { return base; }; source.bookSourceName = src.bookSourceName;
  var ev = function (c) { return (0, eval)(c); };
  try {
    if (src.jsLib) { try { ev(src.jsLib); } catch (e) { if (/UNSUPPORTED/.test(String(e.message))) throw e; } }
    var rule = String(o.rule), res = '', re = /<js>([\s\S]*?)<\/js>|@js:([\s\S]*)$/g, m, start = 0, any = false;
    while ((m = re.exec(rule))) {
      any = true;
      if (start < m.index) res = rule.slice(start, m.index).replace(/@result/g, res);
      result = res;
      var v = ev(m[1] !== undefined ? m[1] : m[2]);
      res = (v === undefined || v === null) ? '' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
      start = re.lastIndex;
    }
    if (any) { if (start < rule.length) res = rule.slice(start).replace(/@result/g, res); } else res = rule;
    res = res.replace(/\{\{([\s\S]*?)\}\}/g, function (all, e) {
      var t = e.trim();
      if (/^(key|key2|searchKey|kw|page|page[-+]\d+)$/.test(t) || /\|urlencode$/.test(t)) return all;
      result = res;
      var v = ev(t); return (v === undefined || v === null) ? '' : String(v);
    });
    return JSON.stringify({ ok: true, url: res.trim() });
  } catch (e) {
    return JSON.stringify({ ok: false, err: String((e && e.message) || e).slice(0, 120) });
  }
}

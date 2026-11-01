// 书源检测引擎：移植自 chk.py（标准模式）。网络与 JS 沙箱由宿主 native 提供：
//   native.http({url,method,headers,body,charset,timeout}) -> {ok,status,text,size,ms} | {ok:false,msg}
//   native.enc(str,charset) -> 百分号编码串（按 charset）
//   native.jsEval({rule,key,page,src}) -> {ok,url}|{ok:false,err}
(function (G) {
  const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  const DESK = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
  const ACC = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8';
  const PARK = [['域名已过期', '站点域名疑似已过期'], ['域名到期', '站点域名疑似已过期'], ['domain has expired', '站点域名疑似已过期'],
    ['site is for sale', '站点疑似域名停放/出售'], ['buy this domain', '站点疑似域名停放/出售'], ['this domain is parked', '站点疑似域名停放/出售'], ['domain parking', '站点疑似域名停放/出售'],
    ['网站已关闭', '站点已关闭或维护'], ['站点已关闭', '站点已关闭或维护'], ['网站已经关闭', '站点已关闭或维护'], ['网站维护中', '站点已关闭或维护'], ['too many redirects', '站点重定向过多']];
  const ERRP = ['404 not found', 'whitelabel error page', '503 service unavailable', '502 bad gateway', '请求过于频繁', 'access denied'];
  const NORES = ['没有找到', '未搜索到', '没有检索到', '搜索结果为0', '无搜索结果', '暂无搜索结果', '搜索结果为空', '找不到相关', '查无此书'];

  function splitRule(rule) {
    let depth = 0, q = null, esc = false;
    for (let i = 0; i < rule.length; i++) {
      const c = rule[i];
      if (esc) { esc = false; continue; }
      if (q) { if (c === '\\') esc = true; else if (c === q) q = null; continue; }
      if (c === '"' || c === "'") q = c;
      else if ('{[('.includes(c)) depth++;
      else if ('}])'.includes(c)) depth = Math.max(0, depth - 1);
      else if (c === ',' && depth === 0) {
        let j = i + 1;
        while (j < rule.length && ' \t\r\n'.includes(rule[j])) j++;
        if (j < rule.length && rule[j] === '{') return [rule.slice(0, i).trim(), rule.slice(j)];
      }
    }
    return [rule.trim(), null];
  }
  function parseOpts(text) {
    let t = String(text || '').trim();
    try {
      const o = JSON.parse(t);
      if (o && typeof o === 'object' && !Array.isArray(o)) {
        const m = {};
        for (const k in o) { const v = o[k]; m[k] = typeof v === 'string' ? v : (v && typeof v === 'object') ? JSON.stringify(v) : String(v); }
        return m;
      }
    } catch (e) {}
    if (t.startsWith('{') && t.endsWith('}')) t = t.slice(1, -1);
    const m = {}, re = /["']?([\w\-]+)["']?\s*[:=]\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^,}]+)/g;
    let x;
    while ((x = re.exec(t))) {
      let v = x[2].trim();
      if ((v[0] === '"' || v[0] === "'") && v[v.length - 1] === v[0]) v = v.slice(1, -1);
      m[x[1]] = v;
    }
    return m;
  }
  function preprocess(rule, base) {
    const notes = [];
    let b = String(base || '').split('#')[0];
    if (b && !b.endsWith('/')) b += '/';
    let r = rule.replace(/^\s*<js>\s*cookie\.\w+\([^)]*\);?\s*<\/js>\s*/, '');
    r = r.replace(/\{\{\s*cookie\.\w+\([^{}]*\)\s*;?\s*\}\}/g, '');
    let r2 = r.split('{{java.connect(source.getKey()).raw().request().url()}}').join(b);
    r2 = r2.replace(/\{\{\s*source\.(getKey\(\)|key|bookSourceUrl)\s*\}\}/g, b);
    if (r2 !== r) { notes.push('已还原站点地址'); r = r2; }
    r2 = r.replace(/\{\{\s*([^{}]*page[^{}]*)\}\}/g, (all, e) => {
      const s = e.trim();
      if (s === 'page' || s === 'page-1' || s === 'page - 1') return all;
      if (/^[\w\s+\-*/().]+$/.test(e) && !/[a-oq-zA-OQ-Z]/.test(e.replace(/page/g, ''))) {
        try { const v = Function('"use strict";return (' + e.replace(/page/g, '1') + ')')(); if (isFinite(v)) return String(Math.trunc(v)); } catch (x) {}
      }
      return all;
    });
    if (r2 !== r) { notes.push('已计算分页表达式'); r = r2; }
    if (/<[^<>]*,[^<>]*>/.test(r) && !r.includes('<js>')) {
      r2 = r.replace(/<([^<>]*,[^<>]*)>/g, (all, p) => p.split(',')[0].trim());
      if (r2 !== r) { notes.push('已解析翻页写法'); r = r2; }
    }
    return [r.trim(), notes];
  }
  function repl(text, kw) {
    let out = text.replace(/\{\{\s*(key2|key|searchKey|kw)\s*\|urlencode\s*\}\}/g, () => encodeURIComponent(kw));
    for (const k of ['{{key2}}', '{{searchKey}}', '{{key}}']) out = out.split(k).join(kw);
    out = out.split('{{page}}').join('1').split('{{page-1}}').join('0').replace(/(^|[^{]){page\}\}/g, '$11');
    out = out.replace(/\{\{\s*page-(\d+)\s*\}\}/g, (a, n) => String(Math.max(0, 1 - +n)));
    out = out.replace(/\{\{\s*page\+(\d+)\s*\}\}/g, (a, n) => String(1 + +n));
    if (out.includes('{{') || out.includes('}}')) return [out, '搜索规则含未支持的变量/JS 表达式'];
    return [out, null];
  }
  function absUrl(base, u) {
    if (/^https?:\/\//i.test(u)) return u;
    try { return new URL(u, base).toString(); } catch (e) { return u; }
  }

  function Engine(native, o) {
    o = o || {};
    const S = { kw: o.kw || '我', timeout: o.timeout || 12 };
    const hostCache = new Map();

    async function enc(s, cs) {
      if (!cs || /^utf-?8$/i.test(cs)) return encodeURIComponent(s).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
      return await native.enc(s, cs);
    }

    async function build(src, kw0, override) {
      const base = src.bookSourceUrl || '';
      let rule = override != null ? override : (src.searchUrl || '');
      if (!rule.trim()) return [null, 'searchUrl 为空'];
      const rs = src.ruleSearch;
      const ck = rs && typeof rs === 'object' ? rs.checkKeyWord : '';
      const kw = ck || kw0;
      const pre = preprocess(rule, base); rule = pre[0]; const notes = pre[1];
      let [url, opt] = splitRule(rule);
      if (override == null) {
        for (const [mk, why] of [['@js:', '含 @js:'], ['<js>', '含 <js>'], ['java.webView', 'WebView'], ['webView(', 'WebView'], ['java.', '调用 java 接口']])
          if (url.includes(mk)) return [null, '搜索规则' + why];
      }
      const op = opt ? parseOpts(opt) : {};
      if (['true', '1'].includes(op.webView) || ['true', '1'].includes(op.useWebView)) notes.push('WebView源，仅测接口可达');
      let r = repl(url, kw); if (r[1]) return [null, r[1]]; url = r[0];
      if (!/^https?/.test(url)) url = absUrl(base, url);
      const method = (op.method || 'GET').toUpperCase();
      const cs = op.charset || 'utf-8';
      const hd = {};
      if (src.header) Object.assign(hd, parseOpts(src.header));
      if (op.header) Object.assign(hd, parseOpts(op.header));
      const has = n => Object.keys(hd).some(k => k.toLowerCase() === n);
      if (!has('user-agent')) hd['User-Agent'] = UA;
      if (!has('accept')) hd['Accept'] = ACC;
      for (const k of Object.keys(hd)) if (['host', 'content-length'].includes(k.toLowerCase())) delete hd[k];
      let body = null;
      if (method === 'POST') {
        let br = op.body || '';
        if (br) { r = repl(br, kw); if (r[1]) return [null, r[1]]; br = r[0]; }
        let ct = null; for (const k of Object.keys(hd)) if (k.toLowerCase() === 'content-type') ct = hd[k];
        const bt = br.trim();
        if ((bt && !'{['.includes(bt[0])) || (ct && /form/i.test(ct))) {
          const ps = [];
          for (const p of br.split('&')) {
            const i = p.indexOf('=');
            ps.push(i >= 0 ? (await enc(p.slice(0, i), cs)) + '=' + (await enc(p.slice(i + 1), cs)) : await enc(p, cs));
          }
          body = ps.join('&'); ct = ct || 'application/x-www-form-urlencoded';
        } else { body = br; ct = ct || 'application/json; charset=utf-8'; }
        for (const k of Object.keys(hd)) if (k.toLowerCase() === 'content-type') delete hd[k];
        hd['Content-Type'] = ct;
      } else {
        let u = url.split('#')[0];
        const qi = u.indexOf('?');
        if (qi >= 0) {
          const parts = [];
          for (const pr of u.slice(qi + 1).split('&')) {
            const i = pr.indexOf('=');
            if (i >= 0) { const k = pr.slice(0, i), v = pr.slice(i + 1); parts.push((k.includes('%') ? k : await enc(k, cs)) + '=' + (v.includes('%') ? v : await enc(v, cs))); }
            else parts.push(pr.includes('%') ? pr : await enc(pr, cs));
          }
          u = u.slice(0, qi) + '?' + parts.join('&');
        }
        url = u;
      }
      return [{ url, method, body, headers: hd, cs, notes }, null];
    }

    async function req(b, headers) {
      return native.http({ url: b.url, method: b.method, headers: headers || b.headers, body: b.body, charset: b.cs !== 'utf-8' ? b.cs : '', timeout: S.timeout });
    }
    async function probeHost(url) {
      if (!/^https?:/.test(url)) return ['DEAD', '地址不是 http(s) 链接'];
      const r = await native.http({ url, method: 'GET', headers: { 'User-Agent': UA, Accept: ACC }, body: null, charset: '', timeout: S.timeout });
      if (!r.ok) return ['DEAD', r.msg];
      const t = r.text.toLowerCase(), c = r.status;
      if (c >= 200 && c < 300) {
        for (const [k, v] of PARK) if (t.includes(k)) return ['DEAD', v];
        if (t.includes('非法访问') && t.length < 500) return ['DEAD', '疑似被封禁或需验证'];
      }
      if (c >= 200 && c < 400) return ['OK', `HTTP ${c} 站点正常可达`];
      if (c === 401 || c === 403) return ['UNCERTAIN', `HTTP ${c} 需要登录或被反爬拦截`];
      return ['DEAD', `HTTP ${c} 站点返回错误`];
    }
    function hostOnce(url) {
      let k = url; try { const u = new URL(url); k = u.protocol + '//' + u.host; } catch (e) {}
      if (!hostCache.has(k)) hostCache.set(k, probeHost(url));
      return hostCache.get(k);
    }

    async function checkOnce(s) {
      if ((s.bookSourceType || 0) !== 0) return hostOnce(s.bookSourceUrl || '');
      let [b, why] = await build(s, S.kw);
      if (!b && why && /JS|java|未支持|@js|<js>/.test(why)) {
        const r = await native.jsEval({ rule: s.searchUrl || '', key: S.kw, page: 1, src: s });
        if (r && r.ok && r.url) {
          let ru = r.url;
          if (ru.startsWith('data:')) { why = '本地计算型源（data: 伪请求），无法联网检测'; ru = null; }
          else {
            const mm = ru.match(/^([\s\S]*?),\s*("[\w\-]+"\s*:[\s\S]*)$/);
            if (mm && !mm[1].trimEnd().endsWith('{')) ru = mm[1] + ',{' + mm[2].trim().replace(/\}$/, '') + '}';
          }
          const [b2, w2] = ru ? await build(s, S.kw, ru) : [null, why];
          if (b2) { b = b2; b.notes.push('已执行JS规则'); } else if (ru) why = '沙箱算出地址但无法解析：' + w2;
        } else {
          const e = (r && r.err) || '';
          why = e.includes('UNSUPPORTED') ? '规则依赖加密/DOM解析等无法模拟的接口' : '规则脚本执行出错：' + e.slice(0, 50);
        }
      }
      if (b) {
        const note = b.notes.length ? '；' + b.notes.join('、') : '';
        let r = await req(b);
        if (r.ok && [401, 403, 429, 503].includes(r.status)) {
          const h2 = Object.assign({}, b.headers); h2['User-Agent'] = DESK;
          const r2 = await req(b, h2); if (r2.ok) r = r2;
        }
        if (!r.ok) return ['DEAD', r.msg];
        const c = r.status;
        if (c >= 200 && c < 300) {
          const tl = r.text.toLowerCase();
          let isjson = false; try { const j = JSON.parse(r.text); isjson = Array.isArray(j) ? j.length > 0 : (j && typeof j === 'object' ? Object.keys(j).length > 0 : !!j); } catch (e) {}
          if (ERRP.some(x => tl.includes(x))) return ['UNCERTAIN', `HTTP ${c}，疑似错误页`];
          if (NORES.some(x => tl.includes(x))) return ['UNCERTAIN', `HTTP ${c}，返回“无结果”类提示`];
          if (isjson || r.text.length > 60 || r.size > 300) return ['OK', `HTTP ${c} 搜索接口正常返回${note}`];
          return ['UNCERTAIN', `HTTP ${c}，返回内容过少${note}`];
        }
        if ([401, 403, 429].includes(c)) return ['UNCERTAIN', `HTTP ${c} 反爬/需登录（换UA仍被拦）${note}`];
        return ['DEAD', `HTTP ${c} 搜索接口不可用`];
      }
      const bu = s.bookSourceUrl || '';
      if (!/^https?:/.test(bu)) return ['UNCERTAIN', `书源地址非网址（聚合/本地型源）；${why}`];
      const [st, m] = await hostOnce(bu);
      if (st === 'OK') {
        if (why === 'searchUrl 为空') return ['UNCERTAIN', '站点可达；无搜索地址（' + (s.exploreUrl ? '仅发现源，不能搜索' : '规则不完整') + '）'];
        return ['UNCERTAIN', `站点可达；${why}（需在阅读里实测）`];
      }
      return [st, m];
    }

    return {
      set(k, v) { S[k] = v; },
      reset() { hostCache.clear(); },
      async check(s) {
        const t0 = Date.now();
        let [st, m] = await checkOnce(s);
        if (st === 'DEAD' && /超时|重置|连接失败/.test(m)) {
          const r = await checkOnce(s); st = r[0]; m = r[1]; if (st === 'DEAD') m += '（已重试）';
        }
        return { state: st, msg: m, ms: Date.now() - t0 };
      },
    };
  }
  G.BSEngine = Engine;
  if (typeof module !== 'undefined') module.exports = Engine;
})(typeof window !== 'undefined' ? window : globalThis);

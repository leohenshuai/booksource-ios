// 用心读书(ParsingBook)书源 → 检测请求。xpath 字段是 JSON：ruleSearch.{url,method,params,header,request,mode,engine,...}
// 转换结果交给 engine.js 的统一判定。宿主 native 提供 http/enc/jsEval。
(function (G) {
  const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  const ACC = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8';

  // 判定通用（与 engine.js 一致）
  const ERRP = ['404 not found', 'whitelabel error page', '503 service unavailable', '502 bad gateway', '请求过于频繁', 'access denied'];
  const NORES = ['没有找到', '未搜索到', '没有检索到', '搜索结果为0', '无搜索结果', '暂无搜索结果', '搜索结果为空', '找不到相关', '查无此书'];

  function subst(s, kw) {
    return String(s).replace(/\{(?:keyword|key|searchKey)\}/g, kw).replace(/\{pageIndex\}/g, '1').replace(/\{page\}/g, '1')
      .replace(/\{\s*\(pageIndex\s*-\s*1\)\s*\*\s*(\d+)\s*\}/g, '0').replace(/\{\s*pageIndex\s*-\s*1\s*\}/g, '0');
  }
  function unresolved(s) { const m = String(s).match(/\{(verifyCode|loginCookies|url|searchUrl|actyzm)\}/); return m ? m[1] : null; }

  async function enc(native, s, cs) {
    if (!cs || /^utf-?8$/i.test(cs)) return encodeURIComponent(s).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
    return await native.enc(s, cs);
  }

  // 返回 {kind:'req',req:{...}} | {kind:'host',url,why} | {kind:'skip',why}
  async function prepare(native, site, kw) {
    let j; try { j = JSON.parse(site.xpath); } catch (e) { return { kind: 'skip', why: '规则已加密（禁止分享）' }; }
    const rs = j.ruleSearch || {}, host = (j.host || site.url || '').trim();
    const hostUrl = /^https?:/.test(host) ? host : (/^https?:/.test(site.url || '') ? site.url : '');
    if (rs.mode === 'webview') return { kind: 'host', url: hostUrl, why: 'WebView 搜索，仅测站点可达' };
    let url = rs.url || '', method = (rs.method || 'GET').toUpperCase(), params = Object.assign({}, rs.params || {}), header = Object.assign({}, j.header || {}, rs.header || {});
    const notes = [];
    const rq = rs.request || '';
    if (rq.startsWith('@js:')) {
      // 在沙箱里跑 request 脚本：config={url,method,params,header,keyword,host,pageIndex}
      const cfg = { url, method, params, header, keyword: kw, host, pageIndex: 1 };
      const r = await native.jsEval({ mode: 'config', code: rq.slice(4), config: cfg, kw, lib: j.publicJavascript || '' });
      if (r && r.ok && r.config) {
        url = r.config.url || url; method = (r.config.method || method).toUpperCase(); params = r.config.params || params; header = r.config.header || header;
        notes.push('已执行request脚本');
      } else {
        const e = (r && r.err) || '';
        return { kind: 'host', url: hostUrl, why: e.includes('NEEDPRE') ? '搜索签名依赖前置请求取令牌，无法模拟，仅测站点可达' : e.includes('UNSUPPORTED') ? 'request脚本依赖加密等接口，无法模拟' : 'request脚本执行出错：' + e.slice(0, 40) };
      }
    } else if (rq) {
      return { kind: 'host', url: hostUrl, why: 'request 为非脚本写法，未支持' };
    }
    if (!url) return { kind: 'host', url: hostUrl, why: '未配置搜索地址，仅测站点可达' };
    if (rs.preRequests && rs.preRequests.length) notes.push('含前置请求（未执行）');
    const bad = unresolved(url + JSON.stringify(params));
    if (bad) return { kind: 'host', url: hostUrl, why: `搜索需要 ${bad === 'verifyCode' || bad === 'actyzm' ? '验证码' : bad === 'loginCookies' ? '登录' : '动态变量'}，仅测站点可达` };
    url = subst(url, kw);
    if (!/^https?:/.test(url)) { try { url = new URL(url, hostUrl || undefined).toString(); } catch (e) { return { kind: 'host', url: hostUrl, why: '搜索地址无法解析' }; } }
    const cs = rs.requestEncode && !/^utf-?8$/i.test(rs.requestEncode) ? rs.requestEncode : 'utf-8';
    const pairs = [];
    for (const k of Object.keys(params)) pairs.push([k, subst(params[k], kw)]);
    const hd = { 'User-Agent': UA, Accept: ACC };
    for (const k of Object.keys(header)) hd[k] = String(header[k]);
    let body = null;
    if (method === 'POST') {
      const ps = []; for (const [k, v] of pairs) ps.push((await enc(native, k, cs)) + '=' + (await enc(native, v, cs)));
      body = ps.join('&'); if (!Object.keys(hd).some(k => k.toLowerCase() === 'content-type')) hd['Content-Type'] = 'application/x-www-form-urlencoded';
    } else if (pairs.length) {
      const ps = []; for (const [k, v] of pairs) ps.push((await enc(native, k, cs)) + '=' + (await enc(native, v, cs)));
      url += (url.includes('?') ? '&' : '?') + ps.join('&');
    }
    return { kind: 'req', req: { url, method, headers: hd, body, cs, notes } };
  }
  G.PBPrepare = prepare;
  G.PBJudge = function (r, notes) {
    const note = notes && notes.length ? '；' + notes.join('、') : '';
    if (!r.ok) return ['DEAD', r.msg];
    const c = r.status;
    if (c >= 200 && c < 300) {
      const tl = r.text.toLowerCase(); let isjson = false;
      try { const j = JSON.parse(r.text); isjson = Array.isArray(j) ? j.length > 0 : (j && typeof j === 'object' ? Object.keys(j).length > 0 : !!j); } catch (e) {}
      if (ERRP.some(x => tl.includes(x))) return ['UNCERTAIN', `HTTP ${c}，疑似错误页`];
      if (NORES.some(x => tl.includes(x))) return ['UNCERTAIN', `HTTP ${c}，返回“无结果”类提示`];
      if (isjson || r.text.length > 60 || r.size > 300) return ['OK', `HTTP ${c} 搜索接口正常返回${note}`];
      return ['UNCERTAIN', `HTTP ${c}，返回内容过少${note}`];
    }
    if ([401, 403, 429].includes(c)) return ['UNCERTAIN', `HTTP ${c} 反爬/需登录${note}`];
    return ['DEAD', `HTTP ${c} 搜索接口不可用`];
  };
  if (typeof module !== 'undefined') module.exports = { prepare, judge: G.PBJudge };
})(typeof window !== 'undefined' ? window : globalThis);

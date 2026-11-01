import UIKit
import WebKit
import JavaScriptCore
import CryptoKit
import Foundation
import SQLite3
import Compression
import UniformTypeIdentifiers

// MARK: - 本地资源
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst()).removingPercentEncoding ?? "")
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish(); return
        }
        let mimes = ["html": "text/html; charset=utf-8", "js": "application/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "png": "image/png", "json": "application/json"]
        let mime = mimes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - 网络（忽略证书错误，与桌面检测一致；不跟随 cookie）
final class Net: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = ch.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: t))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    static func encoding(_ name: String) -> String.Encoding? {
        let n = name.lowercased().replacingOccurrences(of: "_", with: "-")
        if n.isEmpty || n == "utf-8" || n == "utf8" { return .utf8 }
        if ["gbk", "gb2312", "gb18030", "cp936"].contains(n) {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        if n == "big5" { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))) }
        if n == "iso-8859-1" || n == "latin1" { return .isoLatin1 }
        let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
        if cf != kCFStringEncodingInvalidId { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        return nil
    }
    static func decode(_ data: Data, header: String?, preferred: String) -> String {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return String(decoding: data, as: UTF8.self) }
        var name = preferred
        if name.isEmpty, let h = header, let r = h.range(of: "charset=", options: .caseInsensitive) {
            name = String(h[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;")).components(separatedBy: ";").first ?? ""
        }
        let enc = encoding(name) ?? .utf8
        if let s = String(data: data, encoding: enc), !(enc == .utf8 && s.contains("\u{FFFD}")) { return s }
        if enc == .utf8, let g = encoding("gbk"), let s = String(data: data, encoding: g) { return s }
        return String(decoding: data, as: UTF8.self)
    }
    func send(url: String, method: String, headers: [String: String], body: Data?, charset: String, timeout: Double,
              done: @escaping ([String: Any]) -> Void) {
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return done(["ok": false, "msg": "链接格式非法"]) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let b = body, method == "POST" { r.httpBody = b }
        let t0 = Date()
        var finished = false
        let lock = NSLock()
        func fin(_ x: [String: Any]) { lock.lock(); defer { lock.unlock() }; if finished { return }; finished = true; done(x) }
        // 总时限兜底（URLRequest 的 timeout 只管空闲）
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 4) { fin(["ok": false, "msg": "连接超时"]) }
        session.dataTask(with: r) { data, resp, err in
            if let e = err as NSError? {
                var m = "网络错误：\(e.localizedDescription)".prefix(100).description
                switch e.code {
                case NSURLErrorTimedOut: m = "连接超时"
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: m = "域名无法解析（DNS 失败）"
                case NSURLErrorCannotConnectToHost: m = "连接失败/被拒绝"
                case NSURLErrorNetworkConnectionLost: m = "网络连接被重置"
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate: m = "SSL/TLS 证书异常"
                case NSURLErrorHTTPTooManyRedirects: m = "站点重定向过多"
                default: break }
                return fin(["ok": false, "msg": m])
            }
            let h = resp as? HTTPURLResponse
            let d = Data((data ?? Data()).prefix(512 * 1024))
            let txt = Net.decode(d, header: h?.value(forHTTPHeaderField: "Content-Type"), preferred: charset)
            fin(["ok": true, "status": h?.statusCode ?? 0, "text": txt, "size": d.count, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }.resume()
    }
}

// MARK: - JS 沙箱（JavaScriptCore，每次一个独立上下文）
final class JSBox {
    let net: Net
    let rt: String
    init(net: Net) {
        self.net = net
        rt = (try? String(contentsOf: Bundle.main.bundleURL.appendingPathComponent("www/jsrt.js"))) ?? ""
    }
    func run(_ input: String) -> String {
        let ctx = JSContext()!
        var failed = false
        ctx.exceptionHandler = { _, e in failed = true; _ = e }
        let http: @convention(block) (String, String) -> String = { [net] url, optJSON in
            let o = (try? JSONSerialization.jsonObject(with: Data(optJSON.utf8))) as? [String: Any] ?? [:]
            var hs: [String: String] = ["User-Agent": "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"]
            if let h = o["headers"] as? [String: Any] { for (k, v) in h { hs[k] = "\(v)" } }
            var body: Data? = nil; if let b = o["body"] { body = "\(b)".data(using: .utf8) }
            let m = ((o["method"] as? String) ?? "GET").uppercased()
            let sem = DispatchSemaphore(value: 0)
            var out: [String: Any] = ["body": "", "headers": [String: String](), "status": 0, "url": url]
            // 用独立 data task 取响应头
            guard let u = URL(string: url) else { return "{\"body\":\"\",\"headers\":{},\"status\":0,\"url\":\"\"}" }
            var r = URLRequest(url: u, timeoutInterval: 8); r.httpMethod = m; r.httpBody = (m == "POST") ? body : nil
            for (k, v) in hs { r.setValue(v, forHTTPHeaderField: k) }
            net.session.dataTask(with: r) { d, resp, _ in
                if let h = resp as? HTTPURLResponse {
                    var hd = [String: String](); for (k, v) in h.allHeaderFields { hd["\(k)".lowercased()] = "\(v)" }
                    out = ["body": Net.decode(d ?? Data(), header: hd["content-type"], preferred: ""), "headers": hd, "status": h.statusCode, "url": h.url?.absoluteString ?? url]
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            return (try? String(data: JSONSerialization.data(withJSONObject: out), encoding: .utf8)) ?? "{}"
        }
        ctx.setObject(http, forKeyedSubscript: "__http" as NSString)
        let md5: @convention(block) (String) -> String = { s in Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        ctx.setObject(md5, forKeyedSubscript: "__md5" as NSString)
        let b64e: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64d: @convention(block) (String) -> String = { s in Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        ctx.setObject(b64e, forKeyedSubscript: "__b64e" as NSString)
        ctx.setObject(b64d, forKeyedSubscript: "__b64d" as NSString)
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        ctx.setObject(uuid, forKeyedSubscript: "__uuid" as NSString)
        let hmac: @convention(block) (String, String, String, String) -> String = { alg, key, data, enc in
            let k = SymmetricKey(data: Data(key.utf8)), d = Data(data.utf8)
            let a = alg.lowercased().replacingOccurrences(of: "hmac", with: "")
            var bytes: [UInt8]
            switch a {
            case "sha1": bytes = Array(HMAC<Insecure.SHA1>.authenticationCode(for: d, using: k))
            case "sha256": bytes = Array(HMAC<SHA256>.authenticationCode(for: d, using: k))
            case "sha512": bytes = Array(HMAC<SHA512>.authenticationCode(for: d, using: k))
            default: bytes = Array(HMAC<Insecure.MD5>.authenticationCode(for: d, using: k)) }
            return enc == "base64" ? Data(bytes).base64EncodedString() : bytes.map { String(format: "%02x", $0) }.joined()
        }
        ctx.setObject(hmac, forKeyedSubscript: "__hmac" as NSString)
        ctx.evaluateScript(rt)
        if failed { return "{\"ok\":false,\"err\":\"运行时加载失败\"}" }
        ctx.setObject(input, forKeyedSubscript: "__inp" as NSString)
        let v = ctx.evaluateScript("__run(__inp)")
        return v?.toString() ?? "{\"ok\":false,\"err\":\"无输出\"}"
    }
}


// MARK: - 用心读书备份包（zip 内 sql.mrbf 为明文 SQLite）
final class Backup {
    struct Entry { var name: String; var flag: UInt16; var method: UInt16; var time: UInt16; var date: UInt16; var crc: UInt32; var csize: UInt32; var usize: UInt32; var offset: UInt32; var extAttr: UInt32 }
    let url: URL
    var entries: [Entry] = []
    var fh: FileHandle
    init?(url: URL) {
        self.url = url
        guard let f = try? FileHandle(forReadingFrom: url) else { return nil }
        fh = f
        guard parse() else { return nil }
    }
    deinit { try? fh.close() }
    func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    func parse() -> Bool {
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 22 else { return false }
        let tail = min(size, 70000)
        try? fh.seek(toOffset: size - tail)
        guard let d = try? fh.read(upToCount: Int(tail)) else { return false }
        var eocd = -1
        var i = d.count - 22
        while i >= 0 { if d[d.startIndex + i] == 0x50 && d[d.startIndex + i + 1] == 0x4b && d[d.startIndex + i + 2] == 5 && d[d.startIndex + i + 3] == 6 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return false }
        let cnt = Int(u16(d, eocd + 10)), cdOff = UInt64(u32(d, eocd + 16)), cdSize = Int(u32(d, eocd + 12))
        guard cnt != 0xffff, cdOff != 0xffffffff else { return false }   // 不支持 zip64
        try? fh.seek(toOffset: cdOff)
        guard let cd = try? fh.read(upToCount: cdSize), cd.count == cdSize else { return false }
        var p = 0
        for _ in 0..<cnt {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014b50 else { return false }
            let fl = u16(cd, p + 8), me = u16(cd, p + 10), tm = u16(cd, p + 12), dt = u16(cd, p + 14)
            let crc = u32(cd, p + 16), cs = u32(cd, p + 20), us = u32(cd, p + 24)
            let fnl = Int(u16(cd, p + 28)), exl = Int(u16(cd, p + 30)), cml = Int(u16(cd, p + 32))
            let ea = u32(cd, p + 38), off = u32(cd, p + 42)
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + fnl))
            entries.append(Entry(name: String(decoding: nameData, as: UTF8.self), flag: fl, method: me, time: tm, date: dt, crc: crc, csize: cs, usize: us, offset: off, extAttr: ea))
            // 保留原始名字节用于回写
            rawNames.append(nameData)
            p += 46 + fnl + exl + cml
        }
        return true
    }
    var rawNames: [Data] = []
    func read(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        try? fh.seek(toOffset: UInt64(e.offset))
        guard let h = try? fh.read(upToCount: 30), h.count == 30, u32(h, 0) == 0x04034b50 else { return nil }
        let skip = Int(u16(h, 26)) + Int(u16(h, 28))
        try? fh.seek(toOffset: UInt64(e.offset) + 30 + UInt64(skip))
        guard let comp = try? fh.read(upToCount: Int(e.csize)) else { return nil }
        if e.method == 0 { return comp }
        guard e.method == 8 else { return nil }
        var out = Data(count: Int(e.usize))
        let n = out.withUnsafeMutableBytes { ob in comp.withUnsafeBytes { ib in
            compression_decode_buffer(ob.bindMemory(to: UInt8.self).baseAddress!, Int(e.usize), ib.bindMemory(to: UInt8.self).baseAddress!, comp.count, nil, COMPRESSION_ZLIB) } }
        return n == Int(e.usize) ? out : nil
    }
    static func crc32(_ d: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }; table[i] = c }
        var c: UInt32 = 0xffffffff
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
    static func deflate(_ d: Data) -> Data? {
        var out = Data(count: d.count + d.count / 8 + 1024)
        let n = out.withUnsafeMutableBytes { ob in d.withUnsafeBytes { ib in
            compression_encode_buffer(ob.bindMemory(to: UInt8.self).baseAddress!, ob.count, ib.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB) } }
        guard n > 0 else { return nil }
        return out.prefix(n)
    }
    /// 删除 customSite 中 id 在 ids 的行并写出新 zip；其余条目压缩字节原样拷贝
    func rewrite(deleteIds: [Int], to out: URL) -> String? {
        guard let sql = read("sql.mrbf") else { return "读取 sql.mrbf 失败" }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pb_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try sql.write(to: tmp) } catch { return "写临时库失败" }
        var db: OpaquePointer?
        guard sqlite3_open(tmp.path, &db) == SQLITE_OK else { return "打开数据库失败" }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "pragma journal_mode=delete", nil, nil, nil)
        sqlite3_exec(db, "begin", nil, nil, nil)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "delete from customSite where id=?", -1, &st, nil)
        for i in deleteIds { sqlite3_bind_int64(st, 1, Int64(i)); sqlite3_step(st); sqlite3_reset(st) }
        sqlite3_finalize(st)
        guard sqlite3_exec(db, "commit", nil, nil, nil) == SQLITE_OK else { return "提交失败" }
        sqlite3_exec(db, "vacuum", nil, nil, nil)
        // 校验
        var chk: OpaquePointer?; sqlite3_prepare_v2(db, "pragma integrity_check", -1, &chk, nil)
        var okc = false; if sqlite3_step(chk) == SQLITE_ROW, let t = sqlite3_column_text(chk, 0) { okc = String(cString: t) == "ok" }
        sqlite3_finalize(chk)
        guard okc else { return "数据库完整性校验失败，已放弃" }
        sqlite3_close(db); db = nil
        guard let newSql = try? Data(contentsOf: tmp), let comp = Backup.deflate(newSql) else { return "压缩失败" }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let o = try? FileHandle(forWritingTo: out) else { return "创建输出失败" }
        defer { try? o.close() }
        func w16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        func w32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        var cdRecs: [(Entry, Data, UInt32)] = []   // entry(新), name, offset
        var off: UInt32 = 0
        for (idx, e) in entries.enumerated() {
            let nm = rawNames[idx]
            var ne = e
            var body: Data
            if e.name == "sql.mrbf" {
                body = comp; ne.method = 8; ne.crc = Backup.crc32(newSql); ne.csize = UInt32(comp.count); ne.usize = UInt32(newSql.count); ne.flag = e.flag & ~UInt16(8)
            } else {
                try? fh.seek(toOffset: UInt64(e.offset))
                guard let h = try? fh.read(upToCount: 30), h.count == 30 else { return "读取条目失败：\(e.name)" }
                let skip = Int(u16(h, 26)) + Int(u16(h, 28))
                try? fh.seek(toOffset: UInt64(e.offset) + 30 + UInt64(skip))
                body = (try? fh.read(upToCount: Int(e.csize))) ?? Data()
                guard body.count == Int(e.csize) else { return "条目长度不符：\(e.name)" }
                ne.flag = e.flag & ~UInt16(8)
            }
            ne.offset = off
            var hdr = Data()
            hdr += w32(0x04034b50); hdr += w16(20); hdr += w16(ne.flag); hdr += w16(ne.method); hdr += w16(ne.time); hdr += w16(ne.date)
            hdr += w32(ne.crc); hdr += w32(ne.csize); hdr += w32(ne.usize); hdr += w16(UInt16(nm.count)); hdr += w16(0)
            o.write(hdr); o.write(nm); o.write(body)
            off += UInt32(hdr.count + nm.count + body.count)
            cdRecs.append((ne, nm, ne.offset))
        }
        let cdStart = off
        var cdSize: UInt32 = 0
        for (e, nm, _) in cdRecs {
            var r = Data()
            r += w32(0x02014b50); r += w16(20); r += w16(20); r += w16(e.flag); r += w16(e.method); r += w16(e.time); r += w16(e.date)
            r += w32(e.crc); r += w32(e.csize); r += w32(e.usize); r += w16(UInt16(nm.count)); r += w16(0); r += w16(0); r += w16(0); r += w16(0)
            r += w32(e.extAttr); r += w32(e.offset)
            o.write(r); o.write(nm); cdSize += UInt32(r.count + nm.count)
        }
        var end = Data()
        end += w32(0x06054b50); end += w16(0); end += w16(0); end += w16(UInt16(cdRecs.count)); end += w16(UInt16(cdRecs.count)); end += w32(cdSize); end += w32(cdStart); end += w16(0)
        o.write(end)
        return nil
    }
    /// 读取 customSite → [[id, ident, name, url, xpath]]
    func sites() -> [[Any]]? {
        guard let sql = read("sql.mrbf") else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pbr_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? sql.write(to: tmp)) != nil else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select id,siteIdent,siteName,url,xpath from customSite order by \"index\",id", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        func col(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out: [[Any]] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append([Int(sqlite3_column_int64(st, 0)), col(1), col(2), col(3), col(4)]) }
        return out
    }
}

// MARK: - 主界面
final class VC: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIDocumentPickerDelegate {
    var backup: Backup?
    var pickReply: String?
    var backupURL: URL?
    var web: WKWebView!
    let net = Net()
    lazy var jsbox = JSBox(net: net)
    let jsq = DispatchQueue(label: "js", qos: .userInitiated, attributes: .concurrent)
    let jsSem = DispatchSemaphore(value: 4)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        let cfg = WKWebViewConfiguration()
        let www = Bundle.main.bundleURL.appendingPathComponent("www")
        cfg.setURLSchemeHandler(SchemeHandler(root: www), forURLScheme: "app")
        cfg.userContentController.add(self, name: "native")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self; web.uiDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        web.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
    }

    func reply(_ id: String, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web.evaluateJavaScript("window.__nativeReply && window.__nativeReply(\(String(reflecting: id)), \(json))", completionHandler: nil)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let id = d["id"] as? String, let op = d["op"] as? String else { return }
        let p = d["payload"] as? [String: Any] ?? [:]
        switch op {
        case "http":
            var hs = [String: String](); for (k, v) in (p["headers"] as? [String: Any] ?? [:]) { hs["\(k)"] = "\(v)" }
            let body: Data? = (p["body"] as? String).flatMap { $0.data(using: .utf8) }
            var bodyData = body
            if let cs = p["charset"] as? String, !cs.isEmpty, let s = p["body"] as? String, let e = Net.encoding(cs) { bodyData = s.data(using: e, allowLossyConversion: true) }
            net.send(url: p["url"] as? String ?? "", method: (p["method"] as? String ?? "GET").uppercased(), headers: hs, body: bodyData,
                     charset: p["charset"] as? String ?? "", timeout: p["timeout"] as? Double ?? 12) { self.reply(id, $0) }
        case "enc":
            let s = p["s"] as? String ?? "", cs = p["cs"] as? String ?? "utf-8"
            let e = Net.encoding(cs) ?? .utf8
            let bytes = s.data(using: e, allowLossyConversion: true) ?? Data()
            let out = bytes.map { b -> String in
                let c = Character(UnicodeScalar(b))
                return (c.isASCII && (c.isLetter || c.isNumber || "-._~".contains(c))) ? String(c) : String(format: "%%%02X", b) }.joined()
            reply(id, ["v": out])
        case "jsEval":
            let input = (try? String(data: JSONSerialization.data(withJSONObject: p), encoding: .utf8)) ?? "{}"
            jsq.async {
                self.jsSem.wait(); defer { self.jsSem.signal() }
                let out = self.jsbox.run(input)
                let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) ?? ["ok": false, "err": "解析失败"]
                self.reply(id, obj)
            }
        case "pbPick":
            pickReply = id
            DispatchQueue.main.async {
                let pk = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.zip, UTType.data], asCopy: false)
                pk.delegate = self; pk.allowsMultipleSelection = false
                self.present(pk, animated: true)
            }
        case "pbExport":
            let ids = (p["ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            guard let b = backup else { return reply(id, ["ok": false, "err": "未载入备份"]) }
            let name = p["name"] as? String ?? "backup_cleaned.zip"
            DispatchQueue.global(qos: .userInitiated).async {
                let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: out)
                if let e = b.rewrite(deleteIds: ids, to: out) { return self.reply(id, ["ok": false, "err": e]) }
                let sz = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                DispatchQueue.main.async {
                    let vc = UIActivityViewController(activityItems: [out], applicationActivities: nil)
                    vc.popoverPresentationController?.sourceView = self.view
                    vc.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 40, width: 1, height: 1)
                    self.present(vc, animated: true)
                }
                self.reply(id, ["ok": true, "size": sz, "deleted": ids.count])
            }
        case "keepAwake":
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = (p["on"] as? Bool) ?? false }
            reply(id, ["ok": true])
        case "clipboardWrite":
            UIPasteboard.general.string = p["text"] as? String ?? ""; reply(id, ["ok": true])
        case "shareFile":
            let name = (p["name"] as? String ?? "export.json").replacingOccurrences(of: "/", with: "_")
            guard let text = p["text"] as? String, let data = text.data(using: .utf8) else { return reply(id, ["ok": false]) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do { try data.write(to: url, options: .atomic) } catch { return reply(id, ["ok": false]) }
            DispatchQueue.main.async {
                let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                vc.popoverPresentationController?.sourceView = self.view
                vc.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 40, width: 1, height: 1)
                self.present(vc, animated: true)
            }
            reply(id, ["ok": true])
        default: reply(id, ["ok": false])
        }
    }

    // 文件选择回调：读取备份包的 customSite
    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let id = pickReply, let u = urls.first else { return }
        pickReply = nil
        let acc = u.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            // 拷到临时目录，避免安全域在后续读取时失效
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("backup_in.zip")
            try? FileManager.default.removeItem(at: tmp)
            do { try FileManager.default.copyItem(at: u, to: tmp) } catch {
                if acc { u.stopAccessingSecurityScopedResource() }
                return self.reply(id, ["ok": false, "err": "复制文件失败：\(error.localizedDescription)"]) }
            if acc { u.stopAccessingSecurityScopedResource() }
            guard let b = Backup(url: tmp) else { return self.reply(id, ["ok": false, "err": "不是有效的 zip（或为 zip64，暂不支持）"]) }
            guard b.entries.contains(where: { $0.name == "sql.mrbf" }) else { return self.reply(id, ["ok": false, "err": "备份包里没有 sql.mrbf，不是用心读书备份"]) }
            guard let rows = b.sites() else { return self.reply(id, ["ok": false, "err": "读取书源表失败"]) }
            self.backup = b
            self.reply(id, ["ok": true, "name": u.lastPathComponent, "sites": rows])
        }
    }
    func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
        if let id = pickReply { pickReply = nil; reply(id, ["ok": false, "err": "cancel"]) }
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() }); present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) }); present(a, animated: true)
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = VC()
        window?.makeKeyAndVisible()
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

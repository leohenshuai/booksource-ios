import UIKit
import WebKit
import JavaScriptCore
import CryptoKit
import Foundation

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

// MARK: - 主界面
final class VC: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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

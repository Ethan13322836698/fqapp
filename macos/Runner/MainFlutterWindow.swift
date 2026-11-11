import Cocoa
import FlutterMacOS
import WebKit
import IOKit.pwr_mgt

class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private var loginWindow: MacAccountWindow?
  private var powerAssertion: IOPMAssertionID = 0

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let originalFrame = frame
    contentViewController = controller
    setFrame(originalFrame, display: true)
    RegisterGeneratedPlugins(registry: controller)
    nativeChannel = FlutterMethodChannel(name: "fqapp/macos", binaryMessenger: controller.engine.binaryMessenger)
    nativeChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "setKeepAwake":
        let enabled = call.arguments as? Bool ?? false
        if enabled && self.powerAssertion == 0 {
          IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "什锦铺阅读与播放" as CFString, &self.powerAssertion)
        } else if !enabled && self.powerAssertion != 0 {
          IOPMAssertionRelease(self.powerAssertion)
          self.powerAssertion = 0
        }
        result(nil)
      case "decodeText":
        guard let bytes = call.arguments as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid_text", message: "无法读取 TXT", details: nil)); return
        }
        let data = bytes.data
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
          CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let hasUTF16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        let text = hasUTF16BOM ? String(data: data, encoding: .utf16)
          : (String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030))
        if let text = text {
          result(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text)
        } else { result(FlutterError(code: "text_encoding", message: "无法识别 TXT 编码", details: nil)) }
      case "login":
        if self.loginWindow != nil {
          result(FlutterError(code: "login_busy", message: "登录窗口已打开", details: nil)); return
        }
        self.loginWindow = MacAccountWindow { [weak self] cookie in
          self?.loginWindow = nil
          result(cookie)
        }
        self.loginWindow?.show()
      case "cancelLogin":
        self.loginWindow?.finish(nil)
        result(nil)
      case "clearSession":
        self.loginWindow?.finish(nil)
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
          modifiedSince: Date.distantPast) { result(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  deinit {
    if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion) }
  }
}

private final class MacAccountWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
  private let window: NSWindow
  private let webView: WKWebView
  private let status = NSTextField(labelWithString: "请完成番茄官方登录，再点读取书架。")
  private var completion: ((String?) -> Void)?

  init(completion: @escaping (String?) -> Void) {
    self.completion = completion
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    window.title = "番茄官方登录 · 只读导入"
    window.isReleasedWhenClosed = false
    window.delegate = self
    webView.navigationDelegate = self
    let read = NSButton(title: "读取书架", target: self, action: #selector(readCookies))
    let footer = NSStackView(views: [status, read])
    footer.orientation = .horizontal
    footer.spacing = 12
    footer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    let stack = NSStackView(views: [webView, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    webView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.spacing = 0
    window.contentView = stack
    webView.setContentHuggingPriority(.defaultLow, for: .vertical)
  }

  func show() {
    window.center()
    window.makeKeyAndOrderFront(nil)
    webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/main/writer/login")!))
  }

  func finish(_ cookie: String?) {
    guard let completion = completion else { return }
    self.completion = nil
    webView.stopLoading()
    window.close()
    completion(cookie)
  }

  func windowWillClose(_ notification: Notification) { finish(nil) }

  @objc private func readCookies() {
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self = self else { return }
      let allowed = cookies.filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      guard allowed.contains(where: { ["sessionid", "sessionid_ss", "sid_tt"].contains($0.name) && !$0.value.isEmpty }) else {
        self.status.stringValue = "尚未取得有效登录态，请先完成官方登录。"; return
      }
      let header = allowed.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      guard header.utf8.count <= 12 * 1024 else {
        self.status.stringValue = "登录数据过大，请清除会话后重试。"; return
      }
      self.finish(header)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url,
      url.scheme == "https", url.user == nil, url.password == nil, let host = url.host,
      ["fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
      }), navigationAction.targetFrame != nil else {
      status.stringValue = "已阻止离开官方登录域名。"
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
}

import Flutter
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  let flutterEngine = FlutterEngine(name: "clawmate_engine")

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)
    if let registrar = flutterEngine.registrar(forPlugin: "WidgetDataBridge") {
      WidgetDataBridge.register(with: registrar)
    }
    registerLauncherChannel()
    registerClipboardChannel()
    let vc = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
    let newWindow = UIWindow(windowScene: windowScene)
    newWindow.rootViewController = vc
    newWindow.makeKeyAndVisible()
    self.window = newWindow
  }

  private func registerLauncherChannel() {
    let channel = FlutterMethodChannel(
      name: "com.clawmate.launcher",
      binaryMessenger: flutterEngine.binaryMessenger
    )
    channel.setMethodCallHandler { (call, result) in
      guard let urlString = call.arguments as? String,
            let url = URL(string: urlString) else {
        result(FlutterError(code: "INVALID_URL", message: nil, details: nil))
        return
      }
      switch call.method {
      case "canOpenURL":
        result(UIApplication.shared.canOpenURL(url))
      case "openURL":
        UIApplication.shared.open(url, options: [:]) { success in
          result(success)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerClipboardChannel() {
    let channel = FlutterMethodChannel(
      name: "com.clawmate.clipboard",
      binaryMessenger: flutterEngine.binaryMessenger
    )
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "hasImage":
        result(UIPasteboard.general.hasImages)
      case "getImageBase64":
        guard let image = UIPasteboard.general.image else {
          result(nil)
          return
        }
        if let png = image.pngData() {
          result([
            "format": "png",
            "data": png.base64EncodedString(),
          ])
          return
        }
        if let jpg = image.jpegData(compressionQuality: 0.9) {
          result([
            "format": "jpg",
            "data": jpg.base64EncodedString(),
          ])
          return
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

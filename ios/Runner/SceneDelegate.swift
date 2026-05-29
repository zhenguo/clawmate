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
    let vc = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
    let newWindow = UIWindow(windowScene: windowScene)
    newWindow.rootViewController = vc
    newWindow.makeKeyAndVisible()
    self.window = newWindow
  }
}

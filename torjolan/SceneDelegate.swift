import UIKit
import SwiftUI
import CarPlay

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var carPlayDelegate: CarPlaySceneDelegate?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            let contentView = ContentView()
            let hostingController = UIHostingController(rootView: contentView)
            window.rootViewController = hostingController
            self.window = window
            window.makeKeyAndVisible()
        } else if let carPlayScene = scene as? CPTemplateApplicationScene {
            // Initialize CarPlay delegate
            carPlayDelegate = CarPlaySceneDelegate()
            carPlayDelegate?.templateApplicationScene(carPlayScene, didConnect: carPlayScene.interfaceController)
        }
    }
    
    func scene(_ scene: UIScene, didDisconnect session: UISceneSession) {
        if let carPlayScene = scene as? CPTemplateApplicationScene {
            carPlayDelegate?.templateApplicationScene(carPlayScene, didDisconnect: carPlayScene.interfaceController)
            carPlayDelegate = nil
        }
    }
    
    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace, interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation, traitCollection previousTraitCollection: UITraitCollection) {
        // Handle window scene updates if needed
    }
}


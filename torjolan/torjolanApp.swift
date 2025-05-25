//
//  torjolanApp.swift
//  torjolan
//
//  Created by line72 on 5/15/25.
//

import SwiftUI
import CarPlay

@main
struct torjolanApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    init() {
        // If we have a host but no token, still configure the API
        if let savedHost = HostSettings.shared.host {
            APIService.configure(baseURL: savedHost)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let sceneConfig = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        
        if connectingSceneSession.role == .carTemplateApplication {
            sceneConfig.delegateClass = CarPlaySceneDelegate.self
        } else {
            sceneConfig.delegateClass = SceneDelegate.self
        }
        
        return sceneConfig
    }
}

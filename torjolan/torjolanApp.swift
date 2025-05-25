//
//  torjolanApp.swift
//  torjolan
//
//  Created by line72 on 5/15/25.
//

import SwiftUI

@main
struct torjolanApp: App {
    @State private var isLoggedIn = false
    
    init() {
        // Configure API with saved host or default
        if let savedHost = HostSettings.shared.host {
            APIService.configure(baseURL: savedHost)
        }
        
        // Check for saved token and set up initial login state
        if let token = try? KeychainManager.shared.loadToken() {
            APIService.shared.authToken = token
            _isLoggedIn = State(initialValue: true)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationView {
                if isLoggedIn {
                    StationListView()
                } else {
                    LoginView(isLoggedIn: $isLoggedIn)
                }
            }
            .tint(Color(red: 0, green: 0.749, blue: 1.0)) // #00BFFF
        }
    }
}

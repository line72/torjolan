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
        // Only consider user logged in if both host and token exist
        if let savedHost = HostSettings.shared.host,
           let token = try? KeychainManager.shared.loadToken() {
            // We have both host and token
            APIService.configure(baseURL: savedHost)
            APIService.setAuthToken(authToken: token)
            _isLoggedIn = State(initialValue: true)
        } else {
            // Missing either host or token, ensure logged out state
            _isLoggedIn = State(initialValue: false)
            
            // If we have a host but no token, still configure the API
            if let savedHost = HostSettings.shared.host {
                APIService.configure(baseURL: savedHost)
            }
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

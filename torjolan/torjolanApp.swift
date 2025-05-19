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
        #if DEBUG
        APIService.configure(baseURL: "https://boldaric.line72.net") // Development server
        #else
        APIService.configure(baseURL: "https://boldaric.line72.net") // Production server
        #endif
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
        }
    }
}

import SwiftUI

struct ContentView: View {
    @State private var isLoggedIn = false
    
    var body: some View {
        Group {
            if isLoggedIn {
                NavigationStack {
                    StationListView(isLoggedIn: $isLoggedIn)
                }
                .tint(Color(red: 0, green: 0.749, blue: 1.0)) // #00BFFF
            } else {
                NavigationStack {
                    LoginView(isLoggedIn: $isLoggedIn)
                }
                .tint(Color(red: 0, green: 0.749, blue: 1.0)) // #00BFFF
            }
        }
        .onAppear {
            checkLoginState()
        }
    }
    
    func checkLoginState() {
        // Check if we have both a host and a valid token
        if let savedHost = HostSettings.shared.host,
           let token = try? KeychainManager.shared.loadToken() {
            // Configure API with saved credentials
            APIService.configure(baseURL: savedHost)
            APIService.setAuthToken(authToken: token)
            // Set logged in state
            isLoggedIn = true
        } else {
            isLoggedIn = false
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
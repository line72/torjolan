import Foundation

struct User: Codable {
    let id: Int
    let username: String
    let token: String
    
    static var current: User? {
        didSet {
            if let user = current {
                // Save token to Keychain when user is set
                try? KeychainManager.shared.saveToken(user.token)
            } else {
                // Remove token from Keychain when user is cleared
                try? KeychainManager.shared.deleteToken()
            }
        }
    }
    
    init(from authResponse: AuthResponse) {
        self.id = authResponse.id
        self.username = authResponse.username
        self.token = authResponse.token
    }
    
    static func loadSavedUser() {
        if let token = try? KeychainManager.shared.loadToken() {
            // Set the token in APIService
            APIService.shared.authToken = token
        }
    }
} 
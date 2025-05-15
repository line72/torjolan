import Foundation

struct User: Codable {
    let id: Int
    let username: String
    let token: String
    
    static var current: User?
    
    init(from authResponse: AuthResponse) {
        self.id = authResponse.id
        self.username = authResponse.username
        self.token = authResponse.token
    }
} 
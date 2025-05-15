import Foundation

struct User: Codable {
    let id: String
    let username: String
    
    static var current: User?
} 
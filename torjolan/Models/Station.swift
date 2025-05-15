import Foundation

struct Station: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let artworkURL: URL?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case artworkURL = "artwork_url"
    }
} 
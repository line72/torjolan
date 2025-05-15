import Foundation

struct Station: Identifiable, Codable {
    let id: Int
    let name: String
    
    // These will be populated from stream response
    var currentSong: Song?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
} 
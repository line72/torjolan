import Foundation

struct Song: Identifiable, Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let streamURL: URL
    let duration: TimeInterval
    var isLiked: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case artworkURL = "artwork_url"
        case streamURL = "stream_url"
        case duration
        case isLiked = "is_liked"
    }
} 
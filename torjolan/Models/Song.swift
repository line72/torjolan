import Foundation

struct Song: Identifiable, Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let cover_url: String?
    let url: String
    
    enum CodingKeys: String, CodingKey {
        case id = "song_id"
        case title
        case artist
        case album
        case cover_url
        case url
    }
    
    init(from streamResponse: StreamResponse) {
        self.id = streamResponse.song_id
        self.title = streamResponse.title
        self.artist = streamResponse.artist
        self.album = streamResponse.album
        self.cover_url = streamResponse.cover_url
        self.url = streamResponse.url
    }
} 
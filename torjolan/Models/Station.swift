import Foundation

struct Station: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    
    // These will be populated from stream response
    var currentSong: Song?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
    
    // Implement Equatable
    static func == (lhs: Station, rhs: Station) -> Bool {
        // Only compare id and name for equality, ignore currentSong
        // since it's a transient property that doesn't affect station identity
        return lhs.id == rhs.id && lhs.name == rhs.name
    }
    
    // Implement Hashable
    func hash(into hasher: inout Hasher) {
        // Only hash id and name, ignore currentSong
        hasher.combine(id)
        hasher.combine(name)
    }
} 
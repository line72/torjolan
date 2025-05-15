import Foundation

// Response types
struct AuthResponse: Codable {
    let token: String
    let id: Int
    let username: String
}

struct StationResponse: Codable {
    let id: Int
    let name: String
}

struct StreamResponse: Codable {
    let url: String
    let song_id: String
    let artist: String
    let title: String
    let album: String
    let cover_url: String
}

struct SearchResult: Codable {
    let id: String
    let artist: String
    let album: String
    let title: String
}

struct SuccessResponse: Codable {
    let success: Bool
}

enum APIError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case unauthorized
}

class APIService {
    static let shared = APIService()
    private let baseURL = "https://api.example.com" // Replace with your actual API base URL
    private var authToken: String?
    
    private init() {}
    
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    func login(username: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/api/auth") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["login": username]
        request.httpBody = try? JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        do {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            self.authToken = authResponse.token
            return authResponse
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    func fetchStations() async throws -> [StationResponse] {
        guard let url = URL(string: "\(baseURL)/api/stations") else {
            throw APIError.invalidURL
        }
        
        let request = authorizedRequest(url)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        return try JSONDecoder().decode([StationResponse].self, from: data)
    }
    
    func createStation(name: String, songId: String) async throws -> StationResponse {
        guard let url = URL(string: "\(baseURL)/api/stations") else {
            throw APIError.invalidURL
        }
        
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        
        let body = ["station_name": name, "song_id": songId]
        request.httpBody = try? JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        return try JSONDecoder().decode(StationResponse.self, from: data)
    }
    
    func getStationStream(stationId: Int) async throws -> StreamResponse {
        guard let url = URL(string: "\(baseURL)/api/stations/\(stationId)") else {
            throw APIError.invalidURL
        }
        
        let request = authorizedRequest(url)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        return try JSONDecoder().decode(StreamResponse.self, from: data)
    }
    
    func submitSongCompletion(stationId: Int, songId: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/stations/\(stationId)/\(songId)") else {
            throw APIError.invalidURL
        }
        
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        let result = try JSONDecoder().decode(SuccessResponse.self, from: data)
        return result.success
    }
    
    func thumbsUp(stationId: Int, songId: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/stations/\(stationId)/\(songId)/thumbs_up") else {
            throw APIError.invalidURL
        }
        
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        let result = try JSONDecoder().decode(SuccessResponse.self, from: data)
        return result.success
    }
    
    func thumbsDown(stationId: Int, songId: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/stations/\(stationId)/\(songId)/thumbs_down") else {
            throw APIError.invalidURL
        }
        
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        let result = try JSONDecoder().decode(SuccessResponse.self, from: data)
        return result.success
    }
    
    func searchSongs(artist: String? = nil, title: String? = nil) async throws -> [SearchResult] {
        var components = URLComponents(string: "\(baseURL)/api/search")
        var queryItems: [URLQueryItem] = []
        
        if let artist = artist {
            queryItems.append(URLQueryItem(name: "artist", value: artist))
        }
        if let title = title {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        
        let request = authorizedRequest(url)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.invalidResponse
        }
        
        return try JSONDecoder().decode([SearchResult].self, from: data)
    }
} 
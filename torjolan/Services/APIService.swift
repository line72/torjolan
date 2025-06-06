import Foundation

// Response types
struct AuthResponse: Codable {
    let token: String
    let id: Int
    let username: String
}

struct StationResponse: Codable, Equatable {
    let id: Int
    let name: String
}

struct StreamResponse: Codable, Equatable {
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

struct CreateStationResponse: Codable, Equatable {
    let station: StationResponse
    let track: StreamResponse
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
    private var baseURL: String
    var authToken: String? {
        didSet {
            // When token is updated, update the User.current if needed
            if let token = authToken,
               User.current?.token != token {
                // This is a simplified version. In a real app, you might want to
                // validate the token or refresh user data from the server
                // For now, we'll just ensure the token is saved
                try? KeychainManager.shared.saveToken(token)
            }
        }
    }
    
    private init() {
        self.baseURL = "https://api.example.com" // Default value
    }
    
    static func configure(baseURL: String) {
        shared.baseURL = baseURL
    }

    static func setAuthToken(authToken: String) {
        shared.authToken = authToken
    }
    
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
    
    func createStation(name: String, songId: String) async throws -> CreateStationResponse {
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
        
        return try JSONDecoder().decode(CreateStationResponse.self, from: data)
    }
    
    func getStationStream(stationId: Int) async throws -> StreamResponse {
        guard let url = URL(string: "\(baseURL)/api/station/\(stationId)") else {
            throw APIError.invalidURL
        }
        
        let request = authorizedRequest(url)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("Response is not HTTPURLResponse")
            throw APIError.invalidResponse
        }
        
        // Print response details
        print("Response status code: \(httpResponse.statusCode)")
        if let responseString = String(data: data, encoding: .utf8) {
            print("Response body: \(responseString)")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            print("Invalid response status: \(httpResponse.statusCode)")
            throw APIError.invalidResponse
        }
        
        return try JSONDecoder().decode(StreamResponse.self, from: data)
    }
    
    func thumbsUp(stationId: Int, songId: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/station/\(stationId)/\(songId)/thumbs_up") else {
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
        guard let url = URL(string: "\(baseURL)/api/station/\(stationId)/\(songId)/thumbs_down") else {
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
    
    func searchSongs(artist: String = "", title: String = "") async throws -> [SearchResult] {
        var components = URLComponents(string: "\(baseURL)/api/search")
        var queryItems: [URLQueryItem] = []
        
            queryItems.append(URLQueryItem(name: "artist", value: artist))
            queryItems.append(URLQueryItem(name: "title", value: title))
        
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

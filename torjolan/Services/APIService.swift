import Foundation

enum APIError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
}

class APIService {
    static let shared = APIService()
    private let baseURL = "https://api.example.com" // Replace with your actual API base URL
    private var authToken: String?
    
    private init() {}
    
    func login(username: String) async throws -> User {
        guard let url = URL(string: "\(baseURL)/login") else {
            throw APIError.invalidURL
        }
        
        let body = ["username": username]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        do {
            let user = try JSONDecoder().decode(User.self, from: data)
            return user
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    func fetchStations() async throws -> [Station] {
        guard let url = URL(string: "\(baseURL)/stations") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        do {
            let stations = try JSONDecoder().decode([Station].self, from: data)
            return stations
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    func fetchCurrentSong(stationId: String) async throws -> Song {
        guard let url = URL(string: "\(baseURL)/stations/\(stationId)/current") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        do {
            let song = try JSONDecoder().decode(Song.self, from: data)
            return song
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    func rateSong(songId: String, isLike: Bool) async throws {
        guard let url = URL(string: "\(baseURL)/songs/\(songId)/rate") else {
            throw APIError.invalidURL
        }
        
        let body = ["is_like": isLike]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
    }
    
    func setAuthToken(_ token: String) {
        self.authToken = token
    }
} 
//
//  URL+QueryParams.swift
//
import Foundation

extension URL {
    func addQueryParams(_ params: [String: String]) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var items = c?.queryItems ?? []
        params.forEach { name, value in
            items.removeAll { $0.name == name }
            items.append(.init(name: name, value: value))
        }
        c?.queryItems = items
        return c?.url ?? self
    }
}
// Usage: url.addQueryParams(["format": "mp3", "quality": "high"])

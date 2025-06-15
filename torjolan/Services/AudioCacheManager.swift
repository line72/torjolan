import Foundation
import UIKit

enum CacheError: Error {
    case fileNotFound
    case invalidURL
    case downloadError(Error)
    case fileSystemError(Error)
}

@MainActor
class AudioCacheManager: NSObject {
    static let shared = AudioCacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheSize: Int64 = 500 * 1024 * 1024 // 500MB
    private var activeDownloads: [String: (task: URLSessionDownloadTask, tempURL: URL?)] = [:]
    private var downloadCallbacks: [String: (Result<URL, Error>) -> Void] = [:]
    private let minimumPlaybackSize: Int64 = 1024 * 1024 // 1MB
    private var backgroundCompletionHandler: (() -> Void)?
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.torjolan.audiocache")
        config.isDiscretionary = true // Allow system to optimize download timing
        config.sessionSendsLaunchEvents = true // Notify app when download completes
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        // Get the cache directory URL
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("AudioCache", isDirectory: true)
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        super.init()
        
        // Start periodic cleanup
        startPeriodicCleanup()
    }
    
    // MARK: - Background Download Support
    
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }
    
    // MARK: - Cache Operations
    
    func getCachedFileURL(for songId: String) -> URL? {
        let fileURL = cacheDirectory.appendingPathComponent(songId)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
    
    func isCached(songId: String) -> Bool {
        let fileURL = cacheDirectory.appendingPathComponent(songId)
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    func downloadAndCache(url: String, songId: String) async throws -> URL {
        guard let remoteURL = URL(string: url) else {
            throw CacheError.invalidURL
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(songId)
        
        // If file already exists, return its URL
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        
        // If download is already in progress, wait for it
        if activeDownloads[songId] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                downloadCallbacks[songId] = { result in
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        // Start new download
        let downloadTask = session.downloadTask(with: remoteURL)
        activeDownloads[songId] = (downloadTask, nil)
        
        return try await withCheckedThrowingContinuation { continuation in
            downloadCallbacks[songId] = { result in
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            downloadTask.resume()
        }
    }
    
    func removeFromCache(songId: String) {
        let fileURL = cacheDirectory.appendingPathComponent(songId)
        try? fileManager.removeItem(at: fileURL)
        
        // Cancel any active download for this song
        if let download = activeDownloads[songId] {
            download.task.cancel()
            activeDownloads.removeValue(forKey: songId)
            downloadCallbacks.removeValue(forKey: songId)
        }
    }
    
    // MARK: - Cache Management
    
    private func startPeriodicCleanup() {
        // Run cleanup every hour
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.cleanupCache()
            }
        }
    }
    
    private func cleanupCache() async {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            
            // Sort files by modification date (oldest first)
            let sortedFiles = try fileURLs.sorted { url1, url2 in
                let date1 = try url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                let date2 = try url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                return date1 < date2
            }
            
            // Remove oldest files if total size exceeds maxCacheSize
            var totalSize = getCacheSize()
            if totalSize > maxCacheSize {
                for url in sortedFiles {
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        try fileManager.removeItem(at: url)
                        totalSize -= Int64(size)
                        if totalSize <= maxCacheSize {
                            break
                        }
                    }
                }
            }
        } catch {
            print("Failed to cleanup cache: \(error)")
        }
    }
    
    func getCacheSize() -> Int64 {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            return try fileURLs.reduce(0) { sum, url in
                sum + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        } catch {
            print("Failed to get cache size: \(error)")
            return 0
        }
    }
}

// MARK: - URLSessionDelegate
extension AudioCacheManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let songId = activeDownloads.first(where: { $0.value.task == downloadTask })?.key else {
                return
            }
            
            let fileURL = cacheDirectory.appendingPathComponent(songId)
            
            do {
                // If file exists, remove it first
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                
                // Move the downloaded file to our cache directory
                try fileManager.moveItem(at: location, to: fileURL)
                
                // Clean up download tracking
                activeDownloads.removeValue(forKey: songId)
                
                // Notify completion only if we haven't already notified for playback
                if let callback = downloadCallbacks[songId] {
                    callback(.success(fileURL))
                    downloadCallbacks.removeValue(forKey: songId)
                }
            } catch {
                print("Failed to move downloaded file: \(error)")
                if let callback = downloadCallbacks[songId] {
                    callback(.failure(error))
                    downloadCallbacks.removeValue(forKey: songId)
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let songId = activeDownloads.first(where: { $0.value.task == downloadTask })?.key else {
                return
            }
            
            // If we have enough data to start playing and haven't notified yet
            if totalBytesWritten >= minimumPlaybackSize,
               let callback = downloadCallbacks[songId],
               activeDownloads[songId]?.tempURL == nil {
                // Store the temporary URL
                activeDownloads[songId]?.tempURL = downloadTask.originalRequest?.url
                
                // Notify that we can start playing
                callback(.success(downloadTask.originalRequest!.url!))
                // Remove the callback to prevent multiple notifications
                downloadCallbacks.removeValue(forKey: songId)
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard let downloadTask = task as? URLSessionDownloadTask,
                  let songId = activeDownloads.first(where: { $0.value.task == downloadTask })?.key else {
                return
            }
            
            if let error = error {
                print("Download failed: \(error)")
                if let callback = downloadCallbacks[songId] {
                    callback(.failure(error))
                    downloadCallbacks.removeValue(forKey: songId)
                }
            }
            
            activeDownloads.removeValue(forKey: songId)
        }
    }
    
    // Handle background session completion
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
} 
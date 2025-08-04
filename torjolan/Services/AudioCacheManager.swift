import Foundation

class AudioCacheManager: NSObject {
    // Shared instance for singleton access
    static let shared = AudioCacheManager()
    
    // Maximum cache size in bytes (500MB)
    private let maxCacheSize: Int64 = 500 * 1024 * 1024

    // Minimum data we need to start playing in bytes (2k)
    private let minPlaySize: Int64 = 2048
    
    // Directory for caching audio files
    private var cacheDirectory: URL
    
    // Track ongoing downloads
    private var downloadTasks = [String: DownloadTask]()
    
    // Download queue
    private var pendingDownloads = [String: Download]()
    
    // Maximum concurrent downloads
    private let maxConcurrentDownloads = 2
    
    // MARK: - Initializer
    
    private override init() {
        // Create cache directory in Caches folder
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("audio_cache")
        
        super.init()
        
        // Create directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, 
                                                    withIntermediateDirectories: true, 
                                                    attributes: nil)
        } catch {
            print("Failed to create cache directory: \(error)")
        }
        
        // Set attributes to prevent iCloud backup
        do {
            try setNoiCloudBackup()
        } catch {
            print("Failed to set iCloud backup attributes: \(error)")
        }
    }
    
    // MARK: - Public Interface
    
    /// Download a file and return a promise with the local file URL
    /// - Parameters:
    ///   - songId: Unique identifier for the song
    ///   - url: Remote URL of the audio file
    func download(songId: String, url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            // If already cached, return immediately
            let fileURL = cachedURL(for: songId)
            
            // Check if file exists and has enough data to play
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Check if we have at least 2KB of data
                do {
                    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    let fileSize = values.fileSize ?? 0
                    
                    if fileSize >= minPlaySize {
                        continuation.resume(returning: fileURL)
                        return
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
            }
            
            // If already downloading, add to completion handlers
            if let task = downloadTasks[songId] {
                task.completionHandlers.append { result in
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                return
            }
            
            // Create a new download
            let download = Download(songId: songId, url: url, fileURL: fileURL)
            let task = DownloadTask()
            
            // Add completion handler
            task.completionHandlers.append { result in
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Store task
            downloadTasks[songId] = task
            
            // Start download if we have capacity, else queue it
            if activeDownloadsCount() < maxConcurrentDownloads {
                startDownload(download, task: task)
            } else {
                pendingDownloads[songId] = download
            }
        }
    }
    
    /// Queue a download for pre-fetching
    func queue(songId: String, url: URL) {
        let fileURL = cachedURL(for: songId)
        
        // If already cached, do nothing
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        
        // If already downloading, do nothing
        if downloadTasks[songId] != nil {
            return
        }
        
        // Create download task
        let download = Download(songId: songId, url: url, fileURL: fileURL)
        
        // Add to queue
        pendingDownloads[songId] = download
        
        // Start download if we have capacity
        if activeDownloadsCount() < maxConcurrentDownloads {
            if let nextDownload = nextPendingDownload() {
                startDownload(nextDownload.download, task: nextDownload.task)
            }
        }
    }
    
    /// Remove a file from the cache
    func remove(songId: String) {
        let fileURL = cachedURL(for: songId)
        
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                print("Successfully deleted cached file: \(fileURL)")
            }
        } catch {
            print("Failed to delete cached file: \(error)")
        }
    }
    
    /// Clean up the cache to stay under size limit
    func cleanup() async {
        await withCheckedContinuation { continuation in
            cleanupCache {
                continuation.resume()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func cachedURL(for songId: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(songId).audio")
    }
    
    private func startDownload(_ download: Download, task: DownloadTask) {
        // Create background session configuration
        let config = URLSessionConfiguration.default
        config.isDiscretionary = true
        
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Start request
        let downloadTask = session.downloadTask(with: download.url)
        downloadTask.taskDescription = download.songId
        
        // Store the download info and start
        downloadTask.resume()
        
        // Add to active downloads
        downloadTasks[download.songId] = task
    }
    
    // Check if we have enough data to start playing
    private func checkReadyToPlay(for songId: String, at bytesWritten: Int64) {
        guard bytesWritten >= minPlaySize, 
              let task = downloadTasks[songId] else {
            return
        }
        
        let fileURL = cachedURL(for: songId)
        
        // Only call readyToPlay once
        guard !task.hasFiredReadyToPlay else {
            return
        }
        
        do {
            // Make sure file exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }
            
            // Get file size
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = values.fileSize ?? 0
            
            // Only proceed if we have at least 2KB
            guard fileSize >= minPlaySize else {
                return
            }
            
            // Mark that we've fired the readyToPlay event
            task.hasFiredReadyToPlay = true
            
            // Notify completion handlers that we can play
            DispatchQueue.main.async {
                task.completionHandlers.forEach { handler in
                    handler(.success(fileURL))
                }
            }
        } catch {
            // If we have any error, propagate it to the completion handlers
            DispatchQueue.main.async {
                task.completionHandlers.forEach { handler in
                    handler(.failure(error))
                }
            }
        }
    }
    
    private func nextPendingDownload() -> (download: Download, task: DownloadTask)? {
        // Get the oldest pending download
        guard let songId = Array(pendingDownloads.keys).sorted().first else {
            return nil
        }
        
        guard let download = pendingDownloads[songId] else {
            return nil
        }
        
        pendingDownloads.removeValue(forKey: songId)
        
        let task = DownloadTask()
        downloadTasks[songId] = task
        
        return (download, task)
    }
    
    private func activeDownloadsCount() -> Int {
        return downloadTasks.filter { task in
            task.value.hasFiredReadyToPlay == false
        }.count
    }
    
    private func cleanupCache(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                // Get all files in cache
                let contents = try FileManager.default.contentsOfDirectory(
                    at: self.cacheDirectory, 
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: .skipsHiddenFiles
                )
                
                // Sort files by modification date (oldest first)
                let sortedFiles = contents.sorted {
                    (url1, url2) -> Bool in
                    let values1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey])
                    let date1 = values1?.contentModificationDate
                    
                    let values2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey])
                    let date2 = values2?.contentModificationDate
                    
                    return date1?.compare(date2!) == .orderedAscending
                }
                
                // Calculate current size
                var totalSize: Int64 = 0
                var fileSizes = [URL: Int64]()
                
                for fileURL in sortedFiles {
                    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    let fileSize = values.fileSize ?? 0
                    fileSizes[fileURL] = Int64(fileSize)
                    totalSize += Int64(fileSize)
                }
                
                // If under limit, nothing to do
                if totalSize < self.maxCacheSize {
                    completion()
                    return
                }
                
                // Delete oldest files until under limit
                var totalDeleted: Int64 = 0
                for fileURL in sortedFiles {
                    guard let fileSize = fileSizes[fileURL] else { continue }
                    
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        totalDeleted += fileSize
                        
                        if (totalSize - totalDeleted) < self.maxCacheSize {
                            break
                        }
                    } catch {
                        print("Failed to delete file \(fileURL): \(error)")
                    }
                }
                
                completion()
            } catch {
                print("Failed to cleanup cache: \(error)")
                completion()
            }
        }
    }
    
    private func setNoiCloudBackup() throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try cacheDirectory.setResourceValues(resourceValues)
    }
    
    private func resumePendingDownloads() {
        // Start as many pending downloads as we can
        while activeDownloadsCount() < maxConcurrentDownloads, 
              let nextDownload = nextPendingDownload() {
            startDownload(nextDownload.download, task: nextDownload.task)
        }
    }
}

// MARK: - URLSessionDelegate

extension AudioCacheManager: URLSessionDelegate {
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            print("URL Session invalidated: \(error)")
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension AudioCacheManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, 
                    downloadTask: URLSessionDownloadTask, 
                    didFinishDownloadingTo location: URL) {
        guard let songId = downloadTask.taskDescription else {
            print("Download finished without song ID")
            return
        }
        
        guard let download = downloadTasks[songId] else {
            print("No download task found for song ID: \(songId)")
            return
        }
        
        // Move file to cache location
        let destinationURL = cachedURL(for: songId)
        
        do {
            // Remove existing file if it exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            // Move file to cache
            try FileManager.default.moveItem(at: location, to: destinationURL)
            
            // Notify completion handlers
            DispatchQueue.main.async {
                download.completionHandlers.forEach { handler in
                    handler(.success(destinationURL))
                }
            }
        } catch {
            // Notify error
            DispatchQueue.main.async {
                download.completionHandlers.forEach { handler in
                    handler(.failure(error))
                }
            }
        }
        
        // Remove from active downloads
        downloadTasks.removeValue(forKey: songId)
        
        // Start any pending downloads
        resumePendingDownloads()
    }
    
    func urlSession(_ session: URLSession, 
                    task: URLSessionTask, 
                    didCompleteWithError error: Error?) {
        guard let songId = task.taskDescription else { return }
        
        guard let download = downloadTasks[songId] else { return }
        
        if let error = error {
            // Notify error
            DispatchQueue.main.async {
                download.completionHandlers.forEach { handler in
                    handler(.failure(error))
                }
            }
        }
        
        // Remove from active downloads
        downloadTasks.removeValue(forKey: songId)
        
        // Start any pending downloads
        resumePendingDownloads()
    }
    
    func urlSession(_ session: URLSession, 
                    downloadTask: URLSessionDownloadTask, 
                    didWriteData bytesWritten: Int64, 
                    totalBytesWritten: Int64, 
                    totalBytesExpectedToWrite: Int64) {
        guard let songId = downloadTask.taskDescription else { return }
        
        // Check if we have enough data to start playing
        checkReadyToPlay(for: songId, at: totalBytesWritten)
    }
}

// MARK: - Helper Types

private struct Download {
    let songId: String
    let url: URL
    let fileURL: URL
    var task: URLSessionDownloadTask?
}

private class DownloadTask {
    var completionHandlers = [(Result<URL, Error>) -> Void]()
    var hasFiredReadyToPlay = false
}

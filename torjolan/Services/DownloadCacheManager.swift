//
//  DownloadCacheManager.swift
//

import Foundation
import os.log

// MARK: - Public API
public actor DownloadCacheManager {
    static let shared = DownloadCacheManager()

    // MARK: Init / configuration
    private init(
        maxConcurrent: Int = 2,
        cacheSizeLimitBytes: UInt64 = 500 * 1_024 * 1_024  // 500 MB
    ) {
        precondition(maxConcurrent > 0)
        self.maxConcurrent = maxConcurrent
        self.sizeLimit = cacheSizeLimitBytes

        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        cacheDir = caches.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true, attributes: nil
        )

        session = URLSession(configuration: .default)
    }

    // MARK: Public interface
    func cancel(songId: String) {
        os_log("Cancel: %@", log: self.appLog, type: .info, songId)
        self.activeTasks[songId]?.cancel()
        self.activeTasks.removeValue(forKey: songId)
    }
    
    @discardableResult
    func queue(song: Song, url: URL) async -> StreamLoader {
        os_log("Queue: %@: %@ - %@", log: self.appLog, type: .info, song.id, song.artist, song.title)
        return await addToQueue(insertAtHead: false, songId: song.id, url: url)
    }

    @discardableResult
    func queueFirst(song: Song, url: URL) async -> StreamLoader {
        os_log("QueueFirst: %@: %@ - %@", log: self.appLog, type: .info, song.id, song.artist, song.title)
        return await addToQueue(insertAtHead: true, songId: song.id, url: url)
    }

    @discardableResult
    func addToQueue(insertAtHead: Bool, songId: String, url: URL) async -> StreamLoader {
        os_log("addToQueue at head? %d: %@", log: self.appLog, type: .info, insertAtHead, songId)
        os_log("Active Downloads: %d", log: self.appLog, type: .info, active.count)
        os_log("Pending Downloads: %d", log: self.appLog, type: .info, pending.count)

        // if transcode is enabled, convert to mp3
        var downloadUrl = url
        if (self.transcode) {
            downloadUrl = url.addQueryParams(["format": "mp3"])
        }
        os_log("url=%@", log: self.appLog, type: .debug, downloadUrl.absoluteString)
        
        let dest = destinationURL(for: songId, remoteURL: downloadUrl)
        touchFileAccessDate(dest)

        if !(isFileComplete(dest) ?? false) &&
             !pending.contains(where: { $0.songId == songId }) &&
             !active.contains(where: { $0.songId == songId }) {
            os_log("Song: %@ is being added to queue which has %d songs in it", log: self.appLog, type: .debug, songId, self.pending.count)

            // do a HEAD on the request, we need some metadata
            let meta0  = FileMeta(remoteURL: downloadUrl)
            let meta = await metaWithHeadInfo(meta0)
            try? writeMeta(meta, for: dest)

            let streamLoader = StreamLoader(songId: songId, contentType: meta.contentType ?? "audio/mpeg", contentSize: Int64(meta.contentLength ?? 0))
            if (insertAtHead) {
                pending.insert(DownloadRequest(songId: songId, remote: downloadUrl, streamLoader: streamLoader), at: 0)
                // force this download to start. We may go over our
                // max concurrent downloads, but that is ok
                scheduleWorkIfNeeded(force: true)
            } else {
                pending.append(DownloadRequest(songId: songId, remote: downloadUrl, streamLoader: streamLoader))
                scheduleWorkIfNeeded()
            }
            

            return streamLoader
        } else if let index = pending.firstIndex(where: { $0.songId == songId }) {
            os_log("Song: %@ is in pending list already", log: self.appLog, type: .debug, songId)
            // This item is in our pending queue,
            // return a handle to the StreamLoader
            //
            if (insertAtHead) {
                // Move this to the top of the pending queue
                let item = pending.remove(at: index);
                pending.insert(item, at: 0)
                return item.streamLoader
            } else {
                return pending[index].streamLoader
            }
        } else if let index = active.firstIndex(where: { $0.songId == songId }) {
            os_log("Song: %@ is in active list already", log: self.appLog, type: .debug, songId)
            // This item is in our active download queue,
            // return a handle to the StreamLoader
            //
            return active[index].streamLoader
        } else {
            os_log("Song: %@ is cached!", log: self.appLog, type: .debug, songId)

            var meta  = (try? readMeta(for: dest)) ?? FileMeta(remoteURL: downloadUrl)
            let fileSize = localFileSize(dest)
            if meta.contentLength == nil {
                // Backfill content length from local file size for accurate metadata
                meta.contentLength = fileSize
                try? writeMeta(meta, for: dest)
            }

            let streamLoader = StreamLoader(
              songId: songId,
              contentType: meta.contentType ?? "audio/mpeg",
              contentSize: Int64(meta.contentLength ?? fileSize)
            )

            // Read the cached file and feed it to the StreamLoader in chunks
            let readURL = dest
            Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: readURL)
                    defer { try? handle.close() }

                    let chunkSize = 64 * 1024
                    while true {
                        try Task.checkCancellation()
                        if let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                            streamLoader.appendData(data)
                        } else {
                            break
                        }
                    }
                    streamLoader.signalEndOfStream()
                } catch {
                    // On error, still signal end to unblock the player
                    streamLoader.signalEndOfStream()
                }
            }

            return streamLoader
        }
    }

    func remove(songId: String) {
        let url = destinationURL(for: songId, remoteURL: nil)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: metaURL(for: url))
    }

    func cleanup() async {
        await pruneIfNeeded(force: true)
    }

    // MARK: - Internal storage
    private let transcode: Bool = false
    private let maxConcurrent: Int
    private let sizeLimit: UInt64
    private let cacheDir: URL
    private let session: URLSession
    private var pending: [DownloadRequest] = []
    private var active: [DownloadRequest] = []
    private var activeTasks: [String: Task<()?, Never>] = [:] // songId -> Task
    private let appLog = OSLog(subsystem: "net.line72.torjolan", category: "DownloadCacheManager")

    // MARK: - Queue processing
    private func scheduleWorkIfNeeded(force: Bool = false) {
        // Only pass if force is true OR the active is less than our
        // max concurrent and we have pending items
        guard force || self.active.count < maxConcurrent, force || !pending.isEmpty else { return }

        let next = pending.removeFirst()
        self.active.append(next)

        let downloadTask = Task.detached { [weak self] in
            await self?.download(request: next)
        }

        self.activeTasks[next.songId] = downloadTask
    }

    private func download(request: DownloadRequest) async {
        os_log("Start Download: %@ | tasks: %d | active: %d | pending: %d", log: self.appLog, type: .info, request.songId, self.activeTasks.count, self.active.count, self.pending.count)
                 
        var fileHandle: FileHandle? = nil
        defer {
            try? fileHandle?.close()
        }

        let dest  = destinationURL(for: request.songId, remoteURL: request.remote)
        var meta  = (try? readMeta(for: dest)) ?? FileMeta(remoteURL: request.remote)

        // If we don't have an expected size yet, perform a HEAD to fetch it.
        // This _shouldn't_ happen, as we always do a HEAD request when an item
        //  is first queued
        if meta.contentLength == nil {
            meta = await metaWithHeadInfo(meta)
            try? writeMeta(meta, for: dest)
        }

        let currentSize = localFileSize(dest)
        if let expected = meta.contentLength, currentSize == expected, meta.complete {
            os_log("✓ Cached %@", log: self.appLog, type: .debug, request.songId); return
        }

        // !mwd - In the future, it would be cool to resume
        //  where we left off, but for now, we'll just restart
        
        // Prepare Range request if resuming.
        let req = URLRequest(url: request.remote)
        // if currentSize > 0 { req.setValue("bytes=\(currentSize)-", forHTTPHeaderField: "Range") }

        do {
            let (bytes, _) = try await session.bytes(for: req)
            prepareFileIfNeeded(at: dest)

            fileHandle = try FileHandle(forWritingTo: dest)
            // !mwd - In the future, we might resume
            //   we'd actually need to read these bytes to
            //   send to the StreamLoader though
            //try fileHandle?.seekToEnd()

            let bufferSize = 16 * 1024
            var buffer = Data(capacity: bufferSize)
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)

                if buffer.count >= bufferSize {
                    try fileHandle?.write(contentsOf: buffer)
                    request.streamLoader.appendData(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            // Flush remaining bytes in buffer
            if !buffer.isEmpty {
                os_log("Sending last few bytes of buffer: %d", log: self.appLog, type: .debug, buffer.count)
                
                try fileHandle?.write(contentsOf: buffer)
                request.streamLoader.appendData(buffer)
            }
            fileHandle = nil

            // signal end of stream
            request.streamLoader.signalEndOfStream()
            
            // Mark complete if sizes match (or server didn't specify length).
            let finalSize = localFileSize(dest)
            if (finalSize != meta.contentLength) {
                os_log("❌ final size of download is %d, but expected %d", log: self.appLog, type: .error, finalSize, meta.contentLength ?? 0)
            }
            if meta.contentLength == nil || finalSize == meta.contentLength {
                meta.complete = true
            }
            meta.lastValidated = Date()
            try? writeMeta(meta, for: dest)
            touchFileAccessDate(dest)

        } catch {
            // signal end of stream
            request.streamLoader.signalEndOfStream()

            if error is CancellationError {
                os_log("Download %@ has been cancelled", log: self.appLog, type: .info, request.songId)
            } else {
                os_log("❌ Download failed %@: %@", log: self.appLog, type: .error, request.songId, error.localizedDescription)

                os_log("❌ ========== DOWNLOAD FAILED ==========", log: self.appLog, type: .debug)
                os_log("❌ Song ID: %@", log: self.appLog, type: .debug, request.songId)
                os_log("❌ Remote URL: %@", log: self.appLog, type: .debug, request.remote as CVarArg)
                os_log("❌ Error: %@", log: self.appLog, type: .debug, String(describing: error))
                os_log("❌ Error Type: %@", log: self.appLog, type: .debug, String(reflecting: type(of: error)))
                
                if let nsError = error as NSError? {
                    os_log("❌ NSError Domain: %@", log: self.appLog, type: .debug, nsError.domain)
                    os_log("❌ NSError Code: %d", log: self.appLog, type: .debug, nsError.code as CVarArg)
                    os_log("❌ NSError UserInfo: %@", log: self.appLog, type: .debug, nsError.userInfo)
                }
                
                if let urlError = error as? URLError {
                    os_log("❌ URLError Code: %d", log: self.appLog, type: .debug, urlError.code.rawValue)
                    os_log("❌ URLError LocalizedDescription: %@", log: self.appLog, type: .debug, urlError.localizedDescription)
                    os_log("❌ URLError FailingURL: %@", log: self.appLog, type: .debug, urlError.failingURL?.absoluteString ?? "nil")
                }
                
                os_log("❌ ====================================", log: self.appLog, type: .debug)
            }
        }

        finishDownload(request: request)
        await pruneIfNeeded(force: false)
    }

    private func finishDownload(request: DownloadRequest) {
        os_log("Finished downloading song: %@", log: self.appLog, type: .debug, request.songId)
        if let index = self.active.firstIndex(where: { $0.songId == request.songId }) {
            self.active.remove(at: index)
        }
        // also remove the task
        self.activeTasks.removeValue(forKey: request.songId)
        
        scheduleWorkIfNeeded()
    }

    // MARK: - Helpers (paths / meta)
    private func destinationURL(for songId: String, remoteURL: URL?) -> URL {
        let ext = remoteURL?.pathExtension.nonEmpty ?? "dat"
        return cacheDir.appendingPathComponent(songId).appendingPathExtension(ext)
    }

    private func metaURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("meta")
    }

    // MARK: Metadata read / write
    private struct FileMeta: Codable {
        var contentLength: UInt64?
        var contentType: String?
        var etag: String?
        var complete: Bool = false
        var lastValidated: Date?
        var source: String                     // original URL (debug / sanity)

        init(remoteURL: URL) {
            self.source = remoteURL.absoluteString
        }
    }

    private func readMeta(for fileURL: URL) throws -> FileMeta {
        let data = try Data(contentsOf: metaURL(for: fileURL))
        return try JSONDecoder().decode(FileMeta.self, from: data)
    }

    private func writeMeta(_ meta: FileMeta, for fileURL: URL) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL(for: fileURL), options: .atomic)
    }

    // Populate meta with HEAD information.
    private func metaWithHeadInfo(_ meta: FileMeta) async -> FileMeta {
        var updated = meta
        var headReq = URLRequest(url: URL(string: meta.source)!)
        headReq.httpMethod = "HEAD"
        do {
            let (_, resp) = try await session.data(for: headReq)
            if let http = resp as? HTTPURLResponse {
                if let len = http.value(forHTTPHeaderField: "Content-Length"),
                   let n = UInt64(len) { updated.contentLength = n }
                if let tag = http.value(forHTTPHeaderField: "ETag") { updated.etag = tag }
                if let contentType = http.value(forHTTPHeaderField: "Content-Type") { updated.contentType = contentType }
            }
        } catch { /* ignore */ }
        return updated
    }

    // MARK: Completeness & size utils
    private func isFileComplete(_ url: URL) -> Bool? {
        guard let meta = try? readMeta(for: url) else { return nil }
        let size = localFileSize(url)
        if meta.complete, let expected = meta.contentLength {
            return size == expected
        }
        return nil
    }

    private func localFileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(UInt64.init) ?? 0
    }

    // MARK: File prep / protection
    private func prepareFileIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.none]
            )
        }
    }

    private func touchFileAccessDate(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.creationDate: Date(), .modificationDate: Date()],
            ofItemAtPath: url.path
        )
        try? FileManager.default.setAttributes(
            [.creationDate: Date(), .modificationDate: Date()],
            ofItemAtPath: metaURL(for: url).path
        )
    }

    // MARK: Eviction
    private func pruneIfNeeded(force: Bool) async {
        let (total, files) = folderSizeAndFiles()
        os_log("Pruning cache %d, total=%d of %d, files=%d", log: self.appLog, type: .debug, force, total, sizeLimit, files.count)
        guard force || total > sizeLimit else { return }

        var bytesToFree = total > sizeLimit ? total - sizeLimit : 0
        for stat in files where bytesToFree > 0 {
            os_log("Deleting %@ from cache", log: self.appLog, type: .debug, stat.url.absoluteString)
            try? FileManager.default.removeItem(at: stat.url)
            try? FileManager.default.removeItem(at: metaURL(for: stat.url))
            bytesToFree = bytesToFree > stat.size ? bytesToFree - stat.size : 0
        }
    }

    private func folderSizeAndFiles()
    -> (UInt64, [FileStat]) {
        var total: UInt64 = 0
        var stats: [FileStat] = []
        guard let enumerator = FileManager.default.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: .skipsHiddenFiles
        ) else { return (0, []) }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "meta" { continue }           // ignore sidecars
            guard let rv = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey]),
                  rv.isRegularFile == true,
                  let bytes = rv.fileSize else { continue }

            total += UInt64(bytes)
            let accessed = rv.contentAccessDate ?? Date.distantPast
            stats.append(FileStat(url: fileURL,
                                  size: UInt64(bytes),
                                  accessDate: accessed))
        }
        return (total, stats.sorted { $0.accessDate < $1.accessDate })
    }
}

// MARK: - Private helpers / models
private struct DownloadRequest { let songId: String; let remote: URL; let streamLoader: StreamLoader }
private struct FileStat { let url: URL; let size: UInt64; let accessDate: Date }
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

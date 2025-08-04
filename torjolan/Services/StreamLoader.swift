import AVFoundation

final class StreamLoader: NSObject {
    private let queue = DispatchQueue(label: "net.line72.torjolan.streamloader")
    private var dataQueue = Data()
    private var pendingRequests = [AVAssetResourceLoadingRequest]()
    private let contentType: String
    private let contentSize: Int64

    init(contentType: String, contentSize: Int64) {
        self.contentType = contentType
        self.contentSize = contentSize
        super.init()
    }

    // MARK: - Critical Setup
    func setupAsset(_ url: URL) -> AVPlayer {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    func appendData(_ data: Data) {
        queue.async {
            self.dataQueue.append(data)
            self.processPendingRequests()
        }
    }

    func signalEndOfStream() {
        queue.async {
            self.processPendingRequests() // Drain final data
            // Cleanup any stragglers (e.g., after seek)
            self.pendingRequests.forEach { $0.finishLoading() }
            self.pendingRequests.removeAll()
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate
extension StreamLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async {
            // ✅ 1. HANDLE METADATA FIRST (NON-NEGOTIABLE)
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = self.contentType
                info.contentLength = self.contentSize
                info.isByteRangeAccessSupported = true
                
                // Set content information
                info.contentType = self.contentType
                info.contentLength = self.contentSize
                info.isByteRangeAccessSupported = true
                return
            }
            
            // ✅ 2. QUEUE DATA REQUESTS
            self.pendingRequests.append(loadingRequest)
            self.processPendingRequests()
        }
        return true
    }
    
    private func processPendingRequests() {
        guard !pendingRequests.isEmpty else { return }
        
        // Process OLDEST requests first (FIFO)
        var index = 0
        while index < pendingRequests.count {
            let request = pendingRequests[index]
            guard let dataRequest = request.dataRequest else { 
                index += 1; continue 
            }
            
            // CRITICAL: Never exceed requestedLength
            let requested = dataRequest.requestedLength
            let available = min(dataQueue.count, requested)
            let chunk = dataQueue.prefix(available)
            
            // ✅ SAFE: chunk.count <= requestedLength
            dataRequest.respond(with: chunk)
            dataQueue.removeFirst(available)
            
            // Cleanup completed requests
            if request.isFinished {
                pendingRequests.remove(at: index)
            } else {
                index += 1
            }
        }
    }
}

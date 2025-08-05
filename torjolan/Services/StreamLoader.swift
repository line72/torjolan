import AVFoundation

public final class StreamLoader: NSObject {
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
        //print("StreamLoader::appendData")
        queue.async {
            self.dataQueue.append(data)
            // require 50K of data before processing
            if (self.dataQueue.count > 5000) {
                self.processPendingRequests()
            }
        }
    }

    func signalEndOfStream() {
        print("StreamLoader::signalEndOfStream")
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
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        print("StreamLoader::resourceLoader")

        // ✅ 1. HANDLE METADATA FIRST (NON-NEGOTIABLE)
        if let info = loadingRequest.contentInformationRequest {
            print("StreamLoader -> returning meta \(self.contentType)|\(self.contentSize)")
            // Set content information
            info.contentType = self.contentType
            info.contentLength = self.contentSize
            //info.contentLength = -1
            info.isByteRangeAccessSupported = false
            
            loadingRequest.finishLoading()
            
            return true
        } else if let dataRequest = loadingRequest.dataRequest {
            // ✅ 2. QUEUE DATA REQUESTS
            print("StreamLoader -> queuing request")
            self.pendingRequests.append(loadingRequest)
            if (self.dataQueue.count > 5000) {
                self.processPendingRequests()
            }
            return true
        } else {
            print("UNHANDLED")
            return false
        }
    }
    
    private func processPendingRequests() {
        //print("StreamLoader::processingPendingRequests")
        guard !pendingRequests.isEmpty else { return }
        guard dataQueue.count != 0 else { return }
        
        print("StreamLoader -> process pendingRequest")
        let request = pendingRequests[0]
        guard let dataRequest = request.dataRequest else {
            return
        }

        while (true) {
            // CRITICAL: Never exceed requestedLength
            let requested = dataRequest.requestedLength
            let currentOffset = Int(dataRequest.currentOffset)
            let remaining = requested - currentOffset
            print("requested: \(requested), currentOffset \(currentOffset), remaining \(remaining)")
            
            let available = min(dataQueue.count, remaining)
            if (available <= 0) {
                print("No data to sent, stopping until next request")
                return
            }
            
            let totalSent = currentOffset + available
            //let available = dataQueue.count
            
            let chunk = dataQueue.prefix(available)
            print("chunk size is \(chunk.count)")
            
            //print("Requested \(requested) and responding with \(available)")
            
            
            // ✅ SAFE: chunk.count == requestedLength
            dataRequest.respond(with: chunk)
            
            dataQueue.removeFirst(available)
            
            // Cleanup completed requests
            if (totalSent >= requested) {
                print("pendingRequest is complete!!!")
                request.finishLoading()
                pendingRequests.remove(at: 0)
            }
        }
    }
}

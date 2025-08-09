import AVFoundation
import UniformTypeIdentifiers

public final class StreamLoader: NSObject {
    private let queue = DispatchQueue(label: "net.line72.torjolan.streamloader")
    private var dataQueue = Data()
    private var pendingRequests = [AVAssetResourceLoadingRequest]()
    private let contentType: String
    private let utiContentType: String
    private let contentSize: Int64

    init(contentType: String, contentSize: Int64) {
        self.contentType = contentType
        // Map MIME type to UTI identifier for AVFoundation
        if let ut = UTType(mimeType: contentType)?.identifier {
            self.utiContentType = ut
        } else {
            switch contentType {
            case "audio/mpeg":
                self.utiContentType = "public.mp3"
            case "audio/aac":
                self.utiContentType = "public.aac-audio"
            case "audio/mp4", "audio/x-m4a":
                // UTType for m4a is mpeg4Audio
                self.utiContentType = "public.mpeg-4-audio"
            case "audio/flac":
                // No standard UTType provided; use common identifier
                self.utiContentType = "org.xiph.flac"
            default:
                self.utiContentType = "public.audio"
            }
        }
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
        print("\(ObjectIdentifier(self)) StreamLoader::signalEndOfStream")
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
        print("\(ObjectIdentifier(self)) StreamLoader::resourceLoader")
        print("📋 Request URL: \(loadingRequest.request.url?.absoluteString ?? "nil")")
        print("📋 Request Headers: \(loadingRequest.request.allHTTPHeaderFields ?? [:])")

        // ✅ 1. Populate metadata if requested (do not finish yet if there is also a dataRequest)
        if let info = loadingRequest.contentInformationRequest {
            print("StreamLoader -> returning meta \(self.contentType)|\(self.contentSize)")
            // Set content information expected by AVFoundation (UTI, not MIME)
            info.contentType = self.utiContentType
            info.contentLength = self.contentSize
            info.isByteRangeAccessSupported = true
        }

        // ✅ 2. If there's a dataRequest, queue it and start fulfilling
        if loadingRequest.dataRequest != nil {
            print("StreamLoader -> queuing request")
            self.pendingRequests.append(loadingRequest)
            if self.dataQueue.count > 0 {
                self.processPendingRequests()
            }
            return true
        }

        // ✅ 3. If metadata-only request, we can finish now
        if loadingRequest.contentInformationRequest != nil {
            loadingRequest.finishLoading()
            return true
        }

        print("❌ UNHANDLED REQUEST TYPE")
        print("❌ ContentInformationRequest: \(loadingRequest.contentInformationRequest != nil)")
        print("❌ DataRequest: \(loadingRequest.dataRequest != nil)")
        return false
    }
    
    private func processPendingRequests() {
        guard !pendingRequests.isEmpty else { return }
        guard dataQueue.count != 0 else { return }

        //print("StreamLoader::processingPendingRequests")
        
        var index = 0
        while (index < pendingRequests.count) {
            //print("StreamLoader -> process pendingRequest")
            let request = pendingRequests[index]
            guard let dataRequest = request.dataRequest else {
                index+=1
                continue
            }

            //print("Working on pendingRequest \(ObjectIdentifier(request))")
            while true {
                // Never exceed requestedLength
                var requested = dataRequest.requestedLength
                let requestedOffset = Int(dataRequest.requestedOffset)
                let currentOffset = Int(dataRequest.currentOffset)

                // Handle requests that want data to the end of resource
                if dataRequest.requestsAllDataToEndOfResource, contentSize > 0 {
                    requested = max(requested, Int(contentSize) - requestedOffset)
                }

                let start = requestedOffset + currentOffset
                let maxBoundary = min(dataQueue.count, requestedOffset + requested)
                let available = maxBoundary - start

                if available <= 0 {
                    // Not enough data yet
                    index += 1
                    break
                }

                let end = start + available
                let chunk = dataQueue[start..<end]
                dataRequest.respond(with: chunk)

                // Check if request is satisfied
                let newCurrentOffset = Int(dataRequest.currentOffset)
                let totalSent = newCurrentOffset
                if totalSent >= requested {
                    print("\(ObjectIdentifier(self)) pendingRequest is complete!!!")
                    request.finishLoading()
                    pendingRequests.remove(at: index) // remove correct pending request
                    break
                }
            }
        }
    }
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        print("❌ \(ObjectIdentifier(self)) StreamLoader::resourceLoader - Request CANCELLED")
        print("❌ Cancelled URL: \(loadingRequest.request.url?.absoluteString ?? "nil")")
        
        // Remove from pending requests if it exists
        if let index = pendingRequests.firstIndex(where: { $0 === loadingRequest }) {
            pendingRequests.remove(at: index)
            print("❌ Removed cancelled request from pending queue")
        }
    }
}

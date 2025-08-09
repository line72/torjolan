import AVFoundation
import UniformTypeIdentifiers
import os.log

public final class StreamLoader: NSObject {
    private let queue = DispatchQueue(label: "net.line72.torjolan.streamloader")
    private var dataQueue = Data()
    private var pendingRequests = [AVAssetResourceLoadingRequest]()
    private let contentType: String
    private let utiContentType: String
    private let contentSize: Int64
    private let appLog = OSLog(subsystem: "net.line72.torjolan", category: "StreamLoader")

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
                //self.utiContentType = "org.xiph.flac"
                self.utiContentType = "public.flac-audio"
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
        os_log("appendData", log: self.appLog, type: .debug)
        queue.async {
            self.dataQueue.append(data)
            // require 50K of data before processing
            if (self.dataQueue.count > 0) {
                self.processPendingRequests()
            }
        }
    }

    func signalEndOfStream() {
        os_log("signalEndOfStream: %d|%d", log: self.appLog, type: .info, self.dataQueue.count, self.contentSize)
        queue.async {
            self.processPendingRequests() // Drain final data
            // Do not forcibly finish pending requests here. Allow any late
            // range requests to be fulfilled naturally using the available data.
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate
extension StreamLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        os_log("resourceLoader: URL=%@\nHeaders=%@", log: self.appLog, type: .info,
               loadingRequest.request.url?.absoluteString,
               loadingRequest.request.allHTTPHeaderFields
        )

        // ✅ 1. Populate metadata if requested (do not finish yet if there is also a dataRequest)
        if let info = loadingRequest.contentInformationRequest {
            os_log("Returning meta for a contentInformationRequest: contentType=%@, contentSize=%@",
                   log: self.appLog, type: .debug,
                   self.contentType, self.contentSize)

            // Set content information expected by AVFoundation (UTI, not MIME)
            info.contentType = self.utiContentType
            info.contentLength = self.contentSize
            info.isByteRangeAccessSupported = true
        }

        // ✅ 2. If there's a dataRequest, queue it and start fulfilling
        if loadingRequest.dataRequest != nil {
            os_log("queuing new request: %@", log: self.appLog, type: .debug,
                   ObjectIdentifier(loadingRequest))

            self.pendingRequests.append(loadingRequest)

            os_log("Number of pending requests=: %d", log: self.appLog, type: .debug, self.pendingRequests.count)
            if self.dataQueue.count > 0 {
                self.processPendingRequests()
            }
            return true
        }

        // ✅ 3. If metadata-only request, we can finish now
        if loadingRequest.contentInformationRequest != nil {
            os_log("contentInformationRequest is complete", log: self.appLog, type: .debug)
            
            loadingRequest.finishLoading()
            return true
        }

        os_log("❌ Unhandled Request Type, no contentInformationRequest or dataRequest!", log: self.appLog, type: .warning)
        return false
    }
    
    private func processPendingRequests() {
        guard !pendingRequests.isEmpty else { return }
        guard dataQueue.count != 0 else { return }

        os_log("processPendingRequests: count=%d", log: self.appLog, type: .debug, self.pendingRequests.count)
        
        var index = 0
        while (index < pendingRequests.count) {
            let request = pendingRequests[index]
            guard let dataRequest = request.dataRequest else {
                // !mwd - It shouldn't be possible to get here
                //  since we never should have added this to our pending request
                //  if dataRequest was nil
                // Just remove this from our list
                os_log("❌ pendingRequest is missing a dataRequest!", log: self.appLog, type: .warning)

                pendingRequests.remove(at: index)
                
                continue
            }

            os_log("processing pendingRequest(%d): %@", log: self.appLog, type: .debug, index, ObjectIdentifier(request))

            while true {
                // Never exceed requestedLength
                var requested = dataRequest.requestedLength
                // requestOffset is where this request starts relative
                // to the start of the file
                let requestedOffset = Int(dataRequest.requestedOffset)
                // currentOffset is where we currently are at relative
                // to the START OF THE FILE. This will start at the
                // same value as requestedOffset! It is NOT an offset
                // from the requestedOffset!
                let currentOffset = Int(dataRequest.currentOffset)

                // Handle requests that want data to the end of resource
                if dataRequest.requestsAllDataToEndOfResource, contentSize > 0 {
                    let newRequested = max(requested, Int(contentSize) - requestedOffset)
                    if (newRequested != requested) {
                        requested = newRequested
                    }
                }

                let start = currentOffset
                let maxBoundary = min(dataQueue.count, requestedOffset + requested)
                let available = maxBoundary - start

                os_log("pendingRequest(%d): %@: requested=%d, requestedOffset=%d, currentOffset=%d, start=%d, maxBoundary=%d, available=%d",
                       log: self.appLog, type: .debug,
                       index, ObjectIdentifier(request),
                       requested, requestedOffset, currentOffset,
                       start, maxBoundary, available)

                if available <= 0 {
                    // Not enough data yet
                    os_log("pendingRequest(%d): %@: Not enough data for request", log: self.appLog, type: .debug,
                           index, ObjectIdentifier(request))

                    // remove on to the next request as it might have
                    // a different range that we do have data for
                    index += 1
                    break
                }

                let end = start + available
                let chunk = dataQueue[start..<end]

                // Respond with as much data as we have in the range
                dataRequest.respond(with: chunk)

                // Check if request is satisfied
                let newCurrentOffset = Int(dataRequest.currentOffset)
                let totalSent = newCurrentOffset
                if totalSent >= requested {
                    os_log("pendingRequest(%d): %@: is complete!", log: self.appLog, type: .info, index, ObjectIdentifier(request))

                    // Let the request know it is all done
                    request.finishLoading()

                    // Remove this from anything we'll process
                    pendingRequests.remove(at: index) // remove correct pending request
                    
                    break
                }
            }
        }

        os_log("processPendingRequests complete. Number of pendingRequests=%d", log: self.appLog, type: .debug, self.pendingRequests.count)
    }
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        os_log("resourceLoader didCancel: %@, url=%@", log: self.appLog, type: .info,
               loadingRequest, loadingRequest.request.url?.absoluteString)
        
        // Remove from pending requests if it exists
        if let index = pendingRequests.firstIndex(where: { $0 === loadingRequest }) {
            let req = pendingRequests[index]
            os_log("Removing cancelled request from queue: %@", log: self.appLog, type: .info, ObjectIdentifier(req))

            pendingRequests.remove(at: index)

            os_log("Number of pending requests after cancel=%d", log: self.appLog, type: .debug, self.pendingRequests.count)
        }
    }
}

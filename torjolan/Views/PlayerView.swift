import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import os.log

class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()
    private var player: AVPlayer?
    private var currentStreamLoader: StreamLoader?
    private var playerTimeObserver: Any?
    private var playerItemStatusObserver: AnyCancellable?
    private var playerItemDidPlayToEndObserver: AnyCancellable?

    private var submitted = false
    private var nextUpSong: Song?
    private var nextUpStreamLoader: StreamLoader?

    private let appLog = OSLog(subsystem: "net.line72.torjolan", category: "PlayerView")
    
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var currentSong: Song?
    private var currentStation: Station?
    @Published var duration: TimeInterval = 0
    @Published var isThumbedUp = false

    override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }

    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Enable play/pause commands
        commandCenter.playCommand.addTarget { [weak self] event in
            self?.player?.play()
            self?.isPlaying = true
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.player?.pause()
            self?.isPlaying = false
            return .success
        }

        // Disable next/previous track commands
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func setupTimeObserver() {
        // Remove existing observer if any
        if let observer = playerTimeObserver {
            player?.removeTimeObserver(observer)
            playerTimeObserver = nil
        }

        // Create new observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds

            if ((self.currentTime as Double) / (self.duration as Double) >= 0.85) {
                // We have reach 85%. Time to submit this as played and retrieve
                // the next songs
                if (!self.submitted) {
                    // We can't run an async task in this callback,
                    //  therefore we are going to spin up a new
                    //  thread. However, submitAndGetNextSong must be
                    //  run on the main thread, which is why we tell
                    //  this to run on @MainActor
                    Task { @MainActor in
                        do {
                            await self.submitAndGetNextSong(song: self.currentSong)
                        }
                    }
                }
            }
            
            // Update lock screen progress
            if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = self.duration
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        }
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)

        // Update lock screen progress
        if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    private func updateNowPlayingInfo(for song: Song) {
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration
        ]

        // Load album artwork asynchronously if available
        if let coverUrlString = song.cover_url, let coverUrl = URL(string: coverUrlString) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: coverUrl)
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                            return image
                        }
                        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        // Update the now playing info on the main thread
                        await MainActor.run {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                        }
                    }
                } catch {
                    print("Failed to load artwork: \(error)")
                }
            }
        }

        // Set the info immediately, artwork will be updated asynchronously
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func startPlayingStation(_ station: Station) {
        // Stop any existing playback
        stop()

        currentStation = station
        Task {
            await fetchAndPlayNextSong()
        }
    }

    func startPlayingNewStation(_ stationResponse: CreateStationResponse) async {
        currentStation = Station(id: stationResponse.station.id, name: stationResponse.station.name)
        let song = Song(from: stationResponse.track)

        do {
            let streamLoader = await DownloadCacheManager.shared.queueFirst(
              songId: song.id,
              url: URL(string: stationResponse.track.url)!
            )
            
            await MainActor.run {
                play(streamLoader: streamLoader, song: song)
            }
        }
    }

    /**
     * If we have a nextSong in the queue, play it, otherwise
     *  fetch from the server
     */
    private func playNextSong() async {
        if let song = self.nextUpSong, let loader = self.nextUpStreamLoader {
            os_log("playNextSong: Playing queued NextUp", log: self.appLog, type: .debug)
            // we have items in the queue, play it
            await MainActor.run {
                self.nextUpSong = nil
                self.nextUpStreamLoader = nil
                
                play(streamLoader: loader, song: song)
            }
        } else {
            await fetchAndPlayNextSong()
        }
    }
    
    private func fetchAndPlayNextSong() async {
        guard let station = currentStation else { return }

        do {
            let streamResponseList = try await APIService.shared.getStationStream(stationId: station.id)

            do {
                // Queue up and start playing the first song in the response
                let firstStream = streamResponseList.tracks[0]
                let song = Song(from: firstStream)
                let streamLoader = await DownloadCacheManager.shared.queueFirst(
                    songId: song.id,
                    url: URL(string: firstStream.url)!
                )

                await MainActor.run {
                    play(streamLoader: streamLoader, song: song)
                }

                // Put the remaining songs in the download queue
                //
                // !mwd - This would be better if it was a priority
                // queue. We have a good chance of backing up our
                // queue with songs we won't play
                for stream in streamResponseList.tracks.dropFirst() {
                    let song2 = Song(from: stream)
                    let _ = await DownloadCacheManager.shared.queue(
                      songId: song2.id,
                      url: URL(string: stream.url)!
                    )
                }
            }
        } catch {
            print("Failed to fetch next song: \(error)")
        }
    }

    private func submitAndGetNextSong(song: Song?) async {
        os_log("submitAndGetNextSong", log: self.appLog, type: .debug)
        
        guard song != nil else { return }
        guard !self.submitted else { return }
        guard let station = currentStation else { return }

        self.submitted = true
        
        do {
            // If this was thumbed up, it has already been
            //  submitted
            if (!self.isThumbedUp) {
                os_log("Calling APIServer.submitSong", log: self.appLog, type: .debug)
                // Submit this as played
                let _ = try await APIService.shared.submitSong(stationId: station.id,
                                                               songId: song?.id ?? "")
            } else {
                os_log("Song was thumbed up, skipping submit", log: self.appLog, type: .debug)
            }

            // Get the next Songs
            let streamResponseList = try await APIService.shared.getStationStream(stationId: station.id)

            do {
                // Queue up and start playing the first song in the response
                let firstStream = streamResponseList.tracks[0]
                let song = Song(from: firstStream)
                let streamLoader = await DownloadCacheManager.shared.queueFirst(
                    songId: song.id,
                    url: URL(string: firstStream.url)!
                )

                os_log("Got our next song: %@", log: self.appLog, type: .debug, song.id)
                
                self.nextUpSong = song
                self.nextUpStreamLoader = streamLoader

                // Put the remaining songs in the download queue
                //
                // !mwd - This would be better if it was a priority
                // queue. We have a good chance of backing up our
                // queue with songs we won't play
                for stream in streamResponseList.tracks.dropFirst() {
                    let song2 = Song(from: stream)
                    let _ = await DownloadCacheManager.shared.queue(
                      songId: song2.id,
                      url: URL(string: stream.url)!
                    )
                }
            }
        } catch {
            print("Failed to fetch next song: \(error)")
        }
    }
    
    func play(streamLoader: StreamLoader, song: Song) {
        print("Attempting to play URL: \(song.id)")

        stop()

        // clear out any next song stuff
        self.submitted = false
        self.nextUpSong = nil
        self.nextUpStreamLoader = nil
        
        // Retain the stream loader strongly so it isn't deallocated
        currentStreamLoader = streamLoader

        currentSong = song
        isThumbedUp = false  // Reset thumbs up state for new song

        guard let url = URL(string: "torjolan://\(song.id)") else {
            // Handle invalid URL (log error, show alert, etc.)
            print("INVALID URL!!!")
            return
        }
        print("Setting up player for url \(url)")
        player = streamLoader.setupAsset(url)
        let playerItem = player?.currentItem!

        // Observe player item status
        playerItemStatusObserver = playerItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    print("✓ Ready to play")
                    self?.duration = playerItem?.duration.seconds ?? 0.0
                    self?.player?.play()
                    self?.isPlaying = true
                case .failed:
                    self?.logDetailedPlayerError(playerItem: playerItem, song: song)
                    Task {
                        await self?.playNextSong()
                    }
                default:
                    print("Status changed to unknown \(status)")
                    break
                }
            }

        // Observe player item end
        playerItemDidPlayToEndObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("✓ Media playback ended")
                Task {
                    await self?.playNextSong()
                }
            }

        setupTimeObserver()
        updateNowPlayingInfo(for: song)
    }

    func togglePlayPause() {
        if isPlaying {
            print("⏸️ Pausing playback")
            player?.pause()
        } else {
            print("▶️ Resuming playback")
            player?.play()
        }
        isPlaying.toggle()

        // Update playback rate in now playing info
        if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    func stop() {
        print("⏹️ Stopping playback")
        player?.pause()
        player = nil
        playerTimeObserver = nil
        playerItemStatusObserver = nil
        playerItemDidPlayToEndObserver = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSong = nil
        isThumbedUp = false
        currentStreamLoader = nil

        // Clear now playing info when stopping
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func logDetailedPlayerError(playerItem: AVPlayerItem?, song: Song) {
        print("❌ ========== PLAYER ITEM FAILED ==========")
        print("❌ Song ID: \(song.id)")
        print("❌ Song Title: \(song.title)")
        print("❌ Song Artist: \(song.artist)")
        
        if let error = playerItem?.error {
            print("❌ Primary Error: \(error.localizedDescription)")
            
            if let nsError = error as NSError? {
                print("❌ Error Code: \(nsError.code)")
                print("❌ Error Domain: \(nsError.domain)")
            }
            
            // Check for underlying errors
            if let nsError = error as NSError? {
                print("❌ NSError Code: \(nsError.code)")
                print("❌ NSError Domain: \(nsError.domain)")
                print("❌ NSError UserInfo: \(nsError.userInfo)")
                
                // Check for underlying error in userInfo
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("❌ Underlying Error: \(underlyingError.localizedDescription)")
                    print("❌ Underlying Error Code: \(underlyingError.code)")
                    print("❌ Underlying Error Domain: \(underlyingError.domain)")
                    print("❌ Underlying Error UserInfo: \(underlyingError.userInfo)")
                }
                
                // Check for OSStatus errors (common in AVFoundation)
                if nsError.domain == NSOSStatusErrorDomain {
                    let osStatus = OSStatus(nsError.code)
                    print("❌ OSStatus: \(osStatus) (\(fourCharCodeFromOSStatus(osStatus)))")
                }
            }
        } else {
            print("❌ No error object available")
        }
        
        // Check asset information
        if let asset = playerItem?.asset {
            // Check if it's an AVURLAsset first to get URL
            if let urlAsset = asset as? AVURLAsset {
                print("❌ AVURLAsset URL: \(urlAsset.url)")
                print("❌ AVURLAsset ResourceLoader: \(urlAsset.resourceLoader)")
                
                // Check if resource loader has a delegate
                if urlAsset.resourceLoader.delegate != nil {
                    print("❌ ResourceLoader has delegate: YES")
                } else {
                    print("❌ ResourceLoader has delegate: NO")
                }
            } else {
                print("❌ Asset is not AVURLAsset: \(type(of: asset))")
            }
            
            // Use async loading for modern iOS versions to avoid deprecation warnings
            Task {
                do {
                    let duration = try await asset.load(.duration)
                    let isPlayable = try await asset.load(.isPlayable)
                    let isReadable = try await asset.load(.isReadable)
                    let isExportable = try await asset.load(.isExportable)
                    let isComposable = try await asset.load(.isComposable)
                    
                    print("❌ Asset Duration: \(duration)")
                    print("❌ Asset Playable: \(isPlayable)")
                    print("❌ Asset Readable: \(isReadable)")
                    print("❌ Asset Exportable: \(isExportable)")
                    print("❌ Asset Composable: \(isComposable)")
                } catch {
                    print("❌ Failed to load asset properties: \(error)")
                }
            }
        }
        
        // Check player item tracks
        if let tracks = playerItem?.tracks {
            print("❌ Player Item Tracks Count: \(tracks.count)")
            for (index, track) in tracks.enumerated() {
                print("❌ Track \(index): enabled=\(track.isEnabled), asset track=\(track.assetTrack?.mediaType.rawValue ?? "nil")")
            }
        }
        
        // Check audio session
        let audioSession = AVAudioSession.sharedInstance()
        print("❌ Audio Session Category: \(audioSession.category.rawValue)")
        print("❌ Audio Session Active: \(audioSession.isOtherAudioPlaying)")
        print("❌ Audio Session Route: \(audioSession.currentRoute)")
        
        print("❌ ========================================")
    }
    
    private func fourCharCodeFromOSStatus(_ status: OSStatus) -> String {
        let bytes = [
            UInt8((status >> 24) & 0xFF),
            UInt8((status >> 16) & 0xFF),
            UInt8((status >> 8) & 0xFF),
            UInt8(status & 0xFF)
        ]
        
        // Check if all bytes are printable ASCII characters
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "\(status)"
        } else {
            return "\(status)"
        }
    }

    deinit {
        stop()
    }
}

struct PlayerView: View {
    let station: Station
    @StateObject private var audioPlayer = AudioPlayer.shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var isSeeking = false
    @State private var seekTime: TimeInterval = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    // Cover Art
                    Group {
                        if let coverUrl = audioPlayer.currentSong?.cover_url {
                            AsyncImage(url: URL(string: coverUrl)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } placeholder: {
                                ProgressView()
                            }
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(
                        width: min(geometry.size.width - 40, 400),
                        height: min(geometry.size.width - 40, 400)
                    )
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 10)
                    .padding()

                    // Song Info - Fixed height section
                    VStack(spacing: 8) {
                        Text(audioPlayer.currentSong?.title ?? "Loading...")
                            .font(.title2)
                            .bold()
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .center
)
                        Text(audioPlayer.currentSong?.artist ?? " ")  // Use space to maintain height
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if let album = audioPlayer.currentSong?.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text(" ")  // Placeholder to maintain consistent height
                                .font(.subheadline)
                                .foregroundColor(.clear)
                        }
                    }
                    .padding(.horizontal)
                    .frame(height: 100)  // Fixed height for song info section

                    // Time Slider
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekTime : audioPlayer.currentTime },
                                set: { newValue in
                                    isSeeking = true
                                    seekTime = newValue
                                }
                            ),
                            in: 0...max(audioPlayer.duration, 1)
                        ) { editing in
                            if !editing && isSeeking {
                                audioPlayer.seek(to: seekTime)
                                isSeeking = false
                            }
                        }
                        .disabled(audioPlayer.duration == 0)

                        HStack {
                            Text(formatTime(audioPlayer.currentTime))
                                .font(.caption)
                                .monospacedDigit()
                            Spacer()
                            Text(formatTime(audioPlayer.duration))
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal)

                    Spacer()

                    // Controls - Fixed at bottom
                    HStack(spacing: 40) {
                        Button(action: {
                            Task {
                                try? await thumbsDown()
                            }
                        }) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.title)
                                .foregroundColor(.red)
                        }

                        Button(action: {
                            audioPlayer.togglePlayPause()
                        }) {
                            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }

                        Button(action: {
                            Task {
                                try? await thumbsUp()
                            }
                        }) {
                            Image(systemName: audioPlayer.isThumbedUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.title)
                                .foregroundColor(.green)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemBackground).opacity(0.9))
                }
            }
        }
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)  // Ensures long station names don't take up too much space
        .onAppear {
            // Allow screen to turn off during playback
            UIApplication.shared.isIdleTimerDisabled = false
            audioPlayer.stop()
            audioPlayer.startPlayingStation(station)
        }
        .onDisappear {
            audioPlayer.stop()
            // Reset to system default
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }

    private func thumbsUp() async throws {
        guard let song = audioPlayer.currentSong else { return }
        let success = try await APIService.shared.thumbsUp(stationId: station.id, songId: song.id)
        if success {
            audioPlayer.isThumbedUp = true
        }
    }

    private func thumbsDown() async throws {
        guard let song = audioPlayer.currentSong else { return }
        let success = try await APIService.shared.thumbsDown(stationId: station.id, songId: song.id)
        if success {
            // Stop current playback
            audioPlayer.stop()
            // Start playing next song
            audioPlayer.startPlayingStation(station)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    NavigationView {
        PlayerView(station: Station(
            id: 1,
            name: "Test Station",
            currentSong: nil
        ))
    }
}

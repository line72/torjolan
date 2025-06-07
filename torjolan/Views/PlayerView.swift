import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()
    private var player: AVPlayer?
    private var playerTimeObserver: Any?
    private var playerItemStatusObserver: AnyCancellable?
    private var playerItemDidPlayToEndObserver: AnyCancellable?
    
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
    
    func startPlayingNewStation(_ stationResponse: CreateStationResponse) {
        currentStation = Station(id: stationResponse.station.id, name: stationResponse.station.name)
        let song = Song(from: stationResponse.track)
        
        play(url: stationResponse.track.url, song: song)
    }
    
    private func fetchAndPlayNextSong() async {
        guard let station = currentStation else { return }
        
        do {
            let streamResponse = try await APIService.shared.getStationStream(stationId: station.id)
            let song = Song(from: streamResponse)
            
            await MainActor.run {
                play(url: streamResponse.url, song: song)
            }
        } catch {
            print("Failed to fetch next song: \(error)")
        }
    }
    
    func play(url: String, song: Song) {
        print("Attempting to play URL: \(url)")
        
        guard let audioURL = URL(string: url) else {
            print("❌ Failed to create URL from string: \(url)")
            return
        }
        
        stop()
        
        currentSong = song
        isThumbedUp = false  // Reset thumbs up state for new song
        
        let playerItem = AVPlayerItem(url: audioURL)
        player = AVPlayer(playerItem: playerItem)
        
        // Observe player item status
        playerItemStatusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    print("✓ Ready to play")
                    self?.duration = playerItem.duration.seconds
                    self?.player?.play()
                    self?.isPlaying = true
                case .failed:
                    print("❌ Player item failed: \(playerItem.error?.localizedDescription ?? "unknown error")")
                    Task {
                        await self?.fetchAndPlayNextSong()
                    }
                default:
                    break
                }
            }
        
        // Observe player item end
        playerItemDidPlayToEndObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("✓ Media playback ended")
                Task {
                    await self?.fetchAndPlayNextSong()
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
        
        // Clear now playing info when stopping
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
                            .frame(maxWidth: .infinity, alignment: .center)
                        
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

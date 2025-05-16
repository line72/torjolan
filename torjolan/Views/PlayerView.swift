import SwiftUI
import AVFoundation
import UIKit

class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()
    private var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    private var timeObserver: Any?
    
    func play(url: String) {
        print("Attempting to play URL: \(url)")
        
        guard let audioURL = URL(string: url) else {
            print("❌ Failed to create URL from string: \(url)")
            return
        }
        
        stop()
        let playerItem = AVPlayerItem(url: audioURL)
        
        // Add error handling for the player item
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(playerItemDidFailToPlay),
                                             name: .AVPlayerItemFailedToPlayToEndTime,
                                             object: playerItem)
        
        // Add status observation
        playerItem.addObserver(self,
                             forKeyPath: #keyPath(AVPlayerItem.status),
                             options: [.old, .new],
                             context: nil)
        
        player = AVPlayer(playerItem: playerItem)
        print("✓ Created AVPlayer with item")
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
            print("Current playback time: \(time.seconds)")
        }
        
        player?.play()
        isPlaying = true
        print("▶️ Started playback")
    }
    
    override func observeValue(forKeyPath keyPath: String?,
                             of object: Any?,
                             change: [NSKeyValueChangeKey : Any]?,
                             context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(AVPlayerItem.status) {
            let status: AVPlayerItem.Status
            
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
            } else {
                status = .unknown
            }
            
            // Handle the status change
            switch status {
            case .readyToPlay:
                print("✓ Player item is ready to play")
            case .failed:
                if let error = (object as? AVPlayerItem)?.error {
                    print("❌ Player item failed with error: \(error)")
                }
            case .unknown:
                print("⚠️ Player item status is unknown")
            @unknown default:
                print("⚠️ Player item has unhandled status")
            }
        }
    }
    
    @objc private func playerItemDidFailToPlay(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("❌ Playback failed with error: \(error)")
        }
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
    }
    
    func stop() {
        print("⏹️ Stopping playback")
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
        isPlaying = false
        currentTime = 0
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct PlayerView: View {
    let station: Station
    @StateObject private var audioPlayer = AudioPlayer.shared
    @State private var currentSong: Song?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    // Cover Art
                    Group {
                        if let coverUrl = currentSong?.cover_url {
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
                    
                    // Song Info
                    VStack(spacing: 8) {
                        Text(currentSong?.title ?? "Loading...")
                            .font(.title2)
                            .bold()
                        Text(currentSong?.artist ?? "")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        if let album = currentSong?.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Controls
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
                            Image(systemName: "hand.thumbsup")
                                .font(.title)
                                .foregroundColor(.green)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(station.name)
        .onAppear {
            fetchCurrentSong()
        }
        .onReceive(timer) { _ in
            fetchCurrentSong()
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
    
    private func fetchCurrentSong() {
        guard !isLoading else { return }
        isLoading = true
        
        Task {
            do {
                let streamResponse = try await APIService.shared.getStationStream(stationId: station.id)
                await MainActor.run {
                    let song = Song(from: streamResponse)
                    currentSong = song
                    if !audioPlayer.isPlaying {
                        audioPlayer.play(url: streamResponse.url)
                    }
                    isLoading = false
                }
            } catch {
                print("Detailed error: \(error)")
                await MainActor.run {
                    errorMessage = "\(error)"
                    isLoading = false
                }
            }
        }
    }
    
    private func thumbsUp() async throws {
        guard let song = currentSong else { return }
        let success = try await APIService.shared.thumbsUp(stationId: station.id, songId: song.id)
        if success {
            // Optionally update the UI to show the rating was successful
        }
    }
    
    private func thumbsDown() async throws {
        guard let song = currentSong else { return }
        let success = try await APIService.shared.thumbsDown(stationId: station.id, songId: song.id)
        if success {
            // Optionally update the UI to show the rating was successful
        }
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
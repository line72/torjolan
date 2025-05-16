import SwiftUI
import MobileVLCKit
import UIKit
import AVFoundation

class AudioPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    static let shared = AudioPlayer()
    private var player: VLCMediaPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    
    override init() {
        super.init()
        setupAudioSession()
        setupPlayer()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    private func setupPlayer() {
        player = VLCMediaPlayer()
        player?.delegate = self
        player?.audio?.volume = 100
    }
    
    func play(url: String) {
        print("Attempting to play URL: \(url)")
        
        guard let audioURL = URL(string: url) else {
            print("❌ Failed to create URL from string: \(url)")
            return
        }
        
        stop()
        
        let media = VLCMedia(url: audioURL)
        player?.media = media
        print("✓ Created VLCMedia with URL")
        
        player?.play()
        isPlaying = true
        print("▶️ Started playback")
    }
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = player else { return }
        
        switch player.state {
        case .playing:
            print("✓ Media is playing")
            isPlaying = true
        case .error:
            print("❌ Player encountered an error")
            isPlaying = false
        case .ended:
            print("✓ Media playback ended")
            isPlaying = false
        default:
            break
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
        player?.stop()
        isPlaying = false
        currentTime = 0
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
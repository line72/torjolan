import SwiftUI
import AVFoundation
import UIKit

class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()
    private var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    private var timeObserver: Any?
    
    func play(url: URL) {
        stop()
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
        }
        
        player?.play()
        isPlaying = true
    }
    
    func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    func stop() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
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
                        if let url = currentSong?.artworkURL {
                            AsyncImage(url: url) { image in
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
                    
                    // Progress Bar
                    if let duration = currentSong?.duration {
                        ProgressView(value: audioPlayer.currentTime, total: duration)
                            .padding(.horizontal)
                    }
                    
                    // Controls
                    HStack(spacing: 40) {
                        Button(action: {
                            Task {
                                try? await rateSong(isLike: false)
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
                                try? await rateSong(isLike: true)
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
                let song = try await APIService.shared.fetchCurrentSong(stationId: station.id)
                await MainActor.run {
                    currentSong = song
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to fetch current song"
                    isLoading = false
                }
            }
        }
    }
    
    private func rateSong(isLike: Bool) async throws {
        guard let song = currentSong else { return }
        try await APIService.shared.rateSong(songId: song.id, isLike: isLike)
        // Optionally update the UI to show the rating was successful
    }
}

#Preview {
    NavigationView {
        PlayerView(station: Station(
            id: "1",
            name: "Test Station",
            description: "A test station",
            artworkURL: nil
        ))
    }
} 
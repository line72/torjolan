import SwiftUI

struct StationListView: View {
    @State private var stations: [Station] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateStation = false
    @State private var newStationResponse: CreateStationResponse?
    @State private var activeStation: Station?
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Binding var isLoggedIn: Bool
    
    private var gridColumns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible())]
        } else {
            return [
                GridItem(.adaptive(minimum: 250, maximum: 300)),
                GridItem(.adaptive(minimum: 250, maximum: 300))
            ]
        }
    }
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let error = errorMessage {
                VStack {
                    Text(error)
                        .foregroundColor(.red)
                    Button("Try Again") {
                        fetchStations()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(stations) { station in
                            NavigationLink(destination: PlayerView(station: station)) {
                                StationCard(station: station)
                                    .frame(height: 150)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Radio Stations")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(action: { showingCreateStation = true }) {
                        Label("Create Station", systemImage: "plus.circle")
                    }
                    Button(action: logout) {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateStation) {
            NavigationView {
                StationCreationView { response in
                    newStationResponse = response
                    // Add the new station to the list
                    let newStation = Station(id: response.station.id, name: response.station.name)
                    stations.append(newStation)
                }
            }
        }
        .onChange(of: newStationResponse) { oldValue, newValue in
            if let response = newValue {
                // Start playback
                AudioPlayer.shared.startPlayingNewStation(response)
                // Set the active station for navigation
                activeStation = Station(id: response.station.id, name: response.station.name)
            }
        }
        .background(
            NavigationLink(
                destination: Group {
                    if let station = activeStation {
                        PlayerView(station: station)
                    }
                },
                isActive: Binding(
                    get: { activeStation != nil },
                    set: { if !$0 { activeStation = nil } }
                )
            ) {
                EmptyView()
            }
        )
        .onAppear {
            if stations.isEmpty {
                fetchStations()
            }
        }
    }
    
    private func fetchStations() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let stationResponses = try await APIService.shared.fetchStations()
                stations = stationResponses.map { Station(id: $0.id, name: $0.name, currentSong: nil) }
            } catch {
                errorMessage = "Failed to load stations. Please try again."
            }
            isLoading = false
        }
    }
    
    private func logout() {
        // Clear user data
        try? KeychainManager.shared.deleteToken()
        User.current = nil
        
        // Update login state
        withAnimation {
            isLoggedIn = false
        }
    }
}

struct StationCard: View {
    let station: Station
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.gray
            Image(systemName: "radio")
                .font(.system(size: 40))
                .foregroundColor(.white)
            
            VStack(alignment: .leading) {
                Text(station.name)
                    .font(.headline)
                    .foregroundColor(.white)
                
                if let song = station.currentSong {
                    Text("\(song.title) - \(song.artist)")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 5)
    }
}

#Preview {
    NavigationView {
        StationListView(isLoggedIn: .constant(true))
    }
} 
import SwiftUI

struct StationCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stationName = ""
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [SearchResult] = []
    @State private var selectedSong: SearchResult?
    @State private var errorMessage: String?
    @State private var isCreating = false
    
    var body: some View {
        Form {
            Section(header: Text("Station Details")) {
                TextField("Station Name", text: $stationName)
            }
            
            Section(header: Text("Search for a Seed Song")) {
                TextField("Search (e.g., Blind Guardian And The Story Ends)", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: searchText) { oldValue, newValue in
                        performSearch()
                    }
                
                if isSearching {
                    ProgressView()
                        .padding()
                } else if !searchResults.isEmpty {
                    List(searchResults, id: \.id) { result in
                        Button(action: { selectedSong = result }) {
                            HStack {
                                Text("\(result.artist) - \(result.title) (\(result.album))")
                                    .foregroundColor(.primary)
                                if selectedSong?.id == result.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Create Station")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Create") {
                    createStation()
                }
                .disabled(stationName.isEmpty || selectedSong == nil || isCreating)
            }
        }
    }
    
    private func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        
        Task {
            isSearching = true
            do {
                searchResults = try await APIService.shared.searchSongs(title: searchText)
            } catch {
                errorMessage = "Failed to search songs: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }
    
    private func createStation() {
        guard let song = selectedSong else { return }
        
        Task {
            isCreating = true
            do {
                let response = try await APIService.shared.createStation(name: stationName, songId: song.id)
                // Navigate to PlayerView with the new station and track
                dismiss()
            } catch {
                errorMessage = "Failed to create station: \(error.localizedDescription)"
            }
            isCreating = false
        }
    }
}

#Preview {
    NavigationView {
        StationCreationView()
    }
} 
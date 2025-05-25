import SwiftUI
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var rootTemplate: CPTabBarTemplate?
    private var stationsTemplate: CPListTemplate?
    private var nowPlayingTemplate: CPNowPlayingTemplate?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        
        // Setup templates
        setupTemplates()
        
        // Set the root template
        interfaceController.setRootTemplate(rootTemplate!, animated: false, completion: nil)
    }
    
    // Required by CPTemplateApplicationSceneDelegate
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didSelect navigationAlert: CPNavigationAlert) {
        // Handle navigation alerts if needed
    }
    
    private func setupTemplates() {
        // Create the stations list template
        setupStationsTemplate()
        
        // Create the now playing template
        nowPlayingTemplate = CPNowPlayingTemplate.shared
        
        // Create the tab bar template with non-nil templates
        if let stationsTemplate = stationsTemplate,
           let nowPlayingTemplate = nowPlayingTemplate {
            rootTemplate = CPTabBarTemplate(templates: [stationsTemplate, nowPlayingTemplate])
        }
    }
    
    private func setupStationsTemplate() {
        // Create a list template for stations
        let sections = [CPListSection(items: [])]
        stationsTemplate = CPListTemplate(title: "Stations", sections: sections)
        
        // Load stations
        Task {
            do {
                let stationResponses = try await APIService.shared.fetchStations()
                let stations = stationResponses.map { Station(id: $0.id, name: $0.name, currentSong: nil) }
                
                // Create list items for each station
                let items = stations.map { station in
                    let item = CPListItem(text: station.name, detailText: "")
                    item.handler = { [weak self] _, completion in
                        // Start playing the station
                        AudioPlayer.shared.startPlayingStation(station)
                        completion()
                    }
                    return item
                }
                
                // Update the template with the new items
                await MainActor.run {
                    if let sections = self.stationsTemplate?.sections {
                        let updatedSection = CPListSection(items: items)
                        self.stationsTemplate?.updateSections([updatedSection])
                    }
                }
            } catch {
                print("Failed to load stations for CarPlay: \(error)")
            }
        }
    }
}

// MARK: - Additional CPTemplateApplicationSceneDelegate Methods
extension CarPlaySceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
} 
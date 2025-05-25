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
        
        // Check if we have valid credentials
        if let savedHost = HostSettings.shared.host,
           let token = try? KeychainManager.shared.loadToken() {
            // Configure API with saved credentials
            APIService.configure(baseURL: savedHost)
            APIService.setAuthToken(authToken: token)
            
            // Setup templates
            setupTemplates()
            
            // Set the root template
            interfaceController.setRootTemplate(rootTemplate!, animated: false, completion: nil)
        } else {
            // Show a message that user needs to log in first
            let okAction = CPAlertAction(title: "OK", style: .default) { _ in }
            let alert = CPAlertTemplate(titleVariants: ["Please Log In"],
                                      actions: [okAction])
            interfaceController.presentTemplate(alert, animated: true)
        }
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
        // Create a list template for stations with a loading indicator
        let loadingItem = CPListItem(text: "Loading Stations...", detailText: "")
        let sections = [CPListSection(items: [loadingItem])]
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
                        Task {
                            AudioPlayer.shared.startPlayingStation(station)
                            
                            // Switch to Now Playing tab
                            if let self = self,
                               let nowPlayingTemplate = self.nowPlayingTemplate {
                                do {
                                    try await self.interfaceController?.pushTemplate(nowPlayingTemplate, animated: true)
                                } catch {
                                    print("Failed to push now playing template: \(error)")
                                }
                            }
                            completion()
                        }
                    }
                    return item
                }
                
                // Update the template with the new items
                await MainActor.run {
                    let updatedSection = CPListSection(items: items)
                    self.stationsTemplate?.updateSections([updatedSection])
                }
            } catch {
                print("Failed to load stations for CarPlay: \(error)")
                
                // Show error in the list
                await MainActor.run {
                    let errorItem = CPListItem(text: "Error Loading Stations", detailText: "Please check your connection")
                    let errorSection = CPListSection(items: [errorItem])
                    self.stationsTemplate?.updateSections([errorSection])
                }
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
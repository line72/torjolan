import Foundation

class HostSettings {
    static let shared = HostSettings()
    
    private let defaults = UserDefaults.standard
    private let hostKey = "server_host"
    
    var host: String? {
        get { defaults.string(forKey: hostKey) }
        set {
            defaults.set(newValue, forKey: hostKey)
        }
    }
    
    var isHostConfigured: Bool {
        host != nil
    }
    
    private init() {}
} 
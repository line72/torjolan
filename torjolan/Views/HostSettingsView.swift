import SwiftUI

struct HostSettingsView: View {
    @Binding var isPresented: Bool
    @State private var host: String = HostSettings.shared.host ?? ""
    @State private var showError = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    TextField("Server URL (e.g., https://server.example.com)", text: $host)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                
                Section(footer: Text("This should be the URL of your Boldaric server.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarItems(
                leading: Button("Cancel") {
                    if HostSettings.shared.isHostConfigured {
                        isPresented = false
                    }
                }
                .disabled(!HostSettings.shared.isHostConfigured),
                trailing: Button("Save") {
                    saveHost()
                }
                .disabled(host.isEmpty)
            )
        }
        .alert("Invalid URL", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enter a valid URL starting with http:// or https://")
        }
    }
    
    private func saveHost() {
        // Validate URL format
        guard let url = URL(string: host),
              (url.scheme == "http" || url.scheme == "https") else {
            showError = true
            return
        }
        
        // Save the host
        HostSettings.shared.host = host
        APIService.configure(baseURL: host)
        isPresented = false
    }
}

#Preview {
    HostSettingsView(isPresented: .constant(true))
} 
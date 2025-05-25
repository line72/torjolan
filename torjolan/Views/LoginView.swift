import SwiftUI
import UIKit

struct LoginView: View {
    @State private var username = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @State private var isShowingHostSettings = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Binding var isLoggedIn: Bool
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 30) {
                Spacer()
                
                // Logo/App Title
                Text("Tor Jolan")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.primary)
                
                // Login Form
                VStack(spacing: 20) {
                    TextField("Username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(maxWidth: horizontalSizeClass == .compact ? nil : 400)
                        .padding(.horizontal)
                        .disabled(isLoggingIn)
                        .textInputAutocapitalization(.never)
                        .autocapitalization(.none)
                    
                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    Button(action: login) {
                        if isLoggingIn {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Login")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: horizontalSizeClass == .compact ? nil : 400)
                    .padding(.horizontal)
                    .disabled(username.isEmpty || isLoggingIn)
                    
                    // Host Settings Button
                    Button(action: { isShowingHostSettings = true }) {
                        Label("Server Settings", systemImage: "server.rack")
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $isShowingHostSettings) {
            HostSettingsView(isPresented: $isShowingHostSettings)
        }
        .onAppear {
            // Check if host is configured
            if !HostSettings.shared.isHostConfigured {
                isShowingHostSettings = true
            }
        }
    }
    
    private func login() {
        isLoggingIn = true
        errorMessage = nil
        
        Task {
            do {
                let authResponse = try await APIService.shared.login(username: username)
                User.current = User(from: authResponse)
                withAnimation {
                    isLoggedIn = true
                }
            } catch {
                errorMessage = "Login failed. Please try again."
            }
            isLoggingIn = false
        }
    }
}

#Preview {
    LoginView(isLoggedIn: .constant(false))
} 

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct AppFlowView: View {
    @StateObject private var locationService = LocationService()
    @StateObject private var networkPermission = LocalNetworkPermission()
    @AppStorage("pp_hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("pp_localNetworkGranted") private var localNetworkGranted = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionGate: PermissionGate? = nil

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                ContentView(locationService: locationService)
                    .fullScreenCover(item: $permissionGate) { gate in
                        PermissionGateView(
                            gate: gate,
                            onCheckAgain: { refreshPermissions() }
                        )
                    }
                    .onAppear { refreshPermissions() }
                    .onChange(of: locationService.authorizationStatus) { _, _ in refreshPermissions() }
                    .onChange(of: networkPermission.status) { _, _ in refreshPermissions() }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { refreshPermissions() }
                    }
            } else {
                OnboardingFlowView(locationService: locationService) {
                    hasCompletedOnboarding = true
                }
            }
        }
    }

    private func refreshPermissions() {
        guard hasCompletedOnboarding else { return }

        let locStatus = locationService.authorizationStatus
        if locStatus == .denied || locStatus == .restricted {
            permissionGate = .location
            return
        }

        guard localNetworkGranted else {
            permissionGate = nil
            return
        }

        if networkPermission.status == .unknown {
            networkPermission.requestAuthorization()
            return
        }

        if networkPermission.status == .denied {
            permissionGate = .network
            return
        }

        permissionGate = nil
    }
}

private enum PermissionGate: String, Identifiable {
    case location
    case network

    var id: String { rawValue }
}

private struct PermissionGateView: View {
    let gate: PermissionGate
    var onCheckAgain: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Erneut prüfen") { onCheckAgain() }
                #if os(iOS)
                Button("Einstellungen öffnen") { openSettings() }
                .buttonStyle(.borderedProminent)
                #endif
            }
        }
        .padding()
    }

    private var title: String {
        switch gate {
        case .location: return "Standort benötigt"
        case .network: return "Lokales Netzwerk benötigt"
        }
    }

    private var message: String {
        switch gate {
        case .location:
            return "Der Zugriff auf den Standort wurde in den Einstellungen deaktiviert. Ohne diese Berechtigung kann die Party nicht korrekt funktionieren."
        case .network:
            return "Der Zugriff auf das lokale Netzwerk wurde deaktiviert. Ohne diese Berechtigung können Host und Gäste nicht verbunden werden."
        }
    }

    #if os(iOS)
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    #endif
}

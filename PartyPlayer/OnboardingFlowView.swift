import SwiftUI
import AVFoundation
#if os(iOS)
import CoreLocation
#endif
#if os(iOS)
import UIKit
#endif

struct OnboardingFlowView: View {
    @ObservedObject var locationService: LocationService
    var onComplete: () -> Void

    @StateObject private var networkPermission = LocalNetworkPermission()
    @AppStorage("pp_localNetworkGranted") private var localNetworkGranted = false
    @State private var didShowWelcome = false
    @State private var step: Step = .welcome

    enum Step {
        case welcome
        case location
        case network
        case camera
        case done
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                welcomeStep
            case .location:
                locationStep
            case .network:
                networkStep
            case .camera:
                cameraStep
            case .done:
                EmptyView()
            }
        }
        .onAppear { advanceIfNeeded() }
        .onChange(of: locationService.authorizationStatus) { _, _ in advanceIfNeeded() }
        .onChange(of: networkPermission.status) { _, _ in
            if networkPermission.status == .granted {
                localNetworkGranted = true
            }
            advanceIfNeeded()
        }
    }

    private var locationAllowed: Bool {
        switch locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    private var cameraAllowed: Bool {
        #if os(iOS)
        return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        #else
        return true
        #endif
    }

    private var shouldAskNetwork: Bool {
        #if os(iOS)
        return !localNetworkGranted
        #else
        return false
        #endif
    }

    private func nextStep() -> Step {
        if !didShowWelcome { return .welcome }
        if !locationAllowed { return .location }
        if shouldAskNetwork { return .network }
        if !cameraAllowed { return .camera }
        return .done
    }

    private func advanceIfNeeded() {
        let next = nextStep()
        step = next
        if next == .done {
            onComplete()
        }
    }

    private var welcomeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Willkommen bei Party Player")
                    .font(.title2.bold())
                Text(InfoContent.text)
                    .font(.body)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button("Weiter") {
                didShowWelcome = true
                advanceIfNeeded()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var locationStep: some View {
        let denied = (locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted)
        return PermissionExplainView(
            title: "Berechtigungen",
            message: "Als Nächstes fragen wir die System‑Berechtigungen ab, damit Host und Gäste zuverlässig verbunden werden können.",
            detailTitle: "Standort",
            detailMessage: "Wir prüfen die Entfernung zwischen Host und Gästen, damit nur Personen in der Nähe beitreten können.",
            primaryTitle: denied ? "Einstellungen öffnen" : "Berechtigung erlauben",
            primaryAction: {
                if denied {
                    openSettings()
                } else {
                    locationService.requestWhenInUse()
                }
            },
            secondaryTitle: denied ? "Erneut prüfen" : nil,
            secondaryAction: denied ? { advanceIfNeeded() } : nil
        )
    }

    private var networkStep: some View {
        let denied = (networkPermission.status == .denied)
        return OnboardingStepView(
            title: "Lokales Netzwerk",
            message: "Die Verbindung zwischen Host und Gästen läuft direkt im lokalen Netzwerk. Dafür brauchen wir diese Berechtigung.",
            primaryTitle: denied ? "Einstellungen öffnen" : "Berechtigung erlauben",
            primaryAction: {
                if denied {
                    openSettings()
                } else {
                    networkPermission.requestAuthorization()
                }
            },
            secondaryTitle: denied ? "Erneut prüfen" : nil,
            secondaryAction: denied ? { networkPermission.requestAuthorization() } : nil
        )
    }

    private var cameraStep: some View {
        #if os(iOS)
        let denied = (AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted)
        return OnboardingStepView(
            title: "Kamera",
            message: "Zum Beitreten scannen Gäste einen QR‑Code – dafür brauchen wir Kamerazugriff.",
            primaryTitle: denied ? "Einstellungen öffnen" : "Berechtigung erlauben",
            primaryAction: {
                if denied {
                    openSettings()
                } else {
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        DispatchQueue.main.async { advanceIfNeeded() }
                    }
                }
            },
            secondaryTitle: denied ? "Erneut prüfen" : nil,
            secondaryAction: denied ? { advanceIfNeeded() } : nil
        )
        #else
        return EmptyView()
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

private struct OnboardingStepView: View {
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

private struct PermissionExplainView: View {
    let title: String
    let message: String
    let detailTitle: String
    let detailMessage: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Text(detailTitle)
                    .font(.headline)
                Text(detailMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

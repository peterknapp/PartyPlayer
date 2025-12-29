import SwiftUI

struct AppFlowView: View {
    @StateObject private var locationService = LocationService()
    @AppStorage("pp_hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            ContentView(locationService: locationService)
        } else {
            OnboardingFlowView(locationService: locationService) {
                hasCompletedOnboarding = true
            }
        }
    }
}

import SwiftUI

@main
struct PartyPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            AppFlowView()
                .tint(Brand.accent)
        }
    }
}

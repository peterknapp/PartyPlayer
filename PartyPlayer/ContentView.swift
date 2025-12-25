import SwiftUI
import Combine
import MusicKit

struct ContentView: View {
    @StateObject private var locationService = LocationService()

    @State private var displayName: String = {
        #if os(macOS)
        return ""
        #else
        return UIDevice.current.name
        #endif
    }()

    @State private var mode: Mode? = nil

    @StateObject private var hostHolder = HostHolder()
    @StateObject private var guestHolder = GuestHolder()

    @State private var showScanner = false

    @State private var adminCode: String? = nil
    @State private var pendingAdminCodeSetup: Bool = false
    @State private var adminCodeInput1: String = ""
    @State private var adminCodeInput2: String = ""
    @State private var hostTab: HostTab = .publicView
    @State private var adminUnlocked: Bool = false
    @State private var showAdminPrompt: Bool = false
    @State private var adminPromptInput: String = ""
    @State private var adminPromptDismissWorkItem: DispatchWorkItem? = nil
    @State private var adminPromptShake: CGFloat = 0

    #if DEBUG
    @State private var showDebugOverlay = false
    #endif

    private var isRunningOnMac: Bool {
        #if os(macOS)
        return true
        #else
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return true }
            if ProcessInfo.processInfo.isMacCatalystApp { return true }
        }
        return false
        #endif
    }

    enum Mode {
        case host
        case guest
    }

    enum HostTab {
        case publicView, admin
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if hostHolder.host == nil && guestHolder.guest == nil {
                    VStack(spacing: 16) {
                        Text("Party Player").font(.largeTitle.bold())
                        HStack {
                            Button("Party anlegen") {
                                pendingAdminCodeSetup = true
                            }
                            Button("Party beitreten") {
                                if !isRunningOnMac {
                                    if guestHolder.guest == nil { startGuest() }
                                    showScanner = true
                                }
                            }
                            .disabled(isRunningOnMac)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    if let host = hostHolder.host {
                        HostTabsView(
                            host: host,
                            hostTab: $hostTab,
                            adminUnlocked: $adminUnlocked,
                            showAdminPrompt: $showAdminPrompt,
                            adminCode: $adminCode
                        )
                    }
                    if let guest = guestHolder.guest, !isRunningOnMac {
                        GuestView(guest: guest, showScanner: $showScanner)
                    }
                }
            }
            .sheet(isPresented: Binding(get: { !isRunningOnMac && showScanner }, set: { show in if !isRunningOnMac { showScanner = show } })) {
                QRScannerView { code in
                    handleScannedCode(code)
                }
            }
            .sheet(isPresented: $pendingAdminCodeSetup) {
                AdminCodeSetupView(
                    input1: $adminCodeInput1,
                    input2: $adminCodeInput2,
                    onConfirm: {
                        adminCode = adminCodeInput1
                        adminCodeInput1 = ""
                        adminCodeInput2 = ""
                        pendingAdminCodeSetup = false
                        startHost()
                        adminUnlocked = true
                        hostTab = .admin
                    },
                    onCancel: {
                        adminCodeInput1 = ""
                        adminCodeInput2 = ""
                        pendingAdminCodeSetup = false
                    }
                )
            }
            .sheet(isPresented: $showAdminPrompt, onDismiss: {
                adminPromptDismissWorkItem?.cancel()
                adminPromptDismissWorkItem = nil
                adminPromptInput = ""
            }) {
                AdminCodePromptView(
                    codeInput: $adminPromptInput,
                    shakeTrigger: $adminPromptShake,
                    onAppear: {
                        adminPromptDismissWorkItem?.cancel()
                        let work = DispatchWorkItem { showAdminPrompt = false }
                        adminPromptDismissWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
                    },
                    onSubmit: {
                        guard let code = adminCode else { return }
                        if adminPromptInput == code {
                            adminUnlocked = true
                            showAdminPrompt = false
                            hostTab = .admin
                        } else {
                            adminPromptInput = ""
                            adminPromptShake = 0
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                                adminPromptShake += 1
                            }
                        }
                    }
                )
            }
            .onAppear {
                locationService.requestWhenInUse()
                locationService.start()
            }
        }
        .safeAreaInset(edge: .bottom) {
            #if DEBUG
            if showDebugOverlay {
                DebugOverlayView()
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            } else {
                EmptyView()
            }
            #else
            EmptyView()
            #endif
        }
    }

    // MARK: - Actions

    private func startHost() {
        mode = .host
        let host = PartyHostController(
            hostName: (isRunningOnMac ? "Host" : UIDevice.current.name),
            locationService: locationService
        )
        host.startHosting()
        hostHolder.host = host
    }

    private func startGuest() {
        mode = .guest
        let guest = PartyGuestController(
            displayName: (isRunningOnMac ? "Gast" : UIDevice.current.name),
            hasAppleMusic: false,
            locationService: locationService
        )
        guestHolder.guest = guest
    }

    private func handleScannedCode(_ code: String) {
        let parts = code.split(separator: "|").map(String.init)
        guard parts.count == 3, parts[0] == "PP" else { return }

        let sessionID = parts[1]
        let joinCode = parts[2]

        guestHolder.guest?.startJoin(sessionID: sessionID, joinCode: joinCode)
    }
}

// MARK: - Shake Effect (Reusable)

private struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 12
    var shakesPerUnit: CGFloat = 5
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - Holders

final class HostHolder: ObservableObject {
    @Published var host: PartyHostController? = nil
}

final class GuestHolder: ObservableObject {
    @Published var guest: PartyGuestController? = nil
}

// MARK: - HostTabsView

private struct HostTabsView: View {
    @ObservedObject var host: PartyHostController
    @Binding var hostTab: ContentView.HostTab
    @Binding var adminUnlocked: Bool
    @Binding var showAdminPrompt: Bool
    @Binding var adminCode: String?

    @State private var adminLockTimer: Timer? = nil
    @State private var lastInteractionAt: Date = Date()

    @State private var nowPlayingRenderKey = UUID()
    @State private var adminAutoLockSeconds: Int = 0

    @State private var showAddSongs: Bool = false
    @State private var showSettings: Bool = false
    @State private var showInbox: Bool = false

    var badgeCount: Int {
        host.pendingVoteOutcomes.count + host.pendingSkipRequests.count
    }

    var body: some View {
        TabView(selection: $hostTab) {
            publicTab
                .tabItem { Label("Public", systemImage: "person.3") }
                .tag(ContentView.HostTab.publicView)

            adminTab
                .tabItem {
                    Label("Admin", systemImage: "gear")
                }
                .badge(badgeCount)
                .tag(ContentView.HostTab.admin)
        }
        .onChange(of: hostTab) { oldValue, newValue in
            nowPlayingRenderKey = UUID()
            if newValue == .admin {
                if !adminUnlocked {
                    hostTab = .publicView
                    if adminCode != nil {
                        showAdminPrompt = true
                    }
                } else {
                    scheduleAutoLock()
                }
            } else if oldValue == .admin && newValue == .publicView {
                // Manual switch away from Admin: lock immediately
                adminLockTimer?.invalidate()
                adminUnlocked = false
            }
        }
        .toolbar {
            if hostTab == .admin && adminUnlocked {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        registerInteraction()
                        showInbox = true
                    } label: {
                        Label("Meldungen", systemImage: "tray.full")
                            .overlay(alignment: .topTrailing) {
                                if badgeCount > 0 {
                                    ZStack {
                                        Circle().fill(Color.red)
                                        Text(String(min(badgeCount, 99)))
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    .frame(width: 16, height: 16)
                                    .offset(x: 8, y: -8)
                                }
                            }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        lockNow()
                    } label: {
                        Label("Sperren", systemImage: "lock.fill")
                    }
                }
            }
        }
    }

    private func scheduleAutoLock() {
        adminLockTimer?.invalidate()
        adminLockTimer = nil
        guard adminAutoLockSeconds > 0 else { return }
        adminLockTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(adminAutoLockSeconds), repeats: false) { _ in
            adminUnlocked = false
            hostTab = .publicView
        }
    }

    private func registerInteraction() {
        lastInteractionAt = Date()
        scheduleAutoLock()
    }

    private func lockNow() {
        adminLockTimer?.invalidate()
        adminUnlocked = false
        hostTab = .publicView
    }

    private var publicTab: some View {
        VStack(spacing: 0) {
            // Header and counters in a scrolling container, like admin
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("Zum Mitmachen QR scannen")
                            .font(.headline)
                        QRCodeView(text: "PP|\(host.state.sessionID)|\(host.joinCode)")
                    }

                    Text("Gäste: \(host.state.members.count)")
                        .font(.headline)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }

            // Playlist takes the remaining space, like admin's HostAdminPlaylist
            Group {
                if !host.state.queue.isEmpty {
                    List {
                        Section("Playlist") {
                            if let currentItem = currentItem {
                                HostReadOnlyRow(item: currentItem, isCurrent: true, progress: host.nowPlaying?.positionSeconds ?? 0)
                            }
                            ForEach(upcomingItems) { item in
                                HostReadOnlyRow(item: item, isCurrent: false, progress: 0)
                            }
                        }
                        Section("Bereits gespielt") {
                            ForEach(playedItems) { item in
                                HostPlayedReadOnlyRow(item: item)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemBackground))
                    .listStyle(.insetGrouped)
                    .frame(minHeight: 260)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var currentItem: QueueItem? {
        guard let nowID = host.state.nowPlayingItemID else { return nil }
        return host.state.queue.first(where: { $0.id == nowID })
    }

    private var upcomingItems: [QueueItem] {
        guard let currentID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == currentID }) else {
            return host.state.queue
        }
        let nextIndex = nowIdx + 1
        guard host.state.queue.indices.contains(nextIndex) else { return [] }
        return Array(host.state.queue[nextIndex...])
    }

    private var playedItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return []
        }
        return Array(host.state.queue[..<nowIdx])
    }

    private var adminTab: some View {
        VStack(spacing: 0) {
            // Header + Controls (keine ScrollView, damit die Liste den Rest füllt)
            VStack(spacing: 16) {
                Text("Gäste: \(host.state.members.count)")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button("Demo laden & Play") {
                        registerInteraction()
                        host.loadDemoAndPlay()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Play/Pause") {
                        registerInteraction()
                        host.togglePlayPause()
                    }
                    .buttonStyle(.bordered)

                    Button("Skip") {
                        registerInteraction()
                        host.skip()
                    }
                    .buttonStyle(.bordered)

                    Button("Songs hinzufügen") {
                        registerInteraction()
                        showAddSongs = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            if !host.state.queue.isEmpty {
                HostAdminPlaylist(host: host)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .onAppear { scheduleAutoLock() }
        .onDisappear { adminLockTimer?.invalidate() }
        .onChange(of: adminAutoLockSeconds) { _, _ in scheduleAutoLock() }
        .sheet(isPresented: $showAddSongs) {
            AdminAddSongsView(host: host) {
                showAddSongs = false
            }
        }
        .sheet(isPresented: $showSettings) {
            AdminSettingsView(
                host: host,
                adminAutoLockSeconds: $adminAutoLockSeconds,
                onDone: { showSettings = false },
                onInteraction: { registerInteraction() }
            )
        }
        .sheet(isPresented: $showInbox) {
            AdminInboxView(host: host) {
                showInbox = false
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct HostNowPlayingPanel: View {
    @ObservedObject var host: PartyHostController
    
    var body: some View {
        Group {
            if let currentID = host.state.nowPlayingItemID,
               let item = host.state.queue.first(where: { $0.id == currentID }) {
                HStack(spacing: 16) {
                    HostArtworkView(urlString: item.artworkURL, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing").font(.caption).foregroundStyle(.secondary)
                        Text(item.title).font(.headline).lineLimit(1)
                        Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: elapsed, total: total)
                        HStack {
                            Text(timeString(elapsed))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("-" + timeString(remaining))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 16) {
                    HostArtworkView(urlString: nil, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing").font(.caption).foregroundStyle(.secondary)
                        Text("—").font(.headline)
                        Text("").font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: 0, total: 1)
                        HStack {
                            Text("0:00").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text("-0:00").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    private var elapsed: Double {
        host.nowPlaying?.positionSeconds ?? 0
    }
    private var total: Double {
        guard let currentID = host.state.nowPlayingItemID,
              let item = host.state.queue.first(where: { $0.id == currentID }) else {
            return 1
        }
        return item.durationSeconds ?? 240
    }
    private var remaining: Double {
        max(0, total - elapsed)
    }
    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

private struct HostReadOnlyPlaylist: View {
    @ObservedObject var host: PartyHostController
    var body: some View {
        List {
            Section("Playlist") {
                ForEach(upcomingItems) { item in
                    // Simple list row, no highlighting or progress
                    Text("\(item.title) – \(item.artist)")
                        .lineLimit(1)
                }
            }
            Section("Bereits gespielt") {
                ForEach(playedItems) { item in
                    HostPlayedReadOnlyRow(item: item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(minHeight: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var upcomingItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return host.state.queue
        }
        let nextIndex = nowIdx + 1
        guard host.state.queue.indices.contains(nextIndex) else { return [] }
        return Array(host.state.queue[nextIndex...])
    }
    private var playedItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return []
        }
        return Array(host.state.queue[..<nowIdx])
    }
}

private struct HostPlayedReadOnlyRow: View {
    let item: QueueItem
    var body: some View {
        let total = max(1, item.durationSeconds ?? 240)
        HStack(spacing: 12) {
            HostArtworkView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Text("Up \(item.upVotes.count)")
                    Text("Down \(item.downVotes.count)")
                    Spacer()
                    Text(timeString(total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    
    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

private struct HostReadOnlyRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let progress: Double

    var body: some View {
        let total = max(1, item.durationSeconds ?? 240)
        let progressValue: Double = isCurrent ? progress : 0
        let remaining = max(0, total - progressValue)
        HStack(spacing: 12) {
            HostArtworkView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline).lineLimit(1)
                    if isCurrent {
                        Text("▶︎").font(.caption2).foregroundColor(.accentColor)
                            .padding(2).background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: progressValue, total: total)
                    .tint(.secondary)
                HStack {
                    HStack(spacing: 10) {
                        Text("Up \(item.upVotes.count)")
                        Text("Down \(item.downVotes.count)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if isCurrent {
                        HStack(spacing: 8) {
                            Text(timeString(progressValue))
                            Text("-" + timeString(remaining))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else {
                        Text(timeString(total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

private struct HostPendingApprovalsPanel: View {
    @ObservedObject var host: PartyHostController
    var body: some View {
        Group {
            if host.votingMode == .hostApproval && !host.pendingVoteOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Voting-Entscheidungen").font(.headline)
                    ForEach(host.pendingVoteOutcomes) { outcome in
                        let item = host.state.queue.first(where: { $0.id == outcome.itemID })
                        HStack(spacing: 12) {
                            HostArtworkView(urlString: item?.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item?.title ?? "Unbekannter Titel").font(.subheadline).lineLimit(1)
                                Text(item?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(label(for: outcome.kind)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ablehnen") { host.rejectVoteOutcome(id: outcome.id) }.buttonStyle(.bordered)
                            Button("Genehmigen") { host.approveVoteOutcome(id: outcome.id) }.buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func label(for kind: PartyHostController.PendingVoteOutcome.Kind) -> String {
        switch kind {
        case .promoteNext: return "Hinter Now Playing verschieben"
        case .removeFromQueue: return "Aus Playlist entfernen"
        case .sendToEnd: return "Ans Ende verschieben"
        }
    }
}

private struct HostSkipRequestsPanel: View {
    @ObservedObject var host: PartyHostController
    var body: some View {
        Group {
            if host.pendingSkipRequests.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Skip-Anfragen").font(.headline)
                    ForEach(host.pendingSkipRequests) { req in
                        let item = host.state.queue.first(where: { $0.id == req.itemID })
                        let requester = host.state.members.first(where: { $0.id == req.memberID })?.displayName ?? "Gast"
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item?.title ?? "Unbekannter Titel").font(.subheadline).lineLimit(1)
                                Text(item?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(requester)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ablehnen") { host.rejectSkipRequest(itemID: req.itemID, memberID: req.memberID) }.buttonStyle(.bordered)
                            Button("Skip freigeben") { host.approveSkipRequest(itemID: req.itemID) }.buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct HostRemovedItemsPanel: View {
    @ObservedObject var host: PartyHostController
    var body: some View {
        Group {
            if host.removedItems.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Entfernte Titel").font(.headline)
                    ForEach(host.removedItems) { item in
                        HStack(spacing: 12) {
                            HostArtworkView(urlString: item.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline).lineLimit(1)
                                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Ans Ende") { host.restoreRemovedToEnd(itemID: item.id) }.buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct HostAdminPlaylist: View {
    @ObservedObject var host: PartyHostController
    var body: some View {
        List {
            Section("Playlist") {
                ForEach(playlistItems) { item in
                    HostAdminRow(host: host, item: item, isCurrent: host.state.nowPlayingItemID == item.id, nowPlayingPos: host.nowPlaying?.positionSeconds ?? 0)
                }
            }
            Section("Bereits gespielt") {
                ForEach(playedItems) { item in
                    HostPlayedAdminRow(host: host, item: item)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .listStyle(.insetGrouped)
        .frame(minHeight: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var playlistItems: [QueueItem] {
        if let nowID = host.state.nowPlayingItemID,
           let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) {
            return Array(host.state.queue[nowIdx...])
        }
        return host.state.queue
    }
    private var upcomingItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return host.state.queue
        }
        let nextIndex = nowIdx + 1
        guard host.state.queue.indices.contains(nextIndex) else { return [] }
        return Array(host.state.queue[nextIndex...])
    }
    private var playedItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return []
        }
        return Array(host.state.queue[..<nowIdx])
    }
}

private struct HostAdminRow: View {
    @ObservedObject var host: PartyHostController
    let item: QueueItem
    let isCurrent: Bool
    let nowPlayingPos: Double
    var body: some View {
        let total = max(1, item.durationSeconds ?? 240)
        let pos = min(max(0, nowPlayingPos), total)
        return HStack(spacing: 12) {
            HostArtworkView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline).lineLimit(1)
                    if isCurrent {
                        Text("▶︎").font(.caption2).foregroundColor(.accentColor)
                            .padding(2).background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: isCurrent ? pos : 0, total: total)
                
                if isCurrent {
                    HStack {
                        Text(timeString(pos))
                        Spacer()
                        Text("-" + timeString(max(0, total - pos)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    Text(timeString(total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isCurrent {
                Button("Entfernen") { host.adminRemoveFromQueue(itemID: item.id) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(isCurrent ? Color.primary.opacity(0.06) : Color.clear)
    }
    
    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

private struct HostPlayedAdminRow: View {
    @ObservedObject var host: PartyHostController
    let item: QueueItem
    var body: some View {
        HStack(spacing: 12) {
            HostArtworkView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) { Text("Votes \(item.upVotes.count)") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ans Ende") { host.adminMoveToEnd(itemID: item.id) }
                .buttonStyle(.bordered)
        }
        .listRowBackground(Color.clear)
    }
}

private struct HostArtworkView: View {
    let urlString: String?
    let size: CGFloat
    var body: some View {
        let effectiveURLString: String? = {
            guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }()
        if let urlString = effectiveURLString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
            .id(effectiveURLString)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }
}

// MARK: - HostView (original, kept for potential reuse)

struct HostView: View {
    @ObservedObject var host: PartyHostController

    var body: some View {
        VStack(spacing: 12) {
            header
            nowPlayingBar
            controlsRow
            modeAndSettings
            pendingApprovalsPanel
            skipRequestsPanel
            removedItemsPanel
            playlist
        }
        .padding()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Session: \(host.state.sessionID)")
            Text("Join-Code: \(host.joinCode)")
            QRCodeView(text: "PP|\(host.state.sessionID)|\(host.joinCode)")
            Text("Gäste: \(host.state.members.count)")
                .font(.headline)
        }
    }

    private var modeAndSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voting-Modus:").font(.headline)
                Picker("Modus", selection: $host.votingMode) {
                    Text("Automatisch").tag(PartyHostController.VotingMode.automatic)
                    Text("Host-Genehmigung").tag(PartyHostController.VotingMode.hostApproval)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Text("Cooldown (Minuten):")
                Stepper(value: $host.perItemCooldownMinutes, in: 0...120) {
                    Text("\(host.perItemCooldownMinutes)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pendingApprovalsPanel: some View {
        Group {
            if host.votingMode == .hostApproval && !host.pendingVoteOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Voting-Entscheidungen")
                        .font(.headline)

                    ForEach(host.pendingVoteOutcomes) { outcome in
                        let item = host.state.queue.first(where: { $0.id == outcome.itemID })
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item?.title ?? "Unbekannter Titel")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(item?.artist ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(label(for: outcome.kind))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ablehnen") {
                                host.rejectVoteOutcome(id: outcome.id)
                            }
                            .buttonStyle(.bordered)
                            Button("Genehmigen") {
                                host.approveVoteOutcome(id: outcome.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyView()
            }
        }
    }

    private func label(for kind: PartyHostController.PendingVoteOutcome.Kind) -> String {
        switch kind {
        case .promoteNext: return "Hinter Now Playing verschieben"
        case .removeFromQueue: return "Aus Playlist entfernen"
        case .sendToEnd: return "Ans Ende verschieben"
        }
    }

    private var skipRequestsPanel: some View {
        Group {
            if host.pendingSkipRequests.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Skip-Anfragen")
                        .font(.headline)

                    ForEach(host.pendingSkipRequests) { req in
                        let item = host.state.queue.first(where: { $0.id == req.itemID })
                        let requester = host.state.members.first(where: { $0.id == req.memberID })?.displayName ?? "Gast"

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item?.title ?? "Unbekannter Titel")
                                    .font(.subheadline)
                                    .lineLimit(1)

                                Text(item?.artist ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Text("\(requester) · \(timeAgo(req.requestedAt))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Ablehnen") {
                                host.rejectSkipRequest(itemID: req.itemID, memberID: req.memberID)
                            }
                            .buttonStyle(.bordered)

                            Button("Skip freigeben") {
                                host.approveSkipRequest(itemID: req.itemID)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var removedItemsPanel: some View {
        Group {
            if host.removedItems.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Entfernte Titel")
                        .font(.headline)

                    ForEach(host.removedItems) { item in
                        HStack(spacing: 12) {
                            ArtworkView(urlString: item.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Ans Ende") {
                                host.restoreRemovedToEnd(itemID: item.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    private var nowPlayingBar: some View {
        let np = host.nowPlaying
        let currentID = host.state.nowPlayingItemID
        let currentItem = host.state.queue.first(where: { $0.id == currentID })

        let total = max(1, estimatedTotalSeconds(for: currentItem))
        let rawPos = np?.positionSeconds ?? 0
        let pos = min(max(0, rawPos), total)
        let remaining = max(0, total - pos)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 12) {
                    let resolvedArt = currentItem?.artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ArtworkView(urlString: resolvedArt, size: 46)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Now Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(currentItem?.title ?? "—")
                        .font(.headline)
                        .lineLimit(1)

                    Text(currentItem?.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeString(pos))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("-\(timeString(remaining))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: pos, total: total)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button("Demo laden & Play") { host.loadDemoAndPlay() }
                .buttonStyle(.borderedProminent)

            Button("Play/Pause") { host.togglePlayPause() }
                .buttonStyle(.bordered)

            Button("Skip") { host.skip() }
                .buttonStyle(.bordered)
        }
    }

    private var playlist: some View {
        ScrollViewReader { proxy in
            List {
                Section("Bevorstehend") {
                    ForEach(upcomingItems) { item in
                        playlistRow(item: item)
                            .id(item.id)
                    }
                }
                Section("Bereits gespielt") {
                    ForEach(playedItems) { item in
                        playedRow(item: item)
                            .id(item.id)
                    }
                }
            }
            .frame(minHeight: 260)
            .listStyle(.insetGrouped)
            .onChange(of: host.state.nowPlayingItemID) { _, newValue in
                guard let id = newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let id = host.state.nowPlayingItemID {
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var upcomingItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return host.state.queue
        }
        let nextIndex = nowIdx + 1
        guard host.state.queue.indices.contains(nextIndex) else { return [] }
        return Array(host.state.queue[nextIndex...])
    }

    private var playedItems: [QueueItem] {
        guard let nowID = host.state.nowPlayingItemID,
              let nowIdx = host.state.queue.firstIndex(where: { $0.id == nowID }) else {
            return []
        }
        return Array(host.state.queue[..<nowIdx])
    }

    private func playedRow(item: QueueItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Text("Votes \(item.upVotes.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ans Ende") { host.adminMoveToEnd(itemID: item.id) }
                .buttonStyle(.bordered)
        }
    }

    private func playlistRow(item: QueueItem) -> some View {
        let isCurrent = (host.state.nowPlayingItemID == item.id)

        let total = max(1, item.durationSeconds ?? 240)
        let rawPos = host.nowPlaying?.positionSeconds ?? 0
        let pos = min(max(0, rawPos), total)

        return HStack(spacing: 12) {
            ArtworkView(urlString: item.artworkURL, size: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)

                    if isCurrent {
                        Text("▶︎")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .padding(2)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: isCurrent ? pos : 0, total: total)

                HStack(spacing: 10) {
                    Text("Up \(item.upVotes.count)")
                    Text("Down \(item.downVotes.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isCurrent {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: (host.nowPlaying?.isPlaying ?? false) ? "speaker.wave.2.fill" : "pause.fill")

                    Text(timeString(pos))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(timeString(total))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(isCurrent ? Color.primary.opacity(0.06) : Color.clear)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    private func estimatedTotalSeconds(for item: QueueItem?) -> Double {
        if let d = item?.durationSeconds, d > 1 { return d }
        return 240
    }

    private struct ArtworkView: View {
        let urlString: String?
        let size: CGFloat

        var body: some View {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                placeholder
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }

        private var placeholder: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - PIN Code Field (Reusable, dot style)

private struct PinCodeField: View {
    let title: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding? = nil
    var length: Int = 4

    @FocusState private var localFocus: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            ZStack {
                // Dots row
                HStack(spacing: 24) {
                    ForEach(0..<length, id: \.self) { idx in
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 1.5)
                            .background(
                                Circle().fill(idx < text.count ? Color.primary : Color.clear)
                                    .opacity(idx < text.count ? 0.9 : 0)
                            )
                            .frame(width: 20, height: 20)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focus(true) }

                // Hidden text field to capture input
                hiddenInput
            }
        }
        .onChange(of: text) { _, newValue in
            let filtered = newValue.filter { $0.isNumber }
            if filtered != newValue { text = filtered }
            if text.count > length { text = String(text.prefix(length)) }
        }
        .onAppear { focus(true) }
    }

    @ViewBuilder private var hiddenInput: some View {
        #if os(iOS)
        TextField("", text: Binding(
            get: { text },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber }
                text = String(filtered.prefix(length))
            }
        ))
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .foregroundStyle(.clear)
        .tint(.clear)
        .accentColor(.clear)
        .disableAutocorrection(true)
        .frame(width: 1, height: 1)
        .opacity(0.05)
        .accessibilityHidden(true)
        .focused(focused ?? $localFocus)
        #else
        SecureField("", text: Binding(
            get: { text },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber }
                text = String(filtered.prefix(length))
            }
        ))
        .textFieldStyle(.plain)
        .frame(width: 1, height: 1)
        .opacity(0.05)
        .accessibilityHidden(true)
        .focused(focused ?? $localFocus)
        #endif
    }

    private func focus(_ value: Bool) {
        if let f = focused { f.wrappedValue = value } else { localFocus = value }
    }
}

// MARK: - CodeField (Reusable)

private struct CodeField: View {
    let title: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding? = nil

    @ViewBuilder var body: some View {
        #if os(iOS)
        let field = TextField(title, text: Binding(
            get: { text },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber }
                text = String(filtered.prefix(4))
            }
        ))
        .keyboardType(.numberPad)
        .textFieldStyle(.roundedBorder)
        if let f = focused { field.focused(f) } else { field }
        #else
        SecureField(title, text: Binding(
            get: { text },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber }
                text = String(filtered.prefix(4))
            }
        ))
        .textFieldStyle(.roundedBorder)
        #endif
    }
}

// MARK: - AdminCodeSetupView

private struct AdminCodeSetupView: View {
    @Binding var input1: String
    @Binding var input2: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @FocusState private var focusCode1: Bool
    @FocusState private var focusCode2: Bool
    @State private var mismatch: Bool = false
    @State private var shakeRepeat: CGFloat = 0

    var body: some View {
        VStack(spacing: 28) {
            Text("Admin-Code festlegen")
                .font(.title2.bold())
            Text("Bitte 4-stelligen numerischen Code zweimal eingeben.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PinCodeField(title: "Code eingeben", text: $input1, focused: $focusCode1)
                .onChange(of: input1) { _, newValue in
                    mismatch = false
                    if newValue.count >= 4 { focusCode2 = true }
                }

            if input1.count == 4 {
                VStack(spacing: 0) {
                    PinCodeField(title: "Code wiederholen", text: $input2, focused: $focusCode2)
                        .onChange(of: input2) { _, newValue in
                            if newValue.count == 4 {
                                if input1 == newValue {
                                    onConfirm()
                                } else {
                                    mismatch = true
                                    input2 = ""
                                    focusCode2 = true
                                    withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                                        shakeRepeat += 1
                                    }
                                }
                            }
                        }
                }
                .modifier(ShakeEffect(animatableData: shakeRepeat))
            }

            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel)
                Spacer()
                .buttonStyle(.borderedProminent)
                .disabled(!(input1.count == 4 && input1 == input2))
            }
        }
        .padding()
        .onAppear { focusCode1 = true }
        .presentationDetents([.medium])
    }
}

// MARK: - AdminCodePromptView

private struct AdminCodePromptView: View {
    @Binding var codeInput: String
    @Binding var shakeTrigger: CGFloat
    @FocusState private var focusCode: Bool
    var onAppear: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("Admin-Code eingeben")
                    .font(.title3.bold())
                PinCodeField(title: "", text: $codeInput, focused: $focusCode)
                    .onChange(of: codeInput) { _, newValue in
                        if newValue.count == 4 { onSubmit() }
                    }
            }
            .padding()
        }
        .modifier(ShakeEffect(animatableData: shakeTrigger))
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: shakeTrigger)
        .onAppear {
            focusCode = true
            onAppear()
        }
        .presentationDetents([.fraction(0.3)])
    }
}

// MARK: - GuestView

struct GuestView: View {
    @ObservedObject var guest: PartyGuestController
    @Binding var showScanner: Bool

    @State private var tick: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            if guest.status != .admitted {
                Button("QR scannen & beitreten") { showScanner = true }
            }

            Text(statusText)
                .font(.headline)
            
            if guest.status == .admitted {
                Text("Aktionen verfügbar: \(guest.remainingActionSlots)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let state = guest.state {
                if let card = nowPlayingCard(state: state) {
                    card
                }

                playlist(state: state)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding()
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if guest.status == .admitted {
                tick &+= 1
            }
        }
    }

    // MARK: - Voting availability

    private struct VoteAvailability {
        let canUp: Bool
        let canDown: Bool
        let opacity: Double
    }

    private func nextUpID(state: PartyState) -> UUID? {
        guard let nowID = state.nowPlayingItemID,
              let idx = state.queue.firstIndex(where: { $0.id == nowID }) else { return nil }
        let nextIndex = idx + 1
        guard state.queue.indices.contains(nextIndex) else { return nil }
        return state.queue[nextIndex].id
    }

    private func voteAvailability(
        state: PartyState,
        itemID: UUID,
        canInteract: Bool
    ) -> VoteAvailability {

        guard canInteract else {
            return .init(canUp: false, canDown: false, opacity: 0.55)
        }

        let isCurrent = (state.nowPlayingItemID == itemID)
        let isNextUp = (nextUpID(state: state) == itemID)

        // Regeln:
        // - Current: Up/Down disabled
        // - Next-Up: Up disabled, Down allowed
        let canUp = !isCurrent && !isNextUp
        let canDown = !isCurrent

        let opacity: Double = (isCurrent || isNextUp) ? 0.55 : 1.0
        return .init(canUp: canUp, canDown: canDown, opacity: opacity)
    }

    // MARK: - Playlist

    private func playlist(state: PartyState) -> some View {
        let canInteract = (guest.status == .admitted)

        // Derive played and upcoming arrays
        let nowID = state.nowPlayingItemID
        let nowIdx = nowID.flatMap { id in state.queue.firstIndex(where: { $0.id == id }) }
        let played: [QueueItem] = {
            if let idx = nowIdx { return Array(state.queue[..<idx]) }
            return []
        }()
        let upcoming: [QueueItem] = {
            if let idx = nowIdx {
                let nextIndex = idx + 1
                if state.queue.indices.contains(nextIndex) {
                    return Array(state.queue[nextIndex...])
                } else {
                    return []
                }
            }
            return state.queue
        }()

        return ScrollViewReader { proxy in
            List {
                Section("Bevorstehend") {
                    ForEach(upcoming) { item in
                        guestQueueRow(
                            state: state,
                            item: item,
                            canInteract: canInteract,
                            nowPlayingID: guest.nowPlaying?.nowPlayingItemID,
                            nowPlayingPos: guest.nowPlaying?.positionSeconds ?? 0
                        )
                        .id(item.id)
                    }
                }
                Section("Bereits gespielt") {
                    ForEach(played) { item in
                        playedGuestRow(state: state, item: item, canInteract: canInteract)
                            .id(item.id)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: guest.nowPlaying?.nowPlayingItemID) { _, newValue in
                guard let id = newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Now Playing card

    private func nowPlayingCard(state: PartyState) -> AnyView? {
        guard let np = guest.nowPlaying else { return nil }

        let current: QueueItem? = {
            guard let id = np.nowPlayingItemID else { return nil }
            return state.queue.first(where: { $0.id == id })
        }()

        let title = current?.title ?? "—"
        let artist = current?.artist ?? ""
        let artworkURL = current?.artworkURL

        let total = max(1, current?.durationSeconds ?? 240)
        let pos = min(max(0, np.positionSeconds), total)
        let remaining = max(0, total - pos)

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkThumbView(urlString: artworkURL, size: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jetzt läuft")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        if !artist.isEmpty {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(timeString(pos))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text("-\(timeString(remaining))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: pos, total: total)
                    .tint(.primary)

                Text(np.isPlaying ? "Playing" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
    }

    private func guestQueueRow(
        state: PartyState,
        item: QueueItem,
        canInteract: Bool,
        nowPlayingID: UUID?,
        nowPlayingPos: Double
    ) -> some View {

        let isCurrent = (nowPlayingID == item.id)
        let availability = voteAvailability(state: state, itemID: item.id, canInteract: canInteract)

        let total = max(1, item.durationSeconds ?? 240)
        let pos = min(max(0, nowPlayingPos), total)
        let remaining = max(0, total - pos)

        let baseRemaining = guest.itemCooldowns[item.id] ?? 0
        let elapsed = Date().timeIntervalSince(guest.lastSnapshotAt)
        let remainingCooldown = max(0, baseRemaining - elapsed)
        let isCoolingDown = remainingCooldown > 0.5

        // Removed line:
        // let alreadyDecided = guest.decidedItems.contains(item.id)
        let hasSlots = guest.remainingActionSlots > 0

        return VStack(spacing: 8) {
            headerRow(item: item, isCurrent: isCurrent, pos: pos, remaining: remaining, total: total)

            ProgressView(value: isCurrent ? pos : 0, total: total)

            HStack {
                HStack(spacing: 10) {
                    Text("Up \(item.upVotes.count)")
                    Text("Down \(item.downVotes.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if isCoolingDown {
                    Text("Cooldown: \(shortCooldownString(remainingCooldown))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VoteButtons(
                    availability: VoteAvailability(
                        canUp: availability.canUp && !isCoolingDown && hasSlots,
                        canDown: availability.canDown && !isCoolingDown && hasSlots,
                        opacity: (isCoolingDown || !hasSlots) ? 0.55 : availability.opacity
                    ),
                    upAction: { guest.voteUp(itemID: item.id) },
                    downAction: { guest.voteDown(itemID: item.id) }
                )
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(isCurrent ? Color.primary.opacity(0.06) : Color.clear)
    }

    private func playedGuestRow(state: PartyState, item: QueueItem, canInteract: Bool) -> some View {
        let baseRemaining = guest.itemCooldowns[item.id] ?? 0
        let elapsed = Date().timeIntervalSince(guest.lastSnapshotAt)
        let remainingCooldown = max(0, baseRemaining - elapsed)
        let isCoolingDown = remainingCooldown > 0.5
        let hasSlots = guest.remainingActionSlots > 0

        return HStack(spacing: 12) {
            ArtworkThumbView(urlString: item.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Text("Votes \(item.upVotes.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isCoolingDown {
                    Text("Cooldown: \(shortCooldownString(remainingCooldown))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Ans Ende") {
                    // Request host approval to send to end for played items
                    guest.voteDown(itemID: item.id) // leverage existing logic: host interprets played votes as send-to-end
                }
                .buttonStyle(.bordered)
                .disabled(!canInteract || isCoolingDown || !hasSlots)
            }
        }
    }

    private func headerRow(
        item: QueueItem,
        isCurrent: Bool,
        pos: Double,
        remaining: Double,
        total: Double
    ) -> some View {

        HStack(alignment: .top, spacing: 12) {
            ArtworkThumbView(urlString: item.artworkURL, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if isCurrent {
                    Text(timeString(pos))
                    Text("-\(timeString(remaining))")
                } else {
                    Text(timeString(total))
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private struct VoteButtons: View {
        let availability: VoteAvailability
        let upAction: () -> Void
        let downAction: () -> Void

        @State private var tapLocked = false

        var body: some View {
            HStack(spacing: 12) {
                Button("Up") {
                    DebugLog.shared.add("GUEST-UI", "tap Up canUp=\(availability.canUp) tapLocked=\(tapLocked)")
                    guard availability.canUp, !tapLocked else {
                        DebugLog.shared.add("GUEST-UI", "ignored Up (disabled or locked)")
                        return
                    }
                    tapLocked = true
                    upAction()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tapLocked = false }
                }
                .buttonStyle(.bordered)
                .disabled(!availability.canUp)
                .frame(minWidth: 68)
                .contentShape(Rectangle())

                Button("Down") {
                    DebugLog.shared.add("GUEST-UI", "tap Down canDown=\(availability.canDown) tapLocked=\(tapLocked)")
                    guard availability.canDown, !tapLocked else {
                        DebugLog.shared.add("GUEST-UI", "ignored Down (disabled or locked)")
                        return
                    }
                    tapLocked = true
                    downAction()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tapLocked = false }
                }
                .buttonStyle(.bordered)
                .disabled(!availability.canDown)
                .frame(minWidth: 68)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Status / formatting

    private var statusText: String {
        switch guest.status {
        case .idle: return "Nicht verbunden"
        case .scanning: return "Scanne…"
        case .connecting: return "Verbinde…"
        case .reconnecting: return "Bereits angemeldet – verbinde erneut…"
        case .admitted: return "Dabei"
        case .rejected(let reason): return "Abgelehnt: \(reason)"
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    private func shortCooldownString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return String(format: "%dm %02ds", m, r) }
        let h = m / 60
        let mm = m % 60
        return String(format: "%dh %02dm", h, mm)
    }
}

// MARK: - Shared Artwork Thumb (for GuestView)

private struct ArtworkThumbView: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AdminAddSongsView: View {
    @ObservedObject var host: PartyHostController
    var onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var results: [Song] = []
    @State private var isSearching = false
    @State private var selected: Set<MusicItemID> = []
    @State private var errorMessage: String? = nil

    // Debounce search
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                content
            }
            .navigationTitle("Songs suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") { addSelected() }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Titel, Künstler…", text: $searchText)
                .textFieldStyle(.plain)
                .onChange(of: searchText) { _, newValue in scheduleSearch(for: newValue) }
            if !searchText.isEmpty {
                Button(action: { searchText = ""; results = []; selected.removeAll() }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding([.horizontal, .top])
    }

    @ViewBuilder private var content: some View {
        if let msg = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                Text(msg).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else if isSearching {
            VStack(spacing: 12) {
                ProgressView()
                Text("Suche…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                Text("Gib einen Suchbegriff ein, um Apple Music zu durchsuchen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results, id: \.id) { song in
                SongRow(song: song, isSelected: selected.contains(song.id)) {
                    toggleSelection(song.id)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func scheduleSearch(for term: String) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { self.results = []; self.isSearching = false; self.errorMessage = nil; return }
        isSearching = true
        errorMessage = nil
        searchTask = Task { @MainActor in
            // Debounce ~250ms
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await host.searchCatalogSongs(term: trimmed, limit: 25)
                guard !Task.isCancelled else { return }
                self.results = found
                self.isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.isSearching = false
                self.errorMessage = (error as NSError).localizedDescription
            }
        }
    }

    private func toggleSelection(_ id: MusicItemID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func addSelected() {
        let songs = results.filter { selected.contains($0.id) }
        host.adminAppendSongs(songs)
        close()
    }

    private func close() {
        dismiss()
        onClose()
    }

    // MARK: - Row
    private struct SongRow: View {
        let song: Song
        let isSelected: Bool
        let onTap: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                // Artwork
                if let url = song.artwork?.url(width: 80, height: 80) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholder.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.headline).lineLimit(1)
                    Text(song.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }

        private var placeholder: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }
}

private struct AdminSettingsView: View {
    @ObservedObject var host: PartyHostController
    @Binding var adminAutoLockSeconds: Int
    var onDone: () -> Void
    var onInteraction: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Voting-Modus") {
                    Picker("Modus", selection: $host.votingMode) {
                        Text("Automatisch").tag(PartyHostController.VotingMode.automatic)
                        Text("Host-Genehmigung").tag(PartyHostController.VotingMode.hostApproval)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Limits") {
                    Stepper(value: $host.perItemCooldownMinutes, in: 0...120) {
                        HStack {
                            Text("Cooldown (Minuten)")
                            Spacer()
                            Text("\(host.perItemCooldownMinutes)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: $host.voteThresholdPercent, in: 0...100) {
                        HStack {
                            Text("Voting-Hürde (%)")
                            Spacer()
                            Text("\(host.voteThresholdPercent)%")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: $host.maxConcurrentActions, in: 1...10) {
                        HStack {
                            Text("Aktion-Slots")
                            Spacer()
                            Text("\(host.maxConcurrentActions)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Sicherheit") {
                    Stepper(value: $adminAutoLockSeconds, in: 0...120) {
                        HStack {
                            Text("Admin-Sperre (Sek.)")
                            Spacer()
                            Text("\(adminAutoLockSeconds)s")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { close() }
                }
            }
            .onChange(of: host.votingMode) { _, _ in onInteraction() }
            .onChange(of: host.perItemCooldownMinutes) { _, _ in onInteraction() }
            .onChange(of: host.voteThresholdPercent) { _, _ in onInteraction() }
            .onChange(of: host.maxConcurrentActions) { _, _ in onInteraction() }
            .onChange(of: adminAutoLockSeconds) { _, _ in onInteraction() }
        }
    }

    private func close() {
        dismiss()
        onDone()
    }
}

private struct AdminInboxView: View {
    @ObservedObject var host: PartyHostController
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HostPendingApprovalsPanel(host: host)
                    HostSkipRequestsPanel(host: host)
                    HostRemovedItemsPanel(host: host)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle("Meldungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { close() }
                }
            }
        }
    }

    private func close() {
        dismiss()
        onDone()
    }
}


import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var locationService = LocationService()

    @State private var displayName: String = UIDevice.current.name
    @State private var mode: Mode? = nil

    @StateObject private var hostHolder = HostHolder()
    @StateObject private var guestHolder = GuestHolder()

    @State private var showScanner = false

    // Debug-Overlay soll existieren, aber standardmäßig nicht sichtbar sein
    #if DEBUG
    @State private var showDebugOverlay = false
    #endif

    enum Mode {
        case host
        case guest
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Party Player")
                    .font(.largeTitle.bold())
                    #if DEBUG
                    .onLongPressGesture(minimumDuration: 0.6) {
                        showDebugOverlay.toggle()
                    }
                    #endif

                TextField("Dein Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                if mode == nil {
                    HStack {
                        Button("Ich bin Host") { startHost() }
                            .disabled(mode != nil)

                        Button("Ich bin Gast") { startGuest() }
                            .disabled(mode != nil)
                    }
                }

                if let host = hostHolder.host {
                    HostView(host: host)
                }

                if let guest = guestHolder.guest {
                    GuestView(guest: guest, showScanner: $showScanner)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    handleScannedCode(code)
                }
            }
            .onAppear {
                locationService.requestWhenInUse()
                locationService.start()
            }
        }
        // Debug panel: UI standardmäßig aus, aber per Long-Press einschaltbar
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
            hostName: displayName,
            locationService: locationService
        )
        host.startHosting()
        hostHolder.host = host
    }

    private func startGuest() {
        mode = .guest
        let guest = PartyGuestController(
            displayName: displayName,
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

// MARK: - Holders

final class HostHolder: ObservableObject {
    @Published var host: PartyHostController? = nil
}

final class GuestHolder: ObservableObject {
    @Published var guest: PartyGuestController? = nil
}

// MARK: - HostView

struct HostView: View {
    @ObservedObject var host: PartyHostController

    var body: some View {
        VStack(spacing: 12) {
            header
            nowPlayingBar
            controlsRow
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
                    ArtworkView(urlString: currentItem?.artworkURL, size: 46)

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

    // Scroll-to-current im Host
    private var playlist: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(host.state.queue) { item in
                    playlistRow(item: item)
                        .id(item.id)
                }
            }
            .frame(minHeight: 260)
            .listStyle(.plain)
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

    private func playlistRow(item: QueueItem) -> some View {
        let isCurrent = (host.state.nowPlayingItemID == item.id)

        let total = max(1, item.durationSeconds ?? 240)
        let rawPos = host.nowPlaying?.positionSeconds ?? 0
        let pos = min(max(0, rawPos), total)

        return HStack(spacing: 12) {
            ArtworkView(urlString: item.artworkURL, size: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

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
                    Image(systemName: (host.nowPlaying?.isPlaying ?? false)
                          ? "speaker.wave.2.fill"
                          : "pause.fill")

                    Text(timeString(pos))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                // Bei nicht aktuellen Tracks: Gesamtdauer anzeigen
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

// MARK: - GuestView

struct GuestView: View {
    @ObservedObject var guest: PartyGuestController
    @Binding var showScanner: Bool

    var body: some View {
        VStack(spacing: 12) {
            Button("QR scannen & beitreten") { showScanner = true }

            Text(statusText)
                .font(.headline)

            if let state = guest.state {
                if let card = nowPlayingCard(state: state) {
                    card
                }

                playlist(state: state)
                    .frame(height: 320)
            }
        }
        .padding()
    }

    private func playlist(state: PartyState) -> some View {
        let canInteract = (guest.status == .admitted)

        return ScrollViewReader { proxy in
            List(state.queue) { item in
                guestQueueRow(
                    item: item,
                    canInteract: canInteract,
                    nowPlayingID: guest.nowPlaying?.nowPlayingItemID,
                    nowPlayingPos: guest.nowPlaying?.positionSeconds ?? 0
                )
                .id(item.id)
            }
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
        let rawPos = np.positionSeconds
        let pos = min(max(0, rawPos), total)
        let remaining = max(0, total - pos)

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkView(urlString: artworkURL, size: 54)

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

                HStack(spacing: 8) {
                    Text(np.isPlaying ? "Playing" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
    }

    private func guestQueueRow(
        item: QueueItem,
        canInteract: Bool,
        nowPlayingID: UUID?,
        nowPlayingPos: Double
    ) -> some View {
        let isCurrent = (nowPlayingID == item.id)

        let total = max(1, item.durationSeconds ?? 240)
        let rawPos = nowPlayingPos
        let pos = min(max(0, rawPos), total)
        let remaining = max(0, total - pos)

        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(urlString: item.artworkURL, size: 44)

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
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text("-\(timeString(remaining))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(timeString(total))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView(value: isCurrent ? pos : 0, total: total)

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Up \(item.upVotes.count)")
                    Text("Down \(item.downVotes.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 12) {
                    Button("Up") { guest.voteUp(itemID: item.id) }
                        .disabled(!canInteract)

                    Button("Down") { guest.voteDown(itemID: item.id) }
                        .disabled(!canInteract)

                    Button("Skip") { guest.requestSkip(itemID: item.id) }
                        .disabled(!canInteract)
                }
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(isCurrent ? Color.primary.opacity(0.06) : Color.clear)
    }

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
}

private struct ArtworkView: View {
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

import Foundation
import Network

@MainActor
final class LocalNetworkPermission: ObservableObject {
    enum Status {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var status: Status = .unknown

    private var browser: NWBrowser?
    private var listener: NWListener?

    func requestAuthorization() {
        guard browser == nil, listener == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = .denied
            cleanup()
            return
        }

        let browser = NWBrowser(for: .bonjour(type: "_partyplayer._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handle(state: NWBrowser.State) {
        switch state {
        case .ready:
            status = .granted
            cleanup()
        case .failed(let error):
            if case .posix(let code) = error, code == .EPERM {
                status = .denied
            } else {
                status = .denied
            }
            cleanup()
        default:
            break
        }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            status = .granted
            cleanup()
        case .failed(let error):
            if case .posix(let code) = error, code == .EPERM {
                status = .denied
            } else {
                status = .denied
            }
            cleanup()
        default:
            break
        }
    }

    private func cleanup() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
    }
}

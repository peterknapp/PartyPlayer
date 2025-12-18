import SwiftUI

struct DebugOverlayView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var isExpanded = false

    var body: some View {
        #if DEBUG
        VStack(spacing: 8) {
            HStack {
                Text("Debug")
                    .font(.headline)

                Spacer()

                Button(isExpanded ? "Min" : "Max") { isExpanded.toggle() }
                Button("Clear") { log.clear() }
            }

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(log.entries) { e in
                                Text("\(timeString(e.time)) [\(e.tag)] \(e.message)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(e.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    // ✅ iOS 17 signature
                    .onChange(of: log.entries.count) { _, _ in
                        if let last = log.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                if let last = log.entries.last {
                    Text("[\(last.tag)] \(last.message)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                } else {
                    Text("—")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
        #else
        EmptyView()
        #endif
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}

import SwiftUI

struct QueueItem: Identifiable {
    let id = UUID()
    let username: String
    let preview: String
    let source: Source
    let startTime: Date
    var status: Status

    enum Source: String {
        case desktop = "Desktop"
        case telegram = "Telegram"
        case telegramInline = "Inline"
    }

    enum Status {
        case generating
        case queued
        case searching
        case thinking
    }

    var statusText: String {
        switch status {
        case .generating: return "Generating..."
        case .queued: return "In queue"
        case .searching: return "Searching web..."
        case .thinking: return "Thinking..."
        }
    }

    var statusColor: Color {
        switch status {
        case .generating: return .green
        case .queued: return .orange
        case .searching: return .blue
        case .thinking: return .purple
        }
    }

    var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

@MainActor
class QueueMonitor: ObservableObject {
    static let shared = QueueMonitor()
    @Published var items: [QueueItem] = []

    func add(username: String, preview: String, source: QueueItem.Source, status: QueueItem.Status = .queued) -> UUID {
        let item = QueueItem(username: username, preview: preview, source: source, startTime: .now, status: status)
        items.append(item)
        return item.id
    }

    func updateStatus(_ id: UUID, status: QueueItem.Status) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = status
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

struct QueueMonitorView: View {
    @ObservedObject var monitor: QueueMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var tick = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title3)
                Text("Processing Queue")
                    .font(.title3.bold())
                Spacer()
                Text("\(monitor.items.count)")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if monitor.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Queue is empty")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Messages will appear here when being processed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(monitor.items.enumerated()), id: \.element.id) { index, item in
                            QueueItemRow(item: item, position: index + 1, tick: tick)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 400, height: 350)
        .onAppear { startTimer() }
    }

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in tick.toggle() }
        }
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let position: Int
    let tick: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Position
            ZStack {
                Circle()
                    .fill(position == 1 ? item.statusColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    .frame(width: 28, height: 28)
                if position == 1 {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(position)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.username)
                        .font(.callout.bold())
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(item.source.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Text(item.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status + time
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.statusColor)
                        .frame(width: 6, height: 6)
                    Text(item.statusText)
                        .font(.caption2)
                        .foregroundStyle(item.statusColor)
                }

                // Elapsed time (ticks to update)
                let _ = tick
                Text(formatElapsed(item.elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(position == 1 ? item.statusColor.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.08)))
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

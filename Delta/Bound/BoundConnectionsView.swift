import SwiftUI

struct BoundConnectionsView: View {
    @ObservedObject var feed: BoundConnectionFeed
    var gameID = ""
    var isActive = true
    var showsHeader = true

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, HH:mm:ss.SSS z"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 8) {
                    Text("Connections").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button { feed.clear() } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(feed.entries.isEmpty)
                    .accessibilityLabel("Clear connection feed")
                    .accessibilityIdentifier("bound.connections-clear")
                }
                .padding(.leading, 12).padding(.trailing, 4)
                Divider()
            }
            if feed.entries.isEmpty {
                Text("No connection events")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("bound.connections-empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(feed.entries) { entry in
                            event(entry)
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .boundControllerScroll(gameID: gameID, content: .connections, active: isActive)
                .accessibilityIdentifier("bound.connections-list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.connections")
    }

    private func event(_ entry: BoundConnectionFeed.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color(for: entry.kind))
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.footnote.weight(.medium))
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bound.connection-event." + entry.id.uuidString)
    }

    private func color(for kind: BoundConnectionFeed.Kind) -> Color {
        switch kind {
        case .connected, .reconnected, .friendJoined, .friendReconnected: .green
        case .connecting, .retrying, .reconnecting, .connectionLost, .friendConnectionLost, .connectionUnavailable: .orange
        default: .secondary
        }
    }
}

// The screen keeps the legacy .connections identity so saved placement and mappings survive.
enum BoundHistoryTab: String, CaseIterable {
    case connections = "Connections", timeline = "Run Timeline"
    static func allowed(connections: Bool, timeline: Bool) -> [Self] {
        (connections ? [.connections] : []) + (timeline ? [.timeline] : [])
    }
    static func selection(_ selected: Self, allowed: [Self]) -> Self? {
        allowed.contains(selected) ? selected : allowed.first
    }
}

struct BoundHistoryView: View {
    @ObservedObject var feed: BoundConnectionFeed
    let timeline: BoundRunTimeline
    var connectionsAllowed: Bool
    var timelineAllowed: Bool
    var gameID = ""
    var isActive = true
    @State private var selected: BoundHistoryTab = .connections
    private var allowed: [BoundHistoryTab] {
        BoundHistoryTab.allowed(connections: connectionsAllowed, timeline: timelineAllowed)
    }
    private var effective: BoundHistoryTab? { BoundHistoryTab.selection(selected, allowed: allowed) }
    var body: some View {
        VStack(spacing: 0) {
            if let effective {
                HStack(spacing: 4) {
                    Picker("History", selection: Binding(get: { effective }, set: { selected = $0 })) {
                        ForEach(allowed, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).controlSize(.small)
                    .accessibilityIdentifier("bound.history-tabs")
                    if effective == .connections {
                        Button { feed.clear() } label: { Image(systemName: "trash").frame(width: 32, height: 32) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(feed.entries.isEmpty)
                            .accessibilityLabel("Clear connection feed").accessibilityIdentifier("bound.connections-clear")
                    }
                }.padding(6)
                if effective == .connections {
                    BoundConnectionsView(feed: feed, gameID: gameID, isActive: isActive, showsHeader: false)
                } else {
                    BoundRunTimelineView(timeline: timeline, gameID: gameID, isActive: isActive)
                }
            }
        }
        .accessibilityIdentifier("bound.history")
        .onChange(of: allowed, initial: true) { _, choices in
            if let next = BoundHistoryTab.selection(selected, allowed: choices) { selected = next }
        }
        .onReceive(NotificationCenter.default.publisher(for: BoundControllerNavigationEvent.notificationName)) { event in
            guard isActive, allowed.count > 1,
                  let command = BoundControllerNavigationEvent.command(from: event, gameID: gameID, content: .connections),
                  [.focusLeft, .focusRight, .previousItem, .nextItem].contains(command),
                  let effective, let index = allowed.firstIndex(of: effective) else { return }
            let step = [.focusLeft, .previousItem].contains(command) ? -1 : 1
            selected = allowed[(index + step + allowed.count) % allowed.count]
        }
    }
}

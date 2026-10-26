import SwiftUI

/// Loading and inspecting a point are deliberately separate actions. Merely
/// moving controller focus or opening its sheet cannot mutate either player.
struct BoundDebugView: View {
    @ObservedObject var session: BoundDebugSession
    var gameID: String
    var isActive = true
    var settings: () -> Data?
    @AppStorage(BoundMultiplayerFeatures.key) private var enabled = false
    @State private var selected: String?
    @State private var detail: BoundDebugPoint?
    @State private var focusesInfo = false
    @State private var report: URL?
    @State private var reportError = false

    private var canLoad: Bool { enabled && session.isController && !session.isBusy && settings()?.count == 32 }
    private var focusIDs: [String] {
        let sessionActions: [String]
        if session.serverSession == nil || session.serverSession?.status == .revoked {
            sessionActions = ["create"] + session.invitations.filter { $0.status != .revoked }.map { "join:" + $0.sessionID.uuidString } + ["refresh"]
        } else { sessionActions = ["retry", "end"] }
        return (enabled ? sessionActions : []) + BoundDebugCatalog.points.map(\.id) + ["reload", "custom"]
            + session.captures.map { "capture:" + $0.id.uuidString } + ["return", "report"]
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DEBUG").font(.subheadline.weight(.semibold))
                Spacer()
                Text(session.status.rawValue).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sessionControls.padding(12)
                        if let failure = session.failure {
                            Text(failure.localizedDescription).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                        }
                        ForEach(BoundDebugCatalog.points) { point in
                            HStack(spacing: 0) {
                                Button { load(point) } label: {
                                    HStack {
                                        Text(point.title).font(.footnote.weight(.medium)).multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                        if session.currentPointID == point.id {
                                            Text(session.status.rawValue).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }.padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .disabled(!canLoad)
                                .background(selected == point.id && !focusesInfo ? Color.accentColor.opacity(0.18) : .clear)
                                .accessibilityIdentifier("bound.debug.load." + point.id)
                                Button { detail = point } label: {
                                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                                }
                                .background(selected == point.id && focusesInfo ? Color.accentColor.opacity(0.18) : .clear)
                                .accessibilityLabel("About " + point.title)
                                .accessibilityIdentifier("bound.debug.info." + point.id)
                            }.buttonStyle(.plain).id(point.id)
                            Divider()
                        }
                        utilityControls.padding(12)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: BoundControllerNavigationEvent.notificationName)) { notification in
                    guard isActive, let command = BoundControllerNavigationEvent.command(from: notification, gameID: gameID, content: .debug) else { return }
                    navigate(command)
                    if let selected { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityIdentifier("bound.debug")
        .sheet(item: $detail) { point in
            NavigationStack {
                List {
                    info("Location", point.location)
                    info("Prerequisites", point.prerequisites)
                    info("Items, teams and rules", point.mechanics)
                    info("Encounter", point.format)
                    info("Test purpose", point.purpose)
                    info("Native steps", point.nativeSteps)
                }
                .navigationTitle(point.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
            }
        }
        .onChange(of: isActive) { _, active in if !active { selected = nil; detail = nil } }
        .task(id: isActive && enabled) {
            if isActive && enabled { await session.reconcile(); await session.listInvitations(); await session.refreshCaptures() }
        }
    }

    @ViewBuilder private var sessionControls: some View {
        if !enabled {
            Text("Enable Experimental Multiplayer to pair.").font(.caption).foregroundStyle(.secondary)
        } else if session.serverSession == nil || session.serverSession?.status == .revoked {
            Button("Create DEBUG Session") { Task { await session.createSession() } }
                .disabled(session.isBusy).background(focusColor("create")).id("create").accessibilityIdentifier("bound.debug.create")
            ForEach(session.invitations.filter { $0.status != .revoked }) { invitation in
                Button("Join DEBUG Session") {
                    Task { await session.join(sessionID: invitation.sessionID, membershipEpoch: invitation.membershipEpoch) }
                }.disabled(session.isBusy).background(focusColor("join:" + invitation.sessionID.uuidString))
                    .id("join:" + invitation.sessionID.uuidString).accessibilityIdentifier("bound.debug.join")
            }
            Button("Refresh") { Task { await session.listInvitations() } }.disabled(session.isBusy).background(focusColor("refresh")).id("refresh")
        } else {
            HStack {
                Button("Retry") { Task { await session.reconcile(); await session.refreshCaptures() } }.disabled(session.isBusy).background(focusColor("retry")).id("retry")
                Spacer()
                Button(session.isController ? "End Session" : "Leave Session") {
                    Task { if session.isController { await session.revoke() } else { await session.leave() } }
                }.disabled(session.isBusy).background(focusColor("end")).id("end")
            }
        }
    }
    private var utilityControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Reload Current Point") { Task { await session.reload() } }
                .disabled(!canLoad || session.manifest == nil).background(focusColor("reload")).id("reload").accessibilityIdentifier("bound.debug.reload")
            Button("Save Custom Point") { Task { await session.saveCustom() } }
                .disabled(!canLoad || session.manifest == nil || session.terminal != nil).background(focusColor("custom")).id("custom").accessibilityIdentifier("bound.debug.custom")
            ForEach(session.captures) { capture in
                Button("Load Custom \(capture.operation.generation)") { Task { await session.reloadCustom(capture) } }
                    .disabled(!canLoad).background(focusColor("capture:" + capture.id.uuidString)).id("capture:" + capture.id.uuidString)
                    .accessibilityIdentifier("bound.debug.custom-load." + capture.id.uuidString)
            }
            Button("Return to Previous Run") { Task { await session.returnToPreviousRun() } }
                .disabled(!enabled || session.isBusy || !session.canReturn).background(focusColor("return")).id("return").accessibilityIdentifier("bound.debug.return")
            Button("Export Test Report") { exportReport() }.background(focusColor("report")).id("report").accessibilityIdentifier("bound.debug.report")
            if let report { ShareLink("Share Test Report", item: report) }
            if reportError { Text("Report could not be saved.").font(.caption).foregroundStyle(.secondary) }
        }.font(.footnote)
    }
    private func info(_ title: String, _ text: String) -> some View {
        Section(title) { Text(text).font(.body) }
    }
    private func load(_ point: BoundDebugPoint) {
        guard canLoad, let settings = settings() else { return }
        Task { await session.load(source: .init(kind: .builtin, pointID: point.id, fixtureVersion: BoundDebugCatalog.fixtureVersion), settings: settings) }
    }
    private func navigate(_ command: BoundControllerNavigationCommand) {
        if detail != nil { if command == .back { detail = nil }; return }
        let ids = focusIDs
        let index = selected.flatMap { ids.firstIndex(of: $0) }
        let point = BoundDebugCatalog.points.first { $0.id == selected }
        switch command {
        case .focusUp, .previousItem, .scrollUp:
            selected = ids[index.map { max(0, $0 - 1) } ?? 0]
        case .focusDown, .nextItem, .scrollDown:
            selected = ids[index.map { min(ids.count - 1, $0 + 1) } ?? 0]
        case .focusLeft, .scrollLeft: focusesInfo = false
        case .focusRight, .scrollRight: focusesInfo = true
        case .details: detail = point
        case .select:
            if let point { if focusesInfo { detail = point } else { load(point) } }
            else { activate(selected ?? ids[0]) }
        case .back: BoundControllerNavigationEvent.postHideMultiview(gameID: gameID, content: .debug)
        case .clearFocus: selected = nil; focusesInfo = false
        }
    }
    private func focusColor(_ id: String) -> Color { selected == id ? Color.accentColor.opacity(0.18) : .clear }
    private func activate(_ id: String) {
        if id == "report" { exportReport(); return }
        guard enabled, !session.isBusy else { return }
        Task {
            switch id {
            case "create": await session.createSession()
            case "refresh": await session.listInvitations()
            case "retry": await session.reconcile(); await session.refreshCaptures()
            case "end": if session.isController { await session.revoke() } else { await session.leave() }
            case "reload": if canLoad { await session.reload() }
            case "custom": if canLoad && session.terminal == nil { await session.saveCustom() }
            case "return": if session.canReturn { await session.returnToPreviousRun() }
            default:
                if canLoad, let capture = session.captures.first(where: { "capture:" + $0.id.uuidString == id }) {
                    await session.reloadCustom(capture)
                } else if let invitation = session.invitations.first(where: { "join:" + $0.sessionID.uuidString == id }) {
                    await session.join(sessionID: invitation.sessionID, membershipEpoch: invitation.membershipEpoch)
                }
            }
        }
    }
    private func exportReport() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bound DEBUG Reports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
            try session.exportReport().write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            report = destination; reportError = false
        } catch { reportError = true }
    }
}

import SwiftUI
import UIKit

/// Mac-only workspace. Delta's native game fills the space beside the inspector.
struct BoundMacWorkspaceView: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var onboarding: FriendOnboarding
    @ObservedObject var state: BoundCompanionState
    var debug: BoundDebugSession? = nil
    var debugSettings: () -> Data? = { nil }
    var geometry: BoundMacWorkspaceGeometry
    var gameID: String
    var gameTitle: String
    let editingChanged: (Bool) -> Void
    let textEditingChanged: (Bool) -> Void
    let currentSave: (String) throws -> BoundRRDexSave
    let showLibrary: () -> Void
    let showMenu: () -> Void
    let showFriends: () -> Void
    let showSettings: () -> Void

    @State private var retainedSidebarSize = CGSize.zero
    @State private var widthDragStart: CGFloat?
    @State private var topDragStart: CGFloat?
    private let accent = Color(uiColor: .deltaPurple)
    private let shell = Color(red: 0.075, green: 0.082, blue: 0.105)
    private let panel = Color(red: 0.105, green: 0.115, blue: 0.145)
    private var referenceIsVisible: Bool { state.macSidebarVisible && state.macReferenceVisible }

    var body: some View {
        // Layout catches up one pass after a toggle; never squeeze retained
        // scroll views to zero during that transition.
        let size = state.macSidebarVisible && geometry.inspector.width > 0
            ? geometry.inspector.size : retainedSidebarSize
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: geometry.bounds.width, height: geometry.bounds.height)
                .allowsHitTesting(false)
            inspector(size: size)
                .frame(width: size.width, height: size.height)
                .position(x: geometry.bounds.maxX - size.width / 2, y: geometry.bounds.minY + size.height / 2)
                .opacity(state.macSidebarVisible ? 1 : 0)
                .allowsHitTesting(state.macSidebarVisible)
                .accessibilityHidden(!state.macSidebarVisible)
            if state.macSidebarVisible {
                sidebarResizeHandle.frame(width: geometry.resizeHandle.width, height: geometry.resizeHandle.height)
                    .position(x: geometry.resizeHandle.midX, y: geometry.resizeHandle.midY)
            }
            workspaceControls.frame(width: geometry.controls.width, height: geometry.controls.height)
                .position(x: geometry.controls.midX, y: geometry.controls.midY)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.mac-workspace")
        .accessibilityValue(state.macControllerFocused ? "Multiview Controls" : "Game Controls")
        .onChange(of: geometry.inspector.size, initial: true) { _, size in
            if size.width > 0 && size.height > 0 { retainedSidebarSize = size }
        }
        .onChange(of: state.macReference) { _, _ in endEditing() }
        .onChange(of: state.macSidebarVisible) { _, visible in
            if !visible { endEditing() }
        }
        .onChange(of: state.macReferenceVisible) { _, visible in
            if !visible { endEditing() }
        }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        textEditingChanged(false)
        editingChanged(false)
    }

    private var workspaceControls: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Library", systemImage: "square.grid.2x2", action: showLibrary)
                    .accessibilityIdentifier("bound.mac-library")
                Button("Game menu", systemImage: "gamecontroller", action: showMenu)
                    .accessibilityIdentifier("bound.mac-menu")
                Button("Friends", systemImage: "person.2", action: showFriends)
                    .accessibilityIdentifier("bound.mac-friends")
                Button("Settings", systemImage: "gearshape", action: showSettings)
                    .accessibilityIdentifier("bound.mac-settings")
                Divider()
                Toggle("Friend Gameplay", isOn: $state.macFriendVisible)
                    .accessibilityIdentifier("bound.mac-friend-visible")
                Toggle("Multiview", isOn: $state.macReferenceVisible)
                    .accessibilityIdentifier("bound.mac-multiview-visible")
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 36)
            }
            .accessibilityLabel("Workspace menu")
            .accessibilityIdentifier("bound.mac-actions")
            Button {
                state.macSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right").frame(width: 36, height: 36)
            }
            .accessibilityLabel(state.macSidebarVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityValue(state.macSidebarVisible ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("bound.mac-sidebar-toggle")
        }
        .font(.system(size: 16, weight: .medium))
        .buttonStyle(.plain).foregroundStyle(.white)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }

    private var sidebarResizeHandle: some View {
        Rectangle().fill(.clear)
            .overlay { Capsule().fill(.white.opacity(0.4)).frame(width: 4, height: 40) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if widthDragStart == nil { widthDragStart = geometry.inspector.width }
                    resizeSidebar(to: (widthDragStart ?? geometry.inspector.width) - value.translation.width)
                }
                .onEnded { _ in widthDragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityIdentifier("bound.mac-sidebar-resize")
            .accessibilityAdjustableAction { direction in
                resizeSidebar(to: geometry.inspector.width + (direction == .increment ? 40 : -40))
            }
            .help("Drag to resize sidebar")
    }

    private func resizeSidebar(to width: CGFloat) {
        state.macSidebarWidth = BoundMacWorkspaceGeometry(bounds: geometry.bounds,
            preferredSidebarWidth: width).inspector.width
    }

    private func inspector(size: CGSize) -> some View {
        let height = max(0, size.height - 16)
        let bottomHeight = min(320, height * 0.30)
        let remaining = max(0, height - bottomHeight - 20)
        let minimumTop = min(120, remaining * 0.35)
        let minimumMid = min(180, remaining * 0.45)
        let topHeight = state.macFriendVisible
            ? min(remaining - minimumMid, max(minimumTop, remaining * state.macTopFraction))
            : min(40, remaining)
        let visibleTop = state.macReferenceVisible ? topHeight : max(0, height - 44)
        return VStack(spacing: 0) {
            friendSection.frame(height: visibleTop)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.mac-top")
            if state.macReferenceVisible {
                topMidDivider(topHeight: topHeight, available: remaining).frame(height: 12)
            }
            // Keep both panes mounted when the sidebar or Multiview is hidden.
            VStack(spacing: 0) {
                midSection.frame(height: max(0, remaining - topHeight))
                Color.clear.frame(height: 8)
                bottomSection.frame(height: bottomHeight)
            }
            .frame(height: state.macReferenceVisible ? max(0, height - topHeight - 12) : 0, alignment: .top)
            .opacity(state.macReferenceVisible ? 1 : 0)
            .allowsHitTesting(referenceIsVisible)
            .accessibilityElement(children: referenceIsVisible ? .contain : .ignore)
            .accessibilityHidden(!referenceIsVisible)
            .clipped()
            if !state.macReferenceVisible {
                Button("Show Multiview") { state.macReferenceVisible = true }
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .accessibilityIdentifier("bound.mac-show-multiview")
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(shell)
        .environment(\.colorScheme, .dark)
    }

    private func topMidDivider(topHeight: CGFloat, available: CGFloat) -> some View {
        Rectangle().fill(.clear)
            .overlay { Capsule().fill(.white.opacity(0.4)).frame(width: 42, height: 4) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if topDragStart == nil { topDragStart = topHeight }
                    state.macTopFraction = min(0.95, max(0.05,
                        ((topDragStart ?? topHeight) + value.translation.height) / max(1, available)))
                }
                .onEnded { _ in topDragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Friend and reference divider")
            .accessibilityIdentifier("bound.mac-top-mid-resize")
            .accessibilityAdjustableAction { direction in
                state.macTopFraction = min(0.95, max(0.05, state.macTopFraction + (direction == .increment ? 0.08 : -0.08)))
            }
            .help("Drag to resize Friend and references")
    }

    private var friendSection: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                BoundRemoteCanvas(view: sharing.remoteView)
                    .opacity(state.macFriendVisible && (sharing.remoteVisible || state.displaysFixtureVideo) ? 1 : 0)
                if !state.macFriendVisible {
                    Button("Show Friend Gameplay") { state.macFriendVisible = true }
                        .accessibilityIdentifier("bound.mac-show-friend")
                } else if !sharing.remoteVisible && !state.displaysFixtureVideo {
                    Text(sharing.active ? "Waiting for friend" : sharing.connectionRequested ? "Retrying connection…" : "Connect a friend")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityElement(children: state.macFriendVisible ? .ignore : .contain)
            .accessibilityLabel("Friend gameplay")
            .accessibilityValue(sharing.status)
            .accessibilityIdentifier("bound.friend-screen")
            if state.macFriendVisible {
                Button(action: toggleFriendConnection) {
                    Text(sharing.connectionRequested ? "Disconnect" : "Connect")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityIdentifier("bound.mac-friends-connect")
            }
        }
    }

    func toggleFriendConnection() {
        if sharing.connectionRequested { onboarding.disconnect() }
        else { showFriends() }
    }

    private var midSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                referenceButton(.dex, icon: "magnifyingglass", label: "Dex", id: "bound.mac-dex")
                referenceButton(.bosses, icon: "person.crop.rectangle", label: "Docs", id: "bound.mac-bosses")
            }.padding(3).background(panel)
            ZStack {
                BoundRetainedReferenceView(isActive: referenceIsVisible && state.macMidReference == .dex,
                                           floating: false, portraitTopInset: 0) { floating, topInset in
                    BoundRRDexView(gameID: gameID, floating: floating, portraitTopInset: topInset,
                        isActive: referenceIsVisible && state.macMidReference == .dex,
                        presentationChanged: { presented in
                            if state.macMidReference == .dex { editingChanged(presented) }
                        }, textEditingChanged: { editing in
                            if state.macMidReference == .dex { textEditingChanged(editing) }
                        },
                        currentSave: { try currentSave(gameID) })
                }
                BoundRetainedReferenceView(isActive: referenceIsVisible && state.macMidReference == .bosses,
                                           floating: false, portraitTopInset: 0) { floating, topInset in
                    BoundBossGuideView(gameID: gameID, floating: floating, portraitTopInset: topInset,
                        isActive: referenceIsVisible && state.macMidReference == .bosses,
                        presentationChanged: { presented in
                            if state.macMidReference == .bosses { editingChanged(presented) }
                        })
                }
            }.id(gameID)
        }
        .background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier("bound.mac-mid")
    }

    private var bottomSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                referenceButton(.notes, icon: "note.text", label: "Notes", id: "bound.mac-notes")
                referenceButton(.types, icon: "circle.hexagongrid", label: "Types", id: "bound.mac-types")
                referenceButton(.connections, icon: "network", label: "Log", id: "bound.mac-connections")
                if state.configuration.debugAvailable {
                    referenceButton(.debug, icon: "ladybug", label: "DEBUG", id: "bound.mac-debug")
                }
            }.padding(3).background(panel)
            ZStack {
                BoundNotesEditor(gameID: gameID, floating: false, editingChanged: { editing in
                    textEditingChanged(editing); editingChanged(editing)
                })
                .opacity(state.macBottomReference == .notes ? 1 : 0)
                .allowsHitTesting(referenceIsVisible && state.macBottomReference == .notes)
                .accessibilityHidden(!referenceIsVisible || state.macBottomReference != .notes)
                BoundTypeChartView(topInset: 0, constrainsPan: true, fitsViewport: true)
                    .opacity(state.macBottomReference == .types ? 1 : 0)
                    .allowsHitTesting(referenceIsVisible && state.macBottomReference == .types)
                    .accessibilityHidden(!referenceIsVisible || state.macBottomReference != .types)
                BoundConnectionsView(feed: sharing.connectionFeed, gameID: gameID,
                                     isActive: referenceIsVisible && state.macBottomReference == .connections)
                    .opacity(state.macBottomReference == .connections ? 1 : 0)
                    .allowsHitTesting(referenceIsVisible && state.macBottomReference == .connections)
                    .accessibilityHidden(!referenceIsVisible || state.macBottomReference != .connections)
                if state.configuration.debugAvailable, let debug {
                    BoundDebugView(session: debug, gameID: gameID,
                                   isActive: referenceIsVisible && state.macBottomReference == .debug, settings: debugSettings)
                        .opacity(state.macBottomReference == .debug ? 1 : 0)
                        .allowsHitTesting(referenceIsVisible && state.macBottomReference == .debug)
                        .accessibilityHidden(!referenceIsVisible || state.macBottomReference != .debug)
                }
            }.id(gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier("bound.mac-bottom")
    }

    private func referenceButton(_ content: BoundPiPContent, icon: String, label: String, id: String) -> some View {
        let selected = content == state.macMidReference || content == state.macBottomReference
        return Button {
            state.macReference = content
            state.macReferenceVisible = true
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundStyle(selected ? accent : .white.opacity(0.6))
                .background(selected ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
        .accessibilityLabel(content == .connections ? "Connections" : label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

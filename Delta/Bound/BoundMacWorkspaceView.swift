import SwiftUI
import UIKit

/// Desktop workspace chrome around Delta's live game viewport and the existing
/// companion reference views. The gameplay rectangle stays transparent so the
/// emulator view beneath this overlay remains visible and interactive.
struct BoundMacWorkspaceView: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var state: BoundCompanionState
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

    private var compactToolbar: Bool { geometry.toolbar.width < 550 }

    private let accent = Color(uiColor: .deltaPurple)
    private let shell = Color(red: 0.075, green: 0.082, blue: 0.105)
    private let panel = Color(red: 0.105, green: 0.115, blue: 0.145)
    private let raised = Color(red: 0.145, green: 0.155, blue: 0.19)
    private let hairline = Color.white.opacity(0.09)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The actual game is rendered by Delta behind the workspace.
            Color.clear.frame(geometry.gameplay).allowsHitTesting(false)

            if geometry.sidebar.width > 0 {
                sidebar.frame(geometry.sidebar)
            }
            toolbar.frame(geometry.toolbar)
            footer.frame(geometry.footer)
            inspector.frame(geometry.inspector)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.mac-workspace")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(accent.gradient)
                    Image(systemName: "gamecontroller.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                }.frame(width: 34, height: 34)
                if geometry.sidebar.width > 100 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BOUND").font(.system(size: 13, weight: .black, design: .rounded)).tracking(1.2)
                        Text("GAME LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.white.opacity(0.48))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if geometry.sidebar.width > 100 {
                    Text("LIBRARY").font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(.white.opacity(0.42))
                }
                sideButton("Library", icon: "square.grid.2x2.fill", action: showLibrary, id: "bound.mac-library-nav")
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 3, height: 29)
                    Image(systemName: "gamecontroller").font(.system(size: 14)).frame(width: 18)
                    if geometry.sidebar.width > 100 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gameTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text("NOW PLAYING").font(.system(size: 8, weight: .bold)).tracking(0.8).foregroundStyle(accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 42)
                .background(raised, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now playing, \(gameTitle)")
            }

            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 5) {
                sideButton("Friends", icon: "person.2.fill", action: showFriends, id: "bound.mac-friends-nav")
                sideButton("Settings", icon: "gearshape.fill", action: showSettings, id: "bound.mac-settings-nav")
                sideButton("Menu", icon: "line.3.horizontal", action: showMenu, id: "bound.mac-menu-nav")
            }
        }
        .padding(.horizontal, geometry.sidebar.width > 100 ? 14 : 11)
        .padding(.top, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shell)
        .foregroundStyle(Color.white.opacity(0.92))
        .overlay(alignment: .trailing) { Rectangle().fill(hairline).frame(width: 1) }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: showLibrary) {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 0.34, green: 0.82, blue: 0.58)).frame(width: 7, height: 7)
                    Text(gameTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: compactToolbar ? 108 : nil, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.44))
                }
                .padding(.horizontal, 11).frame(height: 30)
                .background(raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).accessibilityLabel("Library, current game \(gameTitle)")
            .accessibilityIdentifier("bound.mac-library")
            .help("Open game library")

            Spacer(minLength: 10)
            Button(action: showMenu) {
                toolbarButtonLabel("Game menu", icon: "ellipsis.circle")
            }.buttonStyle(.plain).accessibilityIdentifier("bound.mac-menu").help("Game menu")

            Button(action: showFriends) {
                toolbarButtonLabel(sharing.remoteVisible ? "Friend live" : "Friends", icon: "person.2.fill")
                    .background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.plain).accessibilityIdentifier("bound.mac-friends")
            .help("Open friends")
            Button(action: showSettings) {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30).background(raised, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("bound.mac-settings")
                .help("Settings")
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shell.opacity(0.98))
        .foregroundStyle(Color.white.opacity(0.92))
        .overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(sharing.remoteVisible ? Color.green : Color.white.opacity(0.3)).frame(width: 6, height: 6)
            Text(sharing.status).lineLimit(1)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text("BOUND").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.34))
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shell)
        .foregroundStyle(Color.white.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
    }

    private var inspector: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let feedWidth = min(270, max(1, width - 54))
            let feedHeight = feedWidth / 1.5
            let availableReferenceHeight = proxy.size.height - feedHeight - 208
            let needsOuterScroll = availableReferenceHeight < 300
            Group {
                if needsOuterScroll {
                    ScrollView(.vertical) {
                        inspectorContents(feedWidth: feedWidth, feedHeight: feedHeight,
                                          referenceHeight: max(300, availableReferenceHeight))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        friendCard(width: feedWidth, feedHeight: feedHeight)
                        referencePicker
                        referenceContent.frame(height: availableReferenceHeight, alignment: .top)
                    }
                    .padding(16)
                }
            }
            .scrollIndicators(.automatic)
            .background(shell)
        }
        .overlay(alignment: .leading) { Rectangle().fill(hairline).frame(width: 1) }
        .environment(\.colorScheme, .dark)
    }

    private func inspectorContents(feedWidth: CGFloat, feedHeight: CGFloat, referenceHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            friendCard(width: feedWidth, feedHeight: feedHeight)
            referencePicker
            referenceContent.frame(height: referenceHeight, alignment: .top)
        }
        .padding(16)
    }

    private func friendCard(width: CGFloat, feedHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(accent)
                Text("FRIEND GAMEPLAY").font(.system(size: 9, weight: .bold)).tracking(1.1)
                Spacer()
                Text(sharing.remoteVisible ? "LIVE" : sharing.joined ? "WAITING" : sharing.active ? "CONNECTING" : "OFF")
                    .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7)
                    .foregroundStyle(sharing.remoteVisible ? Color.green : Color.white.opacity(0.48))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                BoundRemoteCanvas(view: sharing.remoteView)
                    .frame(width: width, height: feedHeight)
                    .opacity(sharing.remoteVisible || state.displaysFixtureVideo ? 1 : 0)
                if !sharing.remoteVisible && !state.displaysFixtureVideo {
                    VStack(spacing: 7) {
                        Image(systemName: sharing.active ? "hourglass" : "person.crop.rectangle.stack")
                            .font(.system(size: 18)).foregroundStyle(.white.opacity(0.48))
                        Text(sharing.active ? "Waiting for friend" : "Connect a friend")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.66))
                    }.allowsHitTesting(false)
                }
            }
            .frame(width: width, height: feedHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Friend gameplay")
            .accessibilityValue(sharing.status)
            .accessibilityIdentifier("bound.friend-screen")
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Button(action: showFriends) {
                    Label(sharing.active ? "Friends" : "Connect", systemImage: "person.2.fill")
                        .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                        .background(accent, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityIdentifier("bound.mac-friends-connect").help("Connect with a friend")
                if sharing.active {
                    Button { sharing.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                            .background(raised, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(11).background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline, lineWidth: 1))
    }

    private var referencePicker: some View {
        HStack(spacing: 3) {
            referenceButton(.dex, icon: "magnifyingglass", label: "RR Dex", id: "bound.mac-dex")
            referenceButton(.bosses, icon: "person.crop.rectangle.stack", label: "Boss", id: "bound.mac-bosses")
            referenceButton(.notes, icon: "note.text", label: "Notes", id: "bound.mac-notes")
            referenceButton(.types, icon: "circle.hexagongrid.fill", label: "Types", id: "bound.mac-types")
        }
        .padding(4).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func referenceButton(_ content: BoundPiPContent, icon: String, label: String, id: String) -> some View {
        Button { state.macReference = content } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(state.macReference == content ? accent : Color.white.opacity(0.58))
            .frame(maxWidth: .infinity).frame(height: 39)
            .background(state.macReference == content ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
        .help(label)
        .accessibilityAddTraits(state.macReference == content ? .isSelected : [])
    }

    @ViewBuilder
    private var referenceContent: some View {
        Group {
            switch state.macReference {
            case .dex:
                BoundRRDexView(gameID: gameID, floating: false, portraitTopInset: 0,
                               presentationChanged: editingChanged, textEditingChanged: textEditingChanged,
                               currentSave: { try currentSave(gameID) })
            case .bosses:
                BoundBossGuideView(gameID: gameID, floating: false, portraitTopInset: 0,
                                   presentationChanged: editingChanged)
            case .notes:
                BoundNotesEditor(gameID: gameID, floating: false, editingChanged: { editing in
                    textEditingChanged(editing)
                    editingChanged(editing)
                })
            case .types:
                BoundTypeChartView(topInset: 0, constrainsPan: true)
            case .friend:
                EmptyView()
            }
        }
        .id(gameID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline, lineWidth: 1))
    }

    private func sideButton(_ title: String, icon: String, action: @escaping () -> Void,
                            id: String? = nil) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                if geometry.sidebar.width > 100 {
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(.horizontal, 9).frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id ?? "bound.mac-\(title.lowercased())")
        .help(title)
    }

    @ViewBuilder
    private func toolbarButtonLabel(_ title: String, icon: String) -> some View {
        if compactToolbar {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30).background(raised, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 30)
                .background(raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private extension View {
    func frame(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

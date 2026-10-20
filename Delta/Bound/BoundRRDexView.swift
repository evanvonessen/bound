import SwiftUI
import UIKit

struct BoundRRDexView: View {
    let gameID: String
    var floating = false
    var inlineSearch = false
    var portraitTopInset: CGFloat = 0
    var previewLayout: BoundReferenceLayout? = nil
    var isActive = true
    let presentationChanged: (Bool) -> Void
    var textEditingChanged: (Bool) -> Void = { _ in }
    var currentSave: () throws -> BoundRRDexSave = { throw BoundRRDexSave.ImportError.currentGameUnavailable }
    @StateObject private var catalogStore = BoundReferenceCatalogStore.shared
    private let preferences = BoundRRDexPreferences()
    @AppStorage(BoundReferenceLayoutPreferences.dexKey) private var savedLayout = BoundReferenceLayout.layout12
    @AppStorage(BoundUIVersionPreferences.key) private var uiVersion = BoundUIVersion.option2
    @State private var choice = BoundRRDexPreferences.Choice()
    @State private var query = ""
    // UIKit owns focus; a SwiftUI FocusState without a .focused view resets it.
    @State private var searching = false
    @State private var moveQuery = ""
    @State private var moveSearchVisible = false
    @State private var moveSearchFocused = false
    @State private var expandedLearnsetMethod: String?
    @State private var layout12LearnsetPresented = false
    @State private var layout12ReturningToLearnset = false
    @State private var importError: String?
    @State private var automaticSaveStatus: String?
    @State private var refreshingSave = false
    @State private var sheet: Detail?
    @State private var controllerSpeciesQuery = ""
    @State private var controllerSpeciesIndex = 0
    @State private var controllerDexFocus: ControllerDexFocus?
    @State private var awaitingDetailDismissal = false
    @State private var layout4EvolutionExpanded = false
    @State private var layout5EvolutionExpanded = false
    private enum Detail: Identifiable {
        case weaknesses, learnset, evolution, controllerSpeciesPicker
        case ability(String, String)
        var id: String {
            switch self {
            case .weaknesses: "weaknesses"
            case .learnset: "learnset"
            case .evolution: "evolution"
            case .controllerSpeciesPicker: "controller-species-picker"
            case let .ability(name, _): "ability-\(name)"
            }
        }
    }
    private enum ControllerDexFocus: Equatable {
        case speciesSearch
        case learnsetSearch
        case learnsetSearchInput
        case learnsetMethod(Int)
    }
    private var controllerMultiviewNavigationEnabled: Bool {
        BoundControllerMultiviewPreferences().isEnabled
    }
    private var editingText: Bool { searching || moveSearchFocused }
    private var interacting: Bool { editingText || sheet != nil || importError != nil }
    private var isControllerSpeciesPickerPresented: Bool {
        if case .controllerSpeciesPicker? = sheet { return true }
        return false
    }
    private var hasPresentedSheet: Bool {
        if case .some(_) = sheet { return true }
        return false
    }
    private var hasIslandActions: Bool { !floating && portraitTopInset >= 51 }
    private var hasInlineSearch: Bool { floating && inlineSearch && layout.rawValue >= 7 }
    private var contentTopInset: CGFloat {
        // Use the spare clearance below the Island without moving its actions.
        hasIslandActions && layout.rawValue >= 8 ? max(51, portraitTopInset - 6) : portraitTopInset
    }
    private var portraitReferenceBottomInset: CGFloat? {
        guard !floating, portraitTopInset > 0 else { return nil }
        // Match Boss's lower band without changing the panel or gameplay frame.
        return 6
    }
    private var layout: BoundReferenceLayout { previewLayout ?? savedLayout }
    private var usesUIVersion2: Bool { uiVersion == .option2 }
    private var statLabels: [String] {
        usesUIVersion2 ? ["HP", "Atk", "Def", "SpAtk", "SpDef", "Speed"] : ["HP", "Atk", "Def", "SpA", "SpD", "Spe"]
    }

    var body: some View {
        BoundControllerInputHost {
        Group {
            if let catalog = catalogStore.dex,
               let pokemon = catalog.pokemon(id: choice.speciesID) ?? catalog.species.first {
                GeometryReader { geometry in
                    if layout == .layout12 && layout12LearnsetPresented {
                        layout12Learnset(pokemon: pokemon, catalog: catalog, compact: geometry.size.height < 140)
                    } else if floating {
                        floatingCard(pokemon: pokemon, catalog: catalog, size: geometry.size)
                    } else if geometry.size.height < 140 {
                        // Keep fixed controls reachable when the portrait strip
                        // is too short to hold them beside a scrolling list.
                        ScrollView {
                            compactCard(pokemon: pokemon, catalog: catalog)
                                .frame(width: geometry.size.width)
                        }
                        .id((layout == .layout4 || layout == .layout5 || layout == .layout6 || layout == .layout7 || layout == .layout8 || layout == .layout9 || layout == .layout10 || layout == .layout11 || layout == .layout12) && (searching || !query.isEmpty))
                        .scrollDismissesKeyboard(.interactively)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        selectedCard(pokemon: pokemon, catalog: catalog, size: geometry.size)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .boundControllerScroll(gameID: gameID, content: .dex, active: isActive && !hasPresentedSheet)
                .padding(.top, contentTopInset)
                .overlay(alignment: .top) {
                    if hasIslandActions {
                        if layout == .layout12 && layout12LearnsetPresented {
                            HStack(spacing: 0) {
                                layout12LearnsetBack(pokemon: pokemon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(width: 160, height: 1)
                                layout12MoveSearchButton.frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: portraitTopInset)
                        } else if layout == .layout8 || layout == .layout9 || layout == .layout10 || layout == .layout11 || layout == .layout12 {
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Color.clear.frame(width: 44, height: 44)
                                Color.clear.frame(width: 160, height: 1)
                                layout8SearchButton
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: portraitTopInset)
                        } else {
                            HStack(spacing: 0) {
                                if layout == .layout7 {
                                    Color.clear.frame(width: 44, height: 44).frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses, besideIsland: true)
                                }
                                // Reserve the center for the Dynamic Island and its clearance.
                                Spacer().frame(width: 160)
                                if layout == .layout7 {
                                    layout7SearchButton.frame(maxWidth: .infinity, alignment: .trailing)
                                } else {
                                    detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset, besideIsland: true)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: portraitTopInset)
                        }
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("bound.rrdex")
                .accessibilityValue(layout.title)
                .onReceive(NotificationCenter.default.publisher(for: BoundControllerNavigationEvent.notificationName)) { notification in
                    guard isActive, previewLayout == nil,
                          let command = BoundControllerNavigationEvent.command(from: notification, gameID: gameID, content: .dex) else { return }
                    handleControllerNavigation(command, catalog: catalog)
                }
                .onAppear {
                    if previewLayout == nil { choice = preferences.read(gameID: gameID) }
                    controllerDexFocus = nil
                    expandedLearnsetMethod = nil
                    layout12LearnsetPresented = false
                    if layout == .layout12 {
                        moveQuery = ""; moveSearchVisible = false; moveSearchFocused = false
                        layout12ReturningToLearnset = false
                    }
                    if previewLayout == nil { refreshAutomaticSave() }
                }
                .onReceive(NotificationCenter.default.publisher(for: BoundRRDexSaveRefreshEvent.notificationName)
                    .receive(on: DispatchQueue.main)) { notification in
                    guard isActive, previewLayout == nil,
                          notification.userInfo?[BoundRRDexSaveRefreshEvent.gameIDKey] as? String == gameID else { return }
                    refreshAutomaticSave()
                }
                .sheet(item: $sheet, onDismiss: detailDismissed) { detail in
                    BoundControllerInputHost {
                    BoundRRDexDetail(title: detailTitle(detail)) {
                        switch detail {
                        case .weaknesses: BoundRRDexMatchups(pokemon: pokemon, catalog: catalog)
                        case .learnset: BoundRRDexLearnset(pokemon: pokemon, catalog: catalog, save: choice.save)
                        case .evolution: evolutionDetail(pokemon: pokemon, catalog: catalog)
                        case .controllerSpeciesPicker: controllerSpeciesPicker(catalog: catalog)
                        case let .ability(name, description):
                            ScrollView { Text(description).frame(maxWidth: .infinity, alignment: .leading).padding() }
                                .accessibilityIdentifier("bound.rrdex-ability-description")
                        }
                    }
                    .boundControllerScroll(gameID: gameID, content: .dex,
                                           active: isActive && !isControllerSpeciesPickerPresented)
                    }
                }
            } else if catalogStore.hasFinishedLoading {
                ContentUnavailableView("RRDex unavailable", systemImage: "book.closed", description: Text("The bundled dex could not be loaded."))
            } else {
                ProgressView("Loading RR Dex…")
            }
        }
        .tint(Color(uiColor: .deltaPurple))
        .task { await catalogStore.loadIfNeeded() }
        .alert("Save could not be imported", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .onChange(of: editingText) { _, active in
            if isActive { textEditingChanged(active) }
        }
        .onChange(of: interacting) { _, active in
            if isActive, active || !awaitingDetailDismissal { presentationChanged(active) }
        }
        .onChange(of: isActive) { wasActive, active in
            guard wasActive != active else { return }
            if active {
                if previewLayout == nil { refreshAutomaticSave() }
            } else {
                controllerDexFocus = nil
                searching = false
                moveSearchFocused = false
                sheet = nil
                importError = nil
                awaitingDetailDismissal = false
                textEditingChanged(false)
                presentationChanged(false)
            }
        }
        .onChange(of: query) { _, _ in controllerSpeciesIndex = 0 }
        .onChange(of: layout) { previous, current in
            expandedLearnsetMethod = nil
            if previous == .layout12 || current == .layout12 { closeLayout12Learnset() }
        }
        .onDisappear {
            searching = false; moveSearchFocused = false; sheet = nil; controllerDexFocus = nil
            if isActive {
                textEditingChanged(false)
                if !awaitingDetailDismissal { presentationChanged(false) }
            }
        }
        .allowsHitTesting(isActive && previewLayout == nil)
        .accessibilityHidden(!isActive)
        }
    }

    private func detailTitle(_ detail: Detail) -> String {
        switch detail {
        case .weaknesses: "Type matchups"
        case .learnset: "Learnset"
        case .evolution: "Evolution and methods"
        case .controllerSpeciesPicker: "Choose Pokémon"
        case let .ability(name, _): name
        }
    }

    private var referenceFooter: some View {
        VStack(spacing: 2) {
            Text("Radical Red Version 4.1")
                .accessibilityIdentifier("bound.rrdex-reference-rom")
            Text("Normal Difficulty")
                .accessibilityIdentifier("bound.rrdex-reference-difficulty")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-reference-footer")
    }

    @ViewBuilder
    private func floatingCard(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, size: CGSize) -> some View {
        let scale = min(size.width / 360, size.height / 300)
        // Keep the existing text/sprite scale while giving the card the full
        // resized viewport. A fixed 300-point height leaves unused space when
        // landscape arrangement makes the panel taller without widening it.
        let contentSize = CGSize(width: size.width / max(scale, 0.001),
                                 height: size.height / max(scale, 0.001))
        selectedCard(pokemon: pokemon, catalog: catalog, size: contentSize)
            .frame(width: contentSize.width, height: contentSize.height).scaleEffect(scale)
            .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func compactCard(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        switch layout {
        case .layout1: card(pokemon: pokemon, catalog: catalog, compact: true)
        case .layout2: cardLayout2(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
        case .layout3: cardLayout3(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
        case .layout4: cardLayout4(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
        case .layout5: cardLayout5(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
        case .layout6: cardLayout6(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
        case .layout7: cardLayout7(pokemon: pokemon, catalog: catalog, compact: true)
        case .layout8, .layout9, .layout10, .layout11, .layout12: cardLayout8(pokemon: pokemon, catalog: catalog, compact: true)
        }
    }

    @ViewBuilder
    private func selectedCard(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, size: CGSize) -> some View {
        switch layout {
        case .layout1:
            card(pokemon: pokemon, catalog: catalog)
        case .layout2:
            cardLayout2(pokemon: pokemon, catalog: catalog, compact: size.height < 140,
                        denseSizing: size.height < 250)
        case .layout3:
            cardLayout3(pokemon: pokemon, catalog: catalog, compact: size.height < 140,
                        denseSizing: size.height < 250)
        case .layout4:
            cardLayout4(pokemon: pokemon, catalog: catalog, compact: size.height < 140,
                        denseSizing: size.height < 250)
        case .layout5:
            cardLayout5(pokemon: pokemon, catalog: catalog, compact: size.height < 140,
                        denseSizing: size.height < 250)
        case .layout6:
            cardLayout6(pokemon: pokemon, catalog: catalog, compact: size.height < 140,
                        denseSizing: size.height < 250)
        case .layout7:
            cardLayout7(pokemon: pokemon, catalog: catalog)
        case .layout8, .layout9, .layout10, .layout11, .layout12:
            cardLayout8(pokemon: pokemon, catalog: catalog)
        }
    }

    private func showDetail(_ detail: Detail) {
        awaitingDetailDismissal = true
        searching = false; moveSearchFocused = false; sheet = detail
    }

    private func detailDismissed() {
        // Keep the pause until UIKit clears the sheet, including a search-to-detail handoff.
        awaitingDetailDismissal = false
        if isActive, !interacting { presentationChanged(false) }
    }

    private func card(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("RR 4.1 · NORMAL").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    importCurrentGameSave()
                } label: { Label(choice.save == nil ? "Import save" : "Save loaded", systemImage: choice.save == nil ? "square.and.arrow.down" : "checkmark.circle") }
                    .font(.system(size: 11, weight: .medium)).accessibilityIdentifier("bound.rrdex-import")
                    .accessibilityHint("Imports or refreshes the current game's save automatically")
                Image(systemName: "info.circle").hidden().accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                BoundRRDexSearchField(text: $query, focused: Binding(get: { searching }, set: { searching = $0 })) {
                    if let first = catalog.suggestions(query).first { select(first) } else { searching = false }
                }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search").accessibilityIdentifier("bound.rrdex-clear-search")
                } else if searching {
                    Button("Done") { searching = false }.font(.system(size: 11))
                }
            }
            .font(.system(size: 14)).padding(.horizontal, 9).frame(height: 32)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if compact {
                    suggestionRows(catalog: catalog)
                } else {
                    suggestions(catalog: catalog).frame(maxHeight: .infinity)
                }
            } else {
                if compact {
                    details(pokemon: pokemon, catalog: catalog)
                } else {
                    ScrollView {
                        details(pokemon: pokemon, catalog: catalog)
                    }
                    .accessibilityIdentifier("bound.rrdex-details")
                    .scrollDismissesKeyboard(.interactively)
                }
                if !hasIslandActions {
                    HStack(spacing: 8) {
                        detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses)
                        detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset)
                    }
                }
            }
        }
        .padding(compact ? 10 : 12)
        .background(Color(uiColor: .systemBackground))
    }

    private var layout7SearchButton: some View {
        Button {
            if searching || !query.isEmpty { query = ""; searching = false }
            else { searching = true }
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(searching ? "Close Pokémon search" : "Search Pokémon")
        .accessibilityIdentifier("bound.rrdex-search-open")
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(controllerFocusColor(for: .speciesSearch), lineWidth: 2).padding(2))
        .accessibilityValue(controllerDexFocus == .speciesSearch ? "Controller highlighted" : "")
    }

    private var layout8SearchButton: some View {
        Button {
            moveSearchFocused = false
            if searching || !query.isEmpty { query = ""; searching = false }
            else { searching = true }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(searching ? "Close Pokémon search" : "Search Pokémon")
        .accessibilityIdentifier("bound.rrdex-search-open")
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(controllerFocusColor(for: .speciesSearch), lineWidth: 2).padding(2))
        .accessibilityValue(controllerDexFocus == .speciesSearch ? "Controller highlighted" : "")
    }

    /// Layout 1's reference card, with its persistent search row replaced by an
    /// Island shortcut and complete ability descriptions in the scrolling body.
    private func cardLayout7(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !hasIslandActions && !hasInlineSearch {
                HStack {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                    layout7SearchButton
                }
            }
            if searching || !query.isEmpty {
                searchRow(catalog: catalog, comfortableTargets: hasInlineSearch)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Search Pokémon by name.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
                } else if compact {
                    suggestionRows(catalog: catalog)
                } else {
                    suggestions(catalog: catalog).frame(maxHeight: .infinity)
                }
            } else if compact {
                details(pokemon: pokemon, catalog: catalog, expandedReference: true)
            } else {
                ScrollView {
                    details(pokemon: pokemon, catalog: catalog, expandedReference: true)
                }
                .accessibilityIdentifier("bound.rrdex-details")
            }
        }
        .padding(compact ? 10 : 12)
        .background(Color(uiColor: .systemBackground))
    }

    /// Layout 8 keeps Layout 7's detail-rich card while bringing the Island
    /// controls inward and pairing the evolution chain with prominent actions.
    private func cardLayout8(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !hasIslandActions && !hasInlineSearch {
                HStack {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                    layout8SearchButton
                }
            }
            if searching || !query.isEmpty {
                searchRow(catalog: catalog, comfortableTargets: hasInlineSearch)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if layout == .layout12 {
                        if !compact { Spacer(minLength: 0) }
                    } else {
                        Text("Search Pokémon by name.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
                    }
                } else if compact {
                    suggestionRows(catalog: catalog)
                } else {
                    suggestions(catalog: catalog).frame(maxHeight: .infinity)
                }
            } else if compact {
                details(pokemon: pokemon, catalog: catalog, expandedReference: true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        details(pokemon: pokemon, catalog: catalog, expandedReference: true)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-details")
                    .onAppear {
                        if layout == .layout12 && layout12ReturningToLearnset {
                            proxy.scrollTo("learnset", anchor: .bottom)
                            layout12ReturningToLearnset = false
                        }
                    }
                    .onChange(of: moveSearchVisible) { _, visible in
                        if visible { proxy.scrollTo("learnset", anchor: .top) }
                    }
                    .onChange(of: expandedLearnsetMethod) { _, method in
                        if let method { proxy.scrollTo("learnset-method-\(method)", anchor: .top) }
                    }
                    .onChange(of: controllerDexFocus) { _, focus in
                        switch focus {
                        case .some(.speciesSearch):
                            proxy.scrollTo("bound.rrdex-pokemon", anchor: .top)
                        case .some(.learnsetSearch), .some(.learnsetMethod(_)):
                            proxy.scrollTo("learnset", anchor: .top)
                        case .some(.learnsetSearchInput), nil:
                            break
                        }
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.top, hasIslandActions ? 4 : compact ? 10 : 12)
        .padding(.bottom, portraitReferenceBottomInset ?? (compact ? 10 : 12))
        .background(Color(uiColor: .systemBackground))
    }

    private func layout7AbilityDescriptions(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                            layoutNumber: Int = 7) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(catalog.abilityDetails(for: pokemon, save: choice.save).enumerated()), id: \.offset) { index, ability in
                (Text(ability.name + (ability.isHidden ? " (Hidden)" : "") + " — ").fontWeight(.semibold)
                 + Text(ability.description))
                    .font(.system(size: 11))
                    .foregroundStyle(ability.isHidden ? Color(red: 1, green: 0.35, blue: 0.7) : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(layoutNumber >= 8
                        ? "bound.rrdex-layout\(layoutNumber)-ability-description-\(index)"
                        : "bound.rrdex-ability-description-\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(layoutNumber >= 8 ? "bound.rrdex-layout\(layoutNumber)-abilities" : "bound.rrdex-abilities")
    }

    private func layout7Evolution(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        HStack(alignment: .top, spacing: 10) {
            evolutionLine(pokemon: pokemon, catalog: catalog)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 5) {
                detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset, dense: true)
                detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses, dense: true)
            }
            .frame(width: 94)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bound.rrdex-evolution-actions")
        }
    }

    private func layout8Evolution(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        let bst = pokemon.stats.reduce(0, +)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("EVOLUTION").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                let links = catalog.evolutionLine(for: pokemon)
                if links.isEmpty {
                    Text("No evolutions").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Button(link.from.name) { select(link.from) }
                                .accessibilityLabel("\(link.from.name) Pokémon")
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            Button(link.to.name) { select(link.to) }
                                .accessibilityLabel("\(link.to.name) Pokémon")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        Text(link.method).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-evolution-pokemon-\(link.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                Text("BST \(bst)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-bst")
                if layout == .layout8 {
                    detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset,
                                 comfortableTargets: true, identifier: "bound.rrdex-layout8-learnset")
                }
                if layout != .layout10 && layout != .layout11 && layout != .layout12 {
                    detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses,
                                 comfortableTargets: true, identifier: "bound.rrdex-layout\(layout.rawValue)-weaknesses")
                }
            }
            .frame(width: (layout == .layout10 || layout == .layout11 || layout == .layout12) ? nil : 126, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-actions")
        }
        .buttonStyle(.plain).foregroundStyle(.primary).tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-evolution")
    }

    private func statColor(_ value: Int) -> Color {
        let hex = UInt32(BoundRRDexCatalog.statColorHex(for: value).dropFirst(), radix: 16) ?? 0x777777
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }

    @ViewBuilder
    private func inlineLearnset(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        if layout == .layout12 {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Learnset").font(.system(size: 12, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    layout12MoveSearchButton
                }
                layout12LearnsetMethods(pokemon: pokemon, catalog: catalog)
            }
            .id("learnset")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bound.rrdex-layout12-learnset")
        } else {
            legacyInlineLearnset(pokemon: pokemon, catalog: catalog)
        }
    }

    private func legacyInlineLearnset(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text("Learnset").font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Button {
                    moveSearchVisible.toggle()
                    moveSearchFocused = moveSearchVisible
                    if !moveSearchVisible { moveQuery = "" }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .accessibilityLabel(moveSearchVisible ? "Close move search" : "Search moves")
                .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-search-toggle")
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(controllerFocusColor(for: .learnsetSearch), lineWidth: 2).padding(2))
                .accessibilityValue(controllerDexFocus == .learnsetSearch ? "Controller highlighted" : "")
                Spacer(minLength: 0)
            }
            .id("learnset")
            if moveSearchVisible {
                HStack(spacing: 6) {
                    BoundRRDexSearchField(text: $moveQuery, focused: $moveSearchFocused,
                                         placeholder: "Find a move", identifier: "bound.rrdex-layout\(layout.rawValue)-learnset-search") {
                        moveSearchFocused = false
                    }
                    if !moveQuery.isEmpty {
                        Button { moveQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Clear move search")
                        .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-clear")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .padding(.horizontal, 9).frame(height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            }
            if choice.save?.randomLearnset == true {
                Text(BoundRRDexLearnset.randomizerNote).font(.caption).foregroundStyle(.secondary)
            }
            let filter = moveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            LazyVStack(alignment: .leading, spacing: layout == .layout11 ? 0 : 12) {
                ForEach(BoundRRDexLearnset.methods, id: \.self) { method in
                    let entries = pokemon.learnset.enumerated().filter { _, entry in
                        entry.method == method && (filter.isEmpty || catalog.learnedMove(entry, pokemon: pokemon, save: choice.save)?.name.localizedCaseInsensitiveContains(filter) == true)
                    }
                    if !entries.isEmpty {
                        let rows = ForEach(entries, id: \.offset) { index, entry in
                            if let move = catalog.learnedMove(entry, pokemon: pokemon, save: choice.save) {
                                BoundRRDexLearnsetMoveRow(move: move, level: entry.level, catalog: catalog)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-move-\(index)")
                                Divider()
                            }
                        }
                        if layout == .layout11 {
                            let expanded = expandedLearnsetMethod == method
                            let title = method == "Level up" ? "Level Up" : method
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    expandedLearnsetMethod = expanded ? nil : method
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(title).font(.system(size: 12, weight: .semibold))
                                        Spacer(minLength: 0)
                                        Text(String(entries.count)).font(.caption2).foregroundStyle(.secondary)
                                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 11, weight: .semibold)).frame(width: 12)
                                    }
                                    .frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).foregroundStyle(.primary)
                                .accessibilityLabel("\(title), \(entries.count) moves")
                                .accessibilityValue(expanded
                                    ? (controllerDexFocus == .learnsetMethod(controllerMethodIndex(method, pokemon: pokemon)) ? "Expanded, Controller highlighted" : "Expanded")
                                    : (controllerDexFocus == .learnsetMethod(controllerMethodIndex(method, pokemon: pokemon)) ? "Collapsed, Controller highlighted" : "Collapsed"))
                                .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-method-\(method)")
                                .id("learnset-method-\(method)")
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(controllerFocusColor(for: .learnsetMethod(controllerMethodIndex(method, pokemon: pokemon))), lineWidth: 2)
                                    .padding(1))
                                if expanded { rows }
                                Divider()
                            }
                        } else {
                            Section {
                                rows
                            } header: {
                                Text(method).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-method-\(method)")
                            }
                        }
                    }
                }
                if !pokemon.learnset.contains(where: { entry in
                    guard let move = catalog.learnedMove(entry, pokemon: pokemon, save: choice.save) else { return false }
                    return filter.isEmpty || move.name.localizedCaseInsensitiveContains(filter)
                }) {
                    Text(filter.isEmpty ? "No moves available" : "No moves found")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset-empty")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout\(layout.rawValue)-learnset")
    }

    private func openLayout12Learnset(method: String?, search: Bool = false) {
        layout12LearnsetPresented = true
        expandedLearnsetMethod = method
        moveQuery = ""
        moveSearchVisible = search
        moveSearchFocused = search
    }

    private func closeLayout12Learnset() {
        layout12ReturningToLearnset = layout == .layout12 && layout12LearnsetPresented
        layout12LearnsetPresented = false
        expandedLearnsetMethod = nil
        moveQuery = ""
        moveSearchVisible = false
        moveSearchFocused = false
    }

    private func layout12LearnsetBack(pokemon: BoundRRDexSpecies) -> some View {
        Button { closeLayout12Learnset() } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pokemon.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Learnset").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityLabel("Back to \(pokemon.name)")
        .accessibilityIdentifier("bound.rrdex-layout12-learnset-back")
    }

    private var layout12MoveSearchButton: some View {
        Button {
            if !layout12LearnsetPresented {
                openLayout12Learnset(method: nil, search: true)
            } else {
                moveSearchVisible.toggle()
                moveSearchFocused = moveSearchVisible
                moveQuery = ""
            }
        } label: {
            Image(systemName: moveSearchVisible ? "xmark" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(moveSearchVisible ? "Close move search" : "Search all moves")
        .accessibilityIdentifier("bound.rrdex-layout12-learnset-search-toggle")
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(controllerFocusColor(for: .learnsetSearch), lineWidth: 2).padding(2))
        .accessibilityValue(controllerDexFocus == .learnsetSearch ? "Controller highlighted" : "")
    }

    private func layout12LearnsetMethods(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        let methods = catalog.learnsetMethods(for: pokemon)
        return ScrollViewReader { proxy in
            ViewThatFits(in: .horizontal) {
                layout12MethodButtons(methods, pokemon: pokemon, fillsWidth: true)
                ScrollView(.horizontal) {
                    layout12MethodButtons(methods, pokemon: pokemon, fillsWidth: false)
                }.scrollIndicators(.hidden)
            }
            .onChange(of: controllerDexFocus) { _, focus in
                guard case .learnsetMethod(let index) = focus, methods.indices.contains(index) else { return }
                proxy.scrollTo("controller-learnset-method-\(index)", anchor: .center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout12-learnset-methods")
    }

    private func layout12MethodButtons(_ methods: [String], pokemon: BoundRRDexSpecies, fillsWidth: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(methods, id: \.self) { method in
                let methodIndex = controllerMethodIndex(method, pokemon: pokemon)
                let selected = layout12LearnsetPresented && expandedLearnsetMethod == method
                let focused = controllerDexFocus == .learnsetMethod(methodIndex)
                Button {
                    openLayout12Learnset(method: method)
                } label: {
                    Text(method == "Level up" ? "Level Up" : method)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                        .background(selected ? Color(uiColor: .deltaPurple).opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color(uiColor: .deltaPurple) : .primary)
                .accessibilityLabel("\(method == "Level up" ? "Level Up" : method), \(pokemon.learnset.filter { $0.method == method }.count) moves")
                .accessibilityValue(selected
                    ? (focused ? "Selected, Controller highlighted" : "Selected")
                    : (focused ? "Not selected, Controller highlighted" : "Not selected"))
                .accessibilityIdentifier("bound.rrdex-layout12-learnset-method-\(method)")
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(controllerFocusColor(for: .learnsetMethod(methodIndex)), lineWidth: 2)
                    .padding(1))
                .id("controller-learnset-method-\(methodIndex)")
            }
        }
    }

    private func layout12Learnset(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, compact: Bool) -> some View {
        let rows = catalog.learnsetRows(for: pokemon, save: choice.save, method: expandedLearnsetMethod, query: moveQuery)
        let filtering = !moveQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsLevels = !filtering && expandedLearnsetMethod == "Level up"
        return VStack(spacing: 0) {
            if compact {
                // On exceptionally short panels, keep every control reachable by
                // scrolling the whole learnset instead of leaving a zero-height list.
                ScrollView {
                    layout12LearnsetControls(pokemon: pokemon, catalog: catalog)
                    layout12LearnsetRows(rows, catalog: catalog, showsLevels: showsLevels, filtering: filtering)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("bound.rrdex-layout12-learnset-list")
            } else {
                layout12LearnsetControls(pokemon: pokemon, catalog: catalog)
                ScrollView {
                    layout12LearnsetRows(rows, catalog: catalog, showsLevels: showsLevels, filtering: filtering)
                }
                .scrollDismissesKeyboard(.interactively)
                .id("\(expandedLearnsetMethod ?? "none")-\(moveQuery)")
                .accessibilityIdentifier("bound.rrdex-layout12-learnset-list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, portraitReferenceBottomInset ?? 0)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout12-learnset")
    }

    private func layout12LearnsetControls(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        VStack(spacing: 0) {
            if !hasIslandActions {
                HStack {
                    layout12LearnsetBack(pokemon: pokemon)
                    Spacer(minLength: 0)
                    layout12MoveSearchButton
                }
            }
            if moveSearchVisible {
                HStack(spacing: 4) {
                    BoundRRDexSearchField(text: $moveQuery, focused: $moveSearchFocused,
                                         placeholder: "Search all moves", identifier: "bound.rrdex-layout12-learnset-search") {
                        moveSearchFocused = false
                    }
                    if !moveQuery.isEmpty {
                        Button { moveQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Clear move search")
                        .accessibilityIdentifier("bound.rrdex-layout12-learnset-clear")
                    }
                }
                .padding(.leading, 9).frame(height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            } else {
                layout12LearnsetMethods(pokemon: pokemon, catalog: catalog)
            }
            Divider()
        }
    }

    private func layout12LearnsetRows(_ rows: [BoundRRDexLearnsetRow], catalog: BoundRRDexCatalog,
                                     showsLevels: Bool, filtering: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if choice.save?.randomLearnset == true {
                Text(BoundRRDexLearnset.randomizerNote).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            }
            if rows.isEmpty {
                Text(filtering ? "No moves found" : moveSearchVisible ? "Search across all learn methods" : "Choose a learn method")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                    .accessibilityIdentifier("bound.rrdex-layout12-learnset-empty")
            } else {
                HStack(spacing: 7) {
                    if showsLevels { Text("Lv.").frame(width: 30, alignment: .leading) }
                    Text("Moves · \(rows.count)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Acc / PP").frame(width: 68, alignment: .trailing)
                    Text("Power").frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 3)
                Divider()
                ForEach(rows) { row in
                    BoundRRDexCompactMoveRow(row: row, catalog: catalog, showsLevel: showsLevels,
                                            showsSources: filtering)
                    .id(row.id)
                    Divider()
                }
            }
        }
    }

    private func cardLayout2(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool, denseSizing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 4 : compact ? 5 : 7) {
            toolbar(catalog: catalog)
            if denseSizing && !compact && !hasIslandActions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        searchRow(catalog: catalog)
                        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            suggestionRows(catalog: catalog)
                        } else {
                            layout2Content(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true)
                        }
                    }
                }
                .accessibilityIdentifier("bound.rrdex-details")
                .scrollDismissesKeyboard(.interactively)
                detailActions(compact: true, dense: true)
            } else {
                searchRow(catalog: catalog)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if compact { suggestionRows(catalog: catalog) }
                    else { suggestions(catalog: catalog).frame(maxHeight: .infinity) }
                } else if compact {
                    layout2Content(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: denseSizing)
                    if !hasIslandActions { detailActions(compact: true, dense: denseSizing) }
                } else {
                    if denseSizing {
                        layout2DenseHeader(pokemon: pokemon, catalog: catalog)
                    } else {
                        speciesIdentity(pokemon: pokemon, catalog: catalog, spriteSize: 62)
                        pinnedAbilities(pokemon: pokemon, catalog: catalog)
                    }
                    ScrollView {
                        layout2Details(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
                    }
                    .accessibilityIdentifier("bound.rrdex-details")
                    .scrollDismissesKeyboard(.interactively)
                    if !hasIslandActions { detailActions(compact: denseSizing, dense: denseSizing) }
                }
            }
        }
        .padding(denseSizing ? 4 : compact ? 8 : 12)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private func layout2Content(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                compact: Bool, denseSizing: Bool) -> some View {
        if denseSizing {
            layout2DenseHeader(pokemon: pokemon, catalog: catalog)
        } else {
            speciesIdentity(pokemon: pokemon, catalog: catalog, spriteSize: compact ? 44 : 62)
            pinnedAbilities(pokemon: pokemon, catalog: catalog)
        }
        layout2Details(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
    }

    private func layout2DenseHeader(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        HStack(alignment: .center, spacing: 6) {
            BoundRRDexSprite(pokemon: pokemon).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                speciesHeading(pokemon: pokemon, catalog: catalog, denseSizing: true)
                pinnedAbilities(pokemon: pokemon, catalog: catalog, compact: true, showTitle: false)
            }
        }
    }

    @ViewBuilder
    private func layout2Details(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                denseSizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 4 : 8) {
            matchupSummary(pokemon: pokemon, catalog: catalog, compact: denseSizing)
            statsLine(pokemon: pokemon, compact: denseSizing)
            evolutionLine(pokemon: pokemon, catalog: catalog)
            referenceFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardLayout3(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool, denseSizing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            if denseSizing && !compact && !hasIslandActions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        layout3Content(pokemon: pokemon, catalog: catalog, compact: true, denseSizing: true,
                                       includeSearch: true)
                    }
                }
                .accessibilityIdentifier("bound.rrdex-layout3-details")
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                layout3Content(pokemon: pokemon, catalog: catalog, compact: compact,
                               denseSizing: denseSizing, includeSearch: true)
            }
            VStack(spacing: 2) {
                if !hasIslandActions { detailActions(compact: true) }
                toolbar(catalog: catalog)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bound.rrdex-layout3-actions")
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.top, compact ? 5 : 8)
        .padding(.bottom, compact ? 7 : 0)
        .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private func layout3Content(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                compact: Bool, denseSizing: Bool, includeSearch: Bool) -> some View {
        if includeSearch { searchRow(catalog: catalog) }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if compact { suggestionRows(catalog: catalog) }
            else { suggestions(catalog: catalog).frame(maxHeight: .infinity) }
        } else {
            HStack(alignment: .center, spacing: 8) {
                BoundRRDexSprite(pokemon: pokemon).frame(width: denseSizing ? 42 : compact ? 42 : 54,
                                                         height: denseSizing ? 42 : compact ? 42 : 54)
                VStack(alignment: .leading, spacing: 2) {
                    speciesHeading(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
                    pinnedAbilities(pokemon: pokemon, catalog: catalog, compact: true,
                                    showTitle: !denseSizing)
                }
            }
            if compact {
                VStack(alignment: .leading, spacing: 5) {
                    matchupSummary(pokemon: pokemon, catalog: catalog, compact: true)
                    statsLine(pokemon: pokemon, compact: true)
                    evolutionLine(pokemon: pokemon, catalog: catalog).font(.system(size: 10))
                    referenceFooter
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        matchupSummary(pokemon: pokemon, catalog: catalog, compact: true)
                        statsLine(pokemon: pokemon, compact: true)
                        evolutionLine(pokemon: pokemon, catalog: catalog).font(.system(size: 10))
                        referenceFooter
                    }
                }
                .accessibilityIdentifier("bound.rrdex-layout3-details")
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Layout 4 keeps the same quick-reference content as Layout 3, but groups
    /// it into clearer modules and gives abilities a comfortable touch target.
    private func cardLayout4(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool, denseSizing: Bool = false) -> some View {
        cardLayoutShell(catalog: catalog, compact: compact, denseSizing: denseSizing,
                        detailsIdentifier: "bound.rrdex-layout4-details") {
            layout4Content(pokemon: pokemon, catalog: catalog, denseSizing: $0)
        }
    }

    @ViewBuilder
    private func layout4Content(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                               denseSizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 6 : 8) {
            if searching || !query.isEmpty {
                searchRow(catalog: catalog, comfortableTargets: true)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestionRows(catalog: catalog)
            } else {
                layout4Identity(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
                layout4Modules(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
            }
        }
    }

    private func layout4Identity(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                 denseSizing: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            BoundRRDexSprite(pokemon: pokemon)
                .frame(width: denseSizing ? 42 : 54, height: denseSizing ? 42 : 54)
            VStack(alignment: .leading, spacing: denseSizing ? 2 : 4) {
                speciesHeading(pokemon: pokemon, catalog: catalog, denseSizing: denseSizing)
                pinnedAbilities(pokemon: pokemon, catalog: catalog, compact: true,
                                showTitle: false, comfortableTargets: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func layout4Modules(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                denseSizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 5 : 8) {
            matchupSummary(pokemon: pokemon, catalog: catalog, compact: denseSizing)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("BASE STATS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text("BST \(pokemon.stats.reduce(0, +))")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                statsLine(pokemon: pokemon, compact: denseSizing)
            }
            DisclosureGroup(isExpanded: $layout4EvolutionExpanded) {
                evolutionLine(pokemon: pokemon, catalog: catalog, showsSummary: false)
                    .padding(.top, 4)
            } label: {
                Label("Evolution and methods", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bound.rrdex-layout4-evolution")
            .accessibilityLabel("Evolution and methods")
            .accessibilityValue(layout4EvolutionExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(layout4EvolutionExpanded ? "Hides evolution details" : "Shows evolution details")
            .padding(.horizontal, 8)
            .padding(.vertical, denseSizing ? 2 : 5)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityElement(children: .contain)
    }

    /// Layout 5 keeps the species identity, matchup summary, and every base
    /// stat visible before evolution details. The single detail scroller gives
    /// short portrait panels room to reveal the lower modules while the search
    /// and import controls stay reachable at the game edge.
    private func cardLayout5(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool, denseSizing: Bool = false) -> some View {
        cardLayoutShell(catalog: catalog, compact: compact, denseSizing: denseSizing,
                        detailsIdentifier: "bound.rrdex-layout5-details",
                        topPadding: compact ? 3 : 6, bottomPadding: compact ? 5 : 0,
                        spacing: compact ? 3 : 5, bst: pokemon.stats.reduce(0, +)) {
            layout5Content(pokemon: pokemon, catalog: catalog, denseSizing: $0)
        }
    }

    /// Layout 6 keeps the full quick-reference row visible and moves evolution
    /// methods into a dedicated sheet with clear, tappable species choices.
    private func cardLayout6(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                             compact: Bool, denseSizing: Bool = false) -> some View {
        cardLayoutShell(catalog: catalog, compact: compact, denseSizing: denseSizing,
                        detailsIdentifier: "bound.rrdex-layout6-details",
                        topPadding: compact ? 3 : 6, bottomPadding: compact ? 5 : 0,
                        spacing: compact ? 3 : 5, bst: pokemon.stats.reduce(0, +),
                        layout6Footer: true) {
            layout6Content(pokemon: pokemon, catalog: catalog, denseSizing: $0)
        }
    }

    private func layout6Content(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                denseSizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 4 : 6) {
            if searching || !query.isEmpty {
                searchRow(catalog: catalog, comfortableTargets: true)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestionRows(catalog: catalog)
            } else {
                layout4Identity(pokemon: pokemon, catalog: catalog, denseSizing: true)
                matchupSummary(pokemon: pokemon, catalog: catalog, compact: true)
                layout5StatsLine(pokemon: pokemon, identifier: "bound.rrdex-layout6-stats")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func cardLayoutShell<Content: View>(catalog: BoundRRDexCatalog, compact: Bool, denseSizing: Bool,
                                                detailsIdentifier: String,
                                                topPadding: CGFloat? = nil,
                                                bottomPadding: CGFloat? = nil,
                                                spacing: CGFloat? = nil,
                                                bst: Int? = nil,
                                                layout6Footer: Bool = false,
                                                @ViewBuilder content: (Bool) -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing ?? (compact ? 4 : 6)) {
            if compact {
                content(true)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { referenceFooter }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        content(denseSizing)
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { referenceFooter }
                    }
                }
                    .id(searching || !query.isEmpty)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(detailsIdentifier)
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if !hasIslandActions {
                detailActions(compact: compact, comfortableTargets: true)
            }
            if layout6Footer {
                layout6Toolbar(bst: bst ?? 0)
            } else {
                toolbar(catalog: catalog, comfortableTargets: true, bst: bst)
            }
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.top, topPadding ?? (compact ? 5 : 8))
        .padding(.bottom, bottomPadding ?? (compact ? 7 : 0))
        .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private func layout5Content(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                denseSizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: denseSizing ? 4 : 6) {
            if searching || !query.isEmpty {
                searchRow(catalog: catalog, comfortableTargets: true)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestionRows(catalog: catalog)
            } else {
                layout4Identity(pokemon: pokemon, catalog: catalog, denseSizing: true)
                matchupSummary(pokemon: pokemon, catalog: catalog, compact: true)
                layout5StatsLine(pokemon: pokemon)
                DisclosureGroup(isExpanded: $layout5EvolutionExpanded) {
                    evolutionLine(pokemon: pokemon, catalog: catalog, showsSummary: false)
                        .padding(.top, 3)
                } label: {
                    Label("Evolution and methods", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.rrdex-layout5-evolution")
                .accessibilityLabel("Evolution and methods")
                .accessibilityValue(layout5EvolutionExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(layout5EvolutionExpanded ? "Hides evolution details" : "Shows evolution details")
                .padding(.horizontal, 8)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func layout5StatsLine(pokemon: BoundRRDexSpecies,
                                  identifier: String = "bound.rrdex-layout5-stats") -> some View {
        HStack(spacing: 5) {
            ForEach(Array(zip(statLabels, pokemon.stats)), id: \.0) { label, stat in
                VStack(spacing: 2) {
                    Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(String(stat)).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(usesUIVersion2 ? statColor(stat) : .primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label), \(stat)")
                .accessibilityIdentifier(identifier.replacingOccurrences(of: "-stats", with: "-stat-\(label)"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func layout6Toolbar(bst: Int) -> some View {
        HStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                Text("RR 4.1").font(.system(size: 9, weight: .medium, design: .monospaced))
                Text("BST \(bst)").font(.system(size: 8, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 43, alignment: .leading)
            Spacer(minLength: 0)
            footerAction("Search", icon: "magnifyingglass", identifier: "bound.rrdex-search-open", width: 56) { searching = true }
            footerAction("Evolution", icon: "arrow.triangle.branch", identifier: "bound.rrdex-evolution-open", width: 64) { showDetail(.evolution) }
            footerAction(choice.save == nil ? "Import save" : "Save loaded",
                         icon: choice.save == nil ? "square.and.arrow.down" : "checkmark.circle",
                         identifier: "bound.rrdex-import", width: 74) { importCurrentGameSave() }
            Color.clear.frame(width: 44, height: 44)
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout6-footer")
    }

    private func footerAction(_ title: String, icon: String, identifier: String, width: CGFloat,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.72)
            }
            .frame(width: width, height: 44)
            .contentShape(Rectangle())
            .background(Color(uiColor: .deltaPurple).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(identifier == "bound.rrdex-search-open" ? controllerFocusColor(for: .speciesSearch) : .clear, lineWidth: 2)
            .padding(1))
    }

    private func toolbar(catalog: BoundRRDexCatalog, comfortableTargets: Bool = false, bst: Int? = nil) -> some View {
        HStack {
            if let bst {
                VStack(alignment: .leading, spacing: 1) {
                    Text("RR 4.1").font(.system(size: 9, weight: .medium, design: .monospaced))
                    Text("BST \(bst)").font(.system(size: 8, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            } else {
                Text(comfortableTargets ? "RR 4.1" : "RR 4.1 · NORMAL")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if comfortableTargets {
                Button { searching = true } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Search Pokémon")
                .accessibilityIdentifier("bound.rrdex-search-open")
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(controllerFocusColor(for: .speciesSearch), lineWidth: 2).padding(2))
                .accessibilityValue(controllerDexFocus == .speciesSearch ? "Controller highlighted" : "")
            }
            Button { importCurrentGameSave() } label: {
                Label(choice.save == nil ? "Import save" : "Save loaded", systemImage: choice.save == nil ? "square.and.arrow.down" : "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(comfortableTargets ? 1 : nil).minimumScaleFactor(comfortableTargets ? 0.9 : 1)
                    .frame(minHeight: comfortableTargets ? 44 : nil)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("bound.rrdex-import")
            .accessibilityHint("Imports or refreshes the current game's save automatically")
            Image(systemName: "info.circle")
                .frame(minWidth: comfortableTargets ? 44 : nil, minHeight: comfortableTargets ? 44 : nil)
                .hidden().accessibilityHidden(true)
        }
        .frame(minHeight: comfortableTargets ? 44 : 28)
    }

    private func searchRow(catalog: BoundRRDexCatalog, comfortableTargets: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            BoundRRDexSearchField(text: $query, focused: Binding(get: { searching }, set: { searching = $0 })) {
                if let first = catalog.suggestions(query).first { select(first) } else { searching = false }
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: comfortableTargets ? 44 : nil, height: comfortableTargets ? 44 : nil)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Clear search").accessibilityIdentifier("bound.rrdex-clear-search")
            }
            if hasInlineSearch {
                Button { query = ""; searching = false } label: {
                    Text("Done").font(.system(size: 11))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close Pokémon search")
                .accessibilityIdentifier("bound.rrdex-search-open")
            } else if query.isEmpty && searching {
                Button { searching = false } label: {
                    Text("Done").font(.system(size: 11))
                        .frame(minWidth: comfortableTargets ? 44 : nil, minHeight: comfortableTargets ? 44 : nil)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(.system(size: 14)).padding(.horizontal, 9)
        .frame(height: comfortableTargets ? 44 : 32)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
    }

    private func speciesIdentity(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, spriteSize: CGFloat) -> some View {
        HStack(spacing: 9) {
            BoundRRDexSprite(pokemon: pokemon).frame(width: spriteSize, height: spriteSize)
            VStack(alignment: .leading, spacing: 4) { speciesHeading(pokemon: pokemon, catalog: catalog) }
            Spacer(minLength: 0)
        }
    }

    private func speciesHeading(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                denseSizing: Bool = false) -> some View {
        let name = HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(pokemon.name).font(.system(size: denseSizing ? 14 : 19, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.65)
                .accessibilityIdentifier("bound.rrdex-pokemon")
            Text("#\(pokemon.dexNumber)").font(.system(size: denseSizing ? 9 : 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        let types = HStack(spacing: 5) {
            ForEach(pokemon.types, id: \.self) { id in
                if let type = catalog.type(id: id) { BoundRRDexTypePill(type: type, usesFullColor: true) }
            }
        }
        return Group {
            if denseSizing {
                HStack(spacing: 6) { name; Spacer(minLength: 2); types }
            } else {
                VStack(alignment: .leading, spacing: 4) { name; types }
            }
        }
    }

    private func statsLine(pokemon: BoundRRDexSpecies, compact: Bool) -> some View {
        return HStack(spacing: 5) {
            ForEach(Array(zip(statLabels, pokemon.stats)), id: \.0) { label, stat in
                VStack(spacing: 2) {
                    Text(label).font(.system(size: compact ? 8 : 9)).foregroundStyle(.secondary)
                    Text(String(stat)).font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(usesUIVersion2 ? statColor(stat) : .primary)
                }.frame(maxWidth: .infinity).padding(.vertical, compact ? 3 : 5)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(stat)")
            }
        }.accessibilityIdentifier("bound.rrdex-stats")
    }

    private func pinnedAbilities(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                compact: Bool = false, showTitle: Bool = true,
                                comfortableTargets: Bool = false) -> some View {
        let comfortable = comfortableTargets || usesUIVersion2
        return VStack(alignment: .leading, spacing: 3) {
            if showTitle { Text("ABILITIES").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            HStack(spacing: 5) {
                ForEach(Array(catalog.abilityDetails(for: pokemon, save: choice.save).enumerated()), id: \.offset) { index, ability in
                    let name = ability.name + (ability.isHidden ? " (Hidden)" : "")
                    Button { showDetail(.ability(name, ability.description)) } label: {
                        Group {
                            if comfortable {
                                HStack(spacing: 4) {
                                    Text(name).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "info.circle").font(.system(size: 10))
                                }
                                .font(.system(size: 11, weight: .medium))
                            } else {
                                Text(name).font(.system(size: compact ? 9 : 10, weight: .medium))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, compact ? 3 : 4)
                        .frame(maxWidth: comfortable ? .infinity : nil,
                               minHeight: comfortable ? 44 : nil)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bound.rrdex-ability-\(index)")
                    .accessibilityLabel("Ability: \(name)")
                }
                if catalog.abilityNames(for: pokemon, save: choice.save).isEmpty {
                    Text("No ability data").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func matchupSummary(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, compact: Bool = false) -> some View {
        let entries = catalog.defensiveMatchups(for: pokemon)
        let fourTimes = entries.filter { $0.multiplier >= 4 }
        let twoTimes = entries.filter { $0.multiplier == 2 }
        let immunities = entries.filter { $0.multiplier == 0 }
        return Button { showDetail(.weaknesses) } label: {
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 9))
                    Text("TYPING ONLY").font(.system(size: 8, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text("All matchups ›").font(.system(size: 9, weight: .medium))
                }.foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 5) {
                    matchupChip("4×", types: fourTimes, color: .red)
                    matchupChip("2×", types: twoTimes, color: .orange)
                    matchupChip("Immune", types: immunities, color: .green)
                }
            }
            .padding(compact ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bound.rrdex-matchup-summary")
        .accessibilityHint("Shows defensive type matchups. Abilities and battle effects may change damage.")
    }

    private func matchupChip(_ title: String, types: [BoundRRDexCatalog.Matchup], color: Color) -> some View {
        HStack(alignment: .top, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(types.isEmpty ? "—" : types.map(\.type.name).joined(separator: ", "))
                .font(.system(size: 8, weight: .medium)).lineLimit(2).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailActions(compact: Bool = false, dense: Bool = false,
                               comfortableTargets: Bool = false) -> some View {
        HStack(spacing: 8) {
            detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses,
                         dense: dense, comfortableTargets: comfortableTargets)
            detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset,
                         dense: dense, comfortableTargets: comfortableTargets)
        }
        .padding(.top, compact ? 2 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-actions")
    }

    private func details(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, expandedReference: Bool = false) -> some View {
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                BoundRRDexSprite(pokemon: pokemon).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pokemon.name).font(.system(size: 19, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                        .accessibilityIdentifier("bound.rrdex-pokemon")
                        .id("bound.rrdex-pokemon")
                    HStack(spacing: 5) {
                        ForEach(pokemon.types, id: \.self) { id in
                            if let type = catalog.type(id: id) { BoundRRDexTypePill(type: type, usesFullColor: true) }
                        }
                        Text("#\(pokemon.dexNumber)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if hasInlineSearch {
                    if layout == .layout7 { layout7SearchButton }
                    else { layout8SearchButton }
                }
            }
            if expandedReference {
                layout7AbilityDescriptions(pokemon: pokemon, catalog: catalog, layoutNumber: layout.rawValue)
            } else {
                Text(catalog.abilityNames(for: pokemon, save: choice.save).joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Abilities").accessibilityValue(catalog.abilityNames(for: pokemon, save: choice.save).joined(separator: ", "))
                .accessibilityIdentifier("bound.rrdex-abilities")
            }
            HStack(spacing: 5) {
                ForEach(Array(zip(statLabels, pokemon.stats)), id: \.0) { label, stat in
                    VStack(spacing: 2) {
                        Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(String(stat)).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(expandedReference || usesUIVersion2 ? statColor(stat) : .primary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(stat)")
                }
            }.accessibilityIdentifier(layout.rawValue >= 8 ? "bound.rrdex-layout\(layout.rawValue)-stats" : "bound.rrdex-stats")
            if expandedReference, layout == .layout8 || layout == .layout9 || layout == .layout10 || layout == .layout11 || layout == .layout12 { layout8Evolution(pokemon: pokemon, catalog: catalog) }
            else if expandedReference { layout7Evolution(pokemon: pokemon, catalog: catalog) }
            else { evolutionLine(pokemon: pokemon, catalog: catalog) }
            if usesUIVersion2 || layout == .layout10 || layout == .layout11 || layout == .layout12 {
                BoundRRDexCompactMatchups(pokemon: pokemon, catalog: catalog,
                                         identifier: "bound.rrdex-layout\(layout.rawValue)-matchups",
                                         usesFullTypeColors: layout == .layout12 || usesUIVersion2,
                                         showsExceptionalMultipliers: usesUIVersion2)
            }
            if layout == .layout9 || layout == .layout10 || layout == .layout11 || layout == .layout12 { inlineLearnset(pokemon: pokemon, catalog: catalog) }
            referenceFooter
        }
    }

    private func detailButton(_ title: String, icon: String, detail: Detail,
                              besideIsland: Bool = false, dense: Bool = false,
                              comfortableTargets: Bool = false,
                              identifier: String? = nil) -> some View {
        let comfortable = comfortableTargets || usesUIVersion2
        return Button {
            showDetail(detail)
        } label: {
            Label(title, systemImage: icon).font(.system(size: besideIsland ? 11 : dense ? 10 : 12, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: besideIsland || usesUIVersion2 ? 44 : nil)
                .frame(minHeight: comfortable ? 44 : nil)
                .padding(.vertical, besideIsland || comfortable ? 0 : dense ? 4 : 8)
                .background(Color(uiColor: .deltaPurple).opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        }.accessibilityIdentifier(identifier ?? "bound.rrdex-\(detail.id)")
    }
    private func suggestions(catalog: BoundRRDexCatalog) -> some View {
        ScrollView {
            suggestionRows(catalog: catalog)
        }.accessibilityIdentifier("bound.rrdex-suggestions")
    }

    private func suggestionRows(catalog: BoundRRDexCatalog) -> some View {
        let results = catalog.suggestions(query)
        return LazyVStack(spacing: 0) {
            if results.isEmpty {
                Text("No Pokémon found").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 20)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, pokemon in
                Button { select(pokemon) } label: {
                    HStack {
                        Text(pokemon.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                        Spacer()
                        Text(pokemon.types.compactMap { catalog.type(id: $0)?.name }.joined(separator: " / "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).frame(minHeight: usesUIVersion2 ? 44 : nil).contentShape(Rectangle())
                        .background(index == controllerSpeciesIndex && searching ? Color(uiColor: .deltaPurple).opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityIdentifier("bound.rrdex-suggestion-\(pokemon.id)")
                    .accessibilityValue(index == controllerSpeciesIndex && searching ? "Highlighted" : "")
                Divider()
            }
        }
    }
    private func evolutionLine(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                              showsSummary: Bool = true) -> some View {
        let links = catalog.evolutionLine(for: pokemon)
        return VStack(alignment: .leading, spacing: 5) {
            if showsSummary {
                HStack {
                    Text("EVOLUTION").font(.system(size: 9, weight: .medium, design: .monospaced))
                    Spacer()
                    Text("BST \(pokemon.stats.reduce(0, +))").font(.system(size: 9, design: .monospaced))
                }.foregroundStyle(.secondary)
            }
            if links.isEmpty { Text("No evolutions").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(links) { link in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Button(link.from.name) { select(link.from) }
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                        Button(link.to.name) { select(link.to) }
                    }.font(.system(size: 11, weight: .medium))
                    Text(link.method).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.accessibilityIdentifier("bound.rrdex-evolution")
    }
    private func evolutionDetail(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tap a Pokémon to view its stats and matchups.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                let links = catalog.evolutionLine(for: pokemon)
                if links.isEmpty {
                    Text("No evolutions listed for \(pokemon.name).")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                evolutionSpeciesButton(link.from)
                                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                                evolutionSpeciesButton(link.to)
                            }
                            Text(link.method).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.rrdex-layout6-evolution-detail")
    }

    private func evolutionSpeciesButton(_ species: BoundRRDexSpecies) -> some View {
        Button {
            select(species)
            sheet = nil
        } label: {
            Text(species.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
                .background(Color(uiColor: .deltaPurple).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bound.rrdex-evolution-select-\(species.id)")
        .accessibilityLabel(species.name)
    }

    private func select(_ pokemon: BoundRRDexSpecies) {
        choice.speciesID = pokemon.id; query = ""; searching = false
        moveQuery = ""; moveSearchVisible = false; moveSearchFocused = false
        expandedLearnsetMethod = nil
        closeLayout12Learnset()
        layout4EvolutionExpanded = false
        layout5EvolutionExpanded = false
        preferences.write(choice, gameID: gameID)
    }

    private func handleControllerNavigation(_ command: BoundControllerNavigationCommand, catalog: BoundRRDexCatalog) {
        if command == .clearFocus {
            controllerDexFocus = nil
            return
        }
        if hasPresentedSheet && !isControllerSpeciesPickerPresented {
            if case .back = command { sheet = nil }
            return
        }
        switch command {
        case .clearFocus:
            controllerDexFocus = nil
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return
        case .focusUp, .focusDown, .focusLeft, .focusRight:
            guard controllerMultiviewNavigationEnabled else { return }
            moveControllerDexFocus(command, catalog: catalog)
        case .previousItem:
            moveControllerSpeciesCursor(-1, catalog: catalog)
        case .nextItem:
            moveControllerSpeciesCursor(1, catalog: catalog)
        case .select:
            if isControllerSpeciesPickerPresented {
                let candidates = controllerSpeciesCandidates(catalog: catalog)
                guard candidates.indices.contains(controllerSpeciesIndex) else { return }
                select(candidates[controllerSpeciesIndex])
                sheet = nil
                return
            }
            if controllerMultiviewNavigationEnabled, let focus = controllerDexFocus {
                selectControllerDexFocus(focus, catalog: catalog)
                return
            }
            if searching, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidates = catalog.suggestions(query)
                guard candidates.indices.contains(controllerSpeciesIndex) else { return }
                select(candidates[controllerSpeciesIndex])
            } else {
                searching = false
                controllerSpeciesQuery = ""
                controllerSpeciesIndex = catalog.species.firstIndex(where: { $0.id == choice.speciesID }) ?? 0
                awaitingDetailDismissal = true
                sheet = .controllerSpeciesPicker
            }
        case .details:
            guard !isControllerSpeciesPickerPresented else { return }
            if layout == .layout12 {
                openLayout12Learnset(method: nil)
            } else {
                showDetail(.learnset)
            }
        case .back:
            if importError != nil {
                importError = nil
            } else if sheet != nil {
                sheet = nil
            } else if layout == .layout12 && layout12LearnsetPresented {
                closeLayout12Learnset()
                controllerDexFocus = .learnsetSearch
            } else if moveSearchVisible {
                moveSearchVisible = false
                moveSearchFocused = false
                moveQuery = ""
                controllerDexFocus = .learnsetSearch
            } else if editingText || !query.isEmpty {
                query = ""
                searching = false
                moveSearchFocused = false
            } else {
                controllerDexFocus = nil
            }
        }
    }

    private func controllerFocusColor(for focus: ControllerDexFocus) -> Color {
        controllerMultiviewNavigationEnabled && controllerDexFocus == focus
            ? Color(uiColor: .deltaPurple) : .clear
    }

    private func controllerMethods(catalog: BoundRRDexCatalog) -> [String] {
        guard let pokemon = catalog.pokemon(id: choice.speciesID) ?? catalog.species.first else { return [] }
        let available = layout == .layout12 ? catalog.learnsetMethods(for: pokemon) : BoundRRDexLearnset.methods
        return available.filter { method in pokemon.learnset.contains(where: { $0.method == method }) }
    }

    private func controllerMethodIndex(_ method: String, pokemon: BoundRRDexSpecies) -> Int {
        let available = layout == .layout12 ? catalogStore.dex?.learnsetMethods(for: pokemon) ?? [] : BoundRRDexLearnset.methods
        let methods = available.filter { candidate in pokemon.learnset.contains(where: { $0.method == candidate }) }
        return methods.firstIndex(of: method) ?? 0
    }

    private func moveControllerDexFocus(_ command: BoundControllerNavigationCommand, catalog: BoundRRDexCatalog) {
        if isControllerSpeciesPickerPresented {
            switch command {
            case .focusUp, .focusLeft: moveControllerSpeciesCursor(-1, catalog: catalog)
            case .focusDown, .focusRight: moveControllerSpeciesCursor(1, catalog: catalog)
            default: break
            }
            return
        }
        let methods = controllerMethods(catalog: catalog)
        switch command {
        case .focusDown:
            switch controllerDexFocus {
            case nil: controllerDexFocus = .speciesSearch
            case .speciesSearch: controllerDexFocus = .learnsetSearch
            case .learnsetSearch, .learnsetSearchInput:
                controllerDexFocus = methods.isEmpty ? .learnsetSearch : .learnsetMethod(0)
            case .learnsetMethod(let index):
                controllerDexFocus = methods.indices.contains(index) ? .learnsetMethod(index) : .learnsetSearch
            }
        case .focusUp:
            switch controllerDexFocus {
            case nil, .speciesSearch: controllerDexFocus = .speciesSearch
            case .learnsetSearch, .learnsetSearchInput: controllerDexFocus = .speciesSearch
            case .learnsetMethod(_): controllerDexFocus = .learnsetSearch
            }
        case .focusLeft, .focusRight:
            guard case .learnsetMethod(let index) = controllerDexFocus, !methods.isEmpty else { return }
            let delta = command == .focusRight ? 1 : -1
            controllerDexFocus = .learnsetMethod((index + delta + methods.count) % methods.count)
        default:
            break
        }
    }

    private func selectControllerDexFocus(_ focus: ControllerDexFocus, catalog: BoundRRDexCatalog) {
        switch focus {
        case .speciesSearch:
            searching = false
            controllerSpeciesQuery = ""
            controllerSpeciesIndex = catalog.species.firstIndex(where: { $0.id == choice.speciesID }) ?? 0
            awaitingDetailDismissal = true
            sheet = .controllerSpeciesPicker
        case .learnsetSearch:
            if layout == .layout12 {
                openLayout12Learnset(method: nil, search: true)
            } else if layout.rawValue >= 9 {
                moveSearchVisible = true
                moveSearchFocused = true
                moveQuery = ""
                controllerDexFocus = .learnsetSearchInput
            } else {
                showDetail(.learnset)
            }
        case .learnsetSearchInput:
            moveSearchFocused = true
        case .learnsetMethod(let index):
            let methods = controllerMethods(catalog: catalog)
            guard methods.indices.contains(index) else { return }
            if layout == .layout12 {
                openLayout12Learnset(method: methods[index])
            } else if layout == .layout11 {
                expandedLearnsetMethod = methods[index]
            } else {
                showDetail(.learnset)
            }
        }
    }

    private func controllerSpeciesCandidates(catalog: BoundRRDexCatalog) -> [BoundRRDexSpecies] {
        let filter = controllerSpeciesQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filter.isEmpty ? catalog.species : catalog.suggestions(filter)
    }

    private func moveControllerSpeciesCursor(_ delta: Int, catalog: BoundRRDexCatalog) {
        if isControllerSpeciesPickerPresented {
            let candidates = controllerSpeciesCandidates(catalog: catalog)
            guard !candidates.isEmpty else { controllerSpeciesIndex = 0; return }
            controllerSpeciesIndex = (controllerSpeciesIndex + delta + candidates.count) % candidates.count
        } else if searching, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let candidates = catalog.suggestions(query)
            guard !candidates.isEmpty else { controllerSpeciesIndex = 0; return }
            controllerSpeciesIndex = (controllerSpeciesIndex + delta + candidates.count) % candidates.count
        } else {
            guard !catalog.species.isEmpty else { return }
            let current = catalog.species.firstIndex(where: { $0.id == choice.speciesID }) ?? 0
            let index = (current + delta + catalog.species.count) % catalog.species.count
            select(catalog.species[index])
        }
    }

    private func controllerSpeciesPicker(catalog: BoundRRDexCatalog) -> some View {
        let candidates = controllerSpeciesCandidates(catalog: catalog)
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, pokemon in
                    Button {
                        select(pokemon)
                        sheet = nil
                    } label: {
                        HStack {
                            Text(pokemon.name)
                            Spacer()
                            Text(pokemon.types.compactMap { catalog.type(id: $0)?.name }.joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                            if index == controllerSpeciesIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(uiColor: .deltaPurple))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bound.rrdex-controller-species-\(pokemon.id)")
                    .accessibilityValue(index == controllerSpeciesIndex ? "Highlighted" : "")
                    .id(pokemon.id)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("bound.rrdex-controller-species-picker")
            .boundControllerScroll(gameID: gameID, content: .dex, active: isActive && isControllerSpeciesPickerPresented)
            .searchable(text: $controllerSpeciesQuery, prompt: "Pokémon")
            .onChange(of: controllerSpeciesQuery) { _, _ in
                controllerSpeciesIndex = 0
                if let first = controllerSpeciesCandidates(catalog: catalog).first { proxy.scrollTo(first.id, anchor: .center) }
            }
            .onChange(of: controllerSpeciesIndex) { _, index in
                let visibleCandidates = controllerSpeciesCandidates(catalog: catalog)
                if visibleCandidates.indices.contains(index) { proxy.scrollTo(visibleCandidates[index].id, anchor: .center) }
            }
            .onAppear {
                if let index = candidates.firstIndex(where: { $0.id == choice.speciesID }) {
                    controllerSpeciesIndex = index
                    proxy.scrollTo(candidates[index].id, anchor: .center)
                }
            }
        }
    }
    private func importCurrentGameSave() {
        searching = false
        do {
            let save = try currentSave()
            choice.save = save
            automaticSaveStatus = nil
            preferences.write(choice, gameID: gameID)
        } catch {
            recordSaveReadFailure(error)
            importError = error.localizedDescription
        }
    }
    private func refreshAutomaticSave() {
        guard isActive, previewLayout == nil, !refreshingSave else { return }
        refreshingSave = true
        defer { refreshingSave = false }
        do {
            choice = try preferences.refreshCurrentSave(gameID: gameID, capture: currentSave)
            automaticSaveStatus = nil
        } catch {
            recordSaveReadFailure(error)
        }
    }

    private func recordSaveReadFailure(_ error: Error) {
        // Unsupported or incomplete saves must not keep a stale loaded check.
        // Transient capture failures retain the last successfully read settings.
        if BoundRRDexSave.shouldDiscardCachedConfiguration(after: error) {
            choice.save = nil
            preferences.write(choice, gameID: gameID)
        } else {
            choice = preferences.read(gameID: gameID)
        }
        automaticSaveStatus = error.localizedDescription
    }
}

/// Explicit UIKit traits match Notes, including spelling underlines and smart edits.
struct BoundRRDexSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = "Search Pokémon"
    var identifier = "bound.rrdex-search"
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = Self.makeTextField()
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    static func makeTextField() -> UITextField {
        let field = UITextField()
        field.placeholder = "Search Pokémon"
        field.font = .systemFont(ofSize: 14)
        field.textColor = .label
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = .search
        field.accessibilityIdentifier = "bound.rrdex-search"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if focused && !field.isFirstResponder {
            DispatchQueue.main.async { if context.coordinator.parent.focused { field.becomeFirstResponder() } }
        } else if !focused && field.isFirstResponder { field.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: BoundRRDexSearchField
        init(_ parent: BoundRRDexSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { parent.submit(); return false }
    }
}

private struct BoundRRDexSprite: View {
    let pokemon: BoundRRDexSpecies
    var body: some View {
        Group {
            if let image = BoundRRImageCache.shared.image(key: "pokemon-\(pokemon.id)", base64: pokemon.sprite) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.accessibilityLabel("\(pokemon.name) picture").accessibilityIdentifier("bound.rrdex-picture")
    }
}
private struct BoundRRDexTypePill: View {
    let type: BoundRRDexType
    var usesFullColor = false
    private var hex: UInt32 { UInt32(type.color.dropFirst(), radix: 16) ?? 0x777777 }
    private var color: Color {
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private var textColor: Color {
        guard usesFullColor else { return .primary }
        // Choose readable text without altering the source type's RGB color.
        func linear(_ component: UInt32) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((hex >> 16) & 255)
            + 0.7152 * linear((hex >> 8) & 255) + 0.0722 * linear(hex & 255)
        return luminance > 0.179 ? .black : .white
    }
    var body: some View {
        Text(type.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(textColor)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(usesFullColor ? 1 : 0.23), in: Capsule())
    }
}
private struct BoundRRDexDetail<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("bound.rrdex-close-detail") } }
        }.tint(Color(uiColor: .deltaPurple))
    }
}
struct BoundRRDexMatchups: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
    var highlightsExtremes = false
    var body: some View {
        List {
            Section {
                Text(pokemon.name).font(.headline)
            }
            ForEach(["Weaknesses", "Resistances", "Immunities", "Neutral"], id: \.self) { section in
                let entries = catalog.defensiveMatchups(for: pokemon).filter { entry in
                    switch section { case "Weaknesses": return entry.multiplier > 1; case "Resistances": return entry.multiplier > 0 && entry.multiplier < 1; case "Immunities": return entry.multiplier == 0; default: return entry.multiplier == 1 }
                }
                Section(section) {
                    if entries.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        HStack {
                            BoundRRDexTypePill(type: entry.type)
                            Spacer()
                            Text(entry.label).monospacedDigit()
                                .fontWeight(highlightsExtremes && (entry.multiplier >= 4 || entry.multiplier == 0) ? .bold : .regular)
                                .foregroundStyle(highlightsExtremes && entry.multiplier >= 4 ? Color.red : highlightsExtremes && entry.multiplier == 0 ? Color.green : Color.primary)
                        }
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }.accessibilityIdentifier("bound.rrdex-matchups")
    }
}

/// Compact type-only matchups shared by the Layout 10–12 reference cards.
struct BoundRRDexCompactMatchups: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
    let identifier: String
    var usesFullTypeColors = false
    var showsExceptionalMultipliers = false

    var body: some View {
        let matchups = catalog.defensiveMatchups(for: pokemon)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(["Weaknesses", "Resistances", "Immunities"], id: \.self) { group in
                let entries = matchups.filter { entry in
                    switch group {
                    case "Weaknesses": entry.multiplier > 1
                    case "Resistances": entry.multiplier > 0 && entry.multiplier < 1
                    default: entry.multiplier == 0
                    }
                }
                if !entries.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text(group + ":").font(.system(size: 11, weight: .semibold))
                            .padding(.top, 3).frame(width: 76, alignment: .leading)
                        BoundRRDexTypeFlowLayout {
                            ForEach(entries) { entry in
                                HStack(spacing: 3) {
                                    BoundRRDexTypePill(type: entry.type, usesFullColor: usesFullTypeColors)
                                    if showsExceptionalMultipliers, entry.multiplier >= 4 || entry.multiplier > 0 && entry.multiplier <= 0.25 {
                                        Text(exceptionalMultiplierLabel(entry.multiplier))
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(entry.multiplier >= 4 ? Color.red : Color.green)
                                            .accessibilityHidden(true)
                                    }
                                }
                                    .accessibilityLabel(entry.type.name)
                                    .accessibilityValue(entry.label)
                                    .accessibilityIdentifier("\(identifier)-\(group.lowercased())-type-\(entry.type.id)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(identifier)-\(group.lowercased())")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func exceptionalMultiplierLabel(_ multiplier: Double) -> String {
        if multiplier >= 4 { return "×\(multiplier.formatted(.number.precision(.fractionLength(0))))" }
        if abs(multiplier - 0.25) < 0.001 { return "¼×" }
        if abs(multiplier - 0.5) < 0.001 { return "½×" }
        return "×\(multiplier.formatted(.number.precision(.fractionLength(0...2))))"
    }
}

/// Keep type pills at their natural width and wrap them within a narrow panel.
private struct BoundRRDexTypeFlowLayout: Layout {
    private let spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            + CGFloat(max(0, subviews.count - 1)) * spacing
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
        let rows = arrangement(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in rows.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, natural.width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }
}

private struct BoundRRDexLearnset: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
    let save: BoundRRDexSave?
    @State private var query = ""
    static let methods = ["Level up", "TM/HM", "Tutor", "Egg", "Pre-evolution", "Event"]
    static let randomizerNote = "Level-up moves match your imported save. TM/HM, tutor and egg moves keep their standard moves."
    var body: some View {
        List {
            Section {
                Text(pokemon.name).font(.headline)
                if save?.randomLearnset == true { Text(Self.randomizerNote).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Self.methods, id: \.self) { method in
                let entries = pokemon.learnset.enumerated().filter { _, entry in
                    entry.method == method && (query.isEmpty || catalog.learnedMove(entry, pokemon: pokemon, save: save)?.name.localizedCaseInsensitiveContains(query) == true)
                }
                if !entries.isEmpty {
                    Section(method) {
                        ForEach(entries, id: \.offset) { _, entry in
                            if let move = catalog.learnedMove(entry, pokemon: pokemon, save: save) {
                                BoundRRDexLearnsetMoveRow(move: move, level: entry.level, catalog: catalog)
                            }
                        }
                    }
                }
            }
            if !query.isEmpty && !pokemon.learnset.contains(where: { catalog.learnedMove($0, pokemon: pokemon, save: save)?.name.localizedCaseInsensitiveContains(query) == true }) {
                Text("No moves found").foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("bound.rrdex-moves")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a move")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}

/// Layout 12 keeps move details and comparison values in the same compact row.
private struct BoundRRDexCompactMoveRow: View {
    let row: BoundRRDexLearnsetRow
    let catalog: BoundRRDexCatalog
    let showsLevel: Bool
    let showsSources: Bool
    @ScaledMetric(relativeTo: .subheadline) private var nameSize = 14.0
    @ScaledMetric(relativeTo: .caption) private var metadataSize = 11.0

    private var power: String { row.move.power == 0 ? "—" : String(row.move.power) }
    private var accuracy: String { row.move.accuracy == 0 ? "—" : String(row.move.accuracy) }
    private var type: BoundRRDexType? { catalog.type(id: row.move.type) }
    private var typeColor: Color {
        let hex = UInt32(type?.color.dropFirst() ?? "777777", radix: 16) ?? 0x777777
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    var body: some View {
        HStack(spacing: 7) {
            if showsLevel {
                Text(row.level.map { $0 == 0 ? "Evo" : String($0) } ?? "—")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.move.name).font(.system(size: nameSize, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let type {
                        Circle().fill(typeColor).frame(width: 6, height: 6)
                        Text(type.name)
                    }
                    Text(row.move.category).foregroundStyle(.secondary)
                }
                .font(.system(size: metadataSize)).lineLimit(1)
                if showsSources {
                    Text(row.sourceSummary).font(.system(size: metadataSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(accuracy) · \(row.move.pp)")
                .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                .frame(width: 68, alignment: .trailing)
                .accessibilityLabel("Accuracy \(accuracy), PP \(row.move.pp)")
            Text(power).font(.system(size: nameSize)).monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 5).frame(minHeight: 44).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.move.name), \(type?.name ?? ""), \(row.move.category), accuracy \(accuracy), PP \(row.move.pp), power \(power), \(row.sourceSummary)")
        .accessibilityIdentifier("bound.rrdex-layout12-learnset-move-\(row.id)")
    }
}

/// One row format for both the original sheet and Layout 9's scrolling learnset.
private struct BoundRRDexLearnsetMoveRow: View {
    let move: BoundRRDexMove
    let level: Int?
    let catalog: BoundRRDexCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(move.name).font(.headline)
                Spacer()
                if let level { Text(level == 0 ? "Evolution" : "Lv. \(level)").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                if let type = catalog.type(id: move.type) { BoundRRDexTypePill(type: type, usesFullColor: true) }
                Text(move.category).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Pwr \(move.power == 0 ? "—" : String(move.power)) · Acc \(move.accuracy == 0 ? "—" : String(move.accuracy)) · PP \(move.pp)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

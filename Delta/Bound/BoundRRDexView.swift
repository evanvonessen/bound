import SwiftUI
import UIKit

struct BoundRRDexView: View {
    let gameID: String
    var floating = false
    var portraitTopInset: CGFloat = 0
    let presentationChanged: (Bool) -> Void
    var textEditingChanged: (Bool) -> Void = { _ in }
    var currentSave: () throws -> BoundRRDexSave = { throw BoundRRDexSave.ImportError.currentGameUnavailable }
    private let catalog = BoundRRDexCatalog.bundled
    private let preferences = BoundRRDexPreferences()
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @AppStorage(BoundReferenceLayoutPreferences.dexKey) private var layout = BoundReferenceLayout.layout1
    @State private var choice = BoundRRDexPreferences.Choice()
    @State private var query = ""
    // UIKit owns focus; a SwiftUI FocusState without a .focused view resets it.
    @State private var searching = false
    @State private var importError: String?
    @State private var sheet: Detail?
    @State private var awaitingDetailDismissal = false
    @State private var layout4EvolutionExpanded = false
    @State private var layout5EvolutionExpanded = false
    private enum Detail: Identifiable {
        case weaknesses, learnset, information, evolution
        case ability(String, String)
        var id: String {
            switch self {
            case .weaknesses: "weaknesses"
            case .learnset: "learnset"
            case .information: "information"
            case .evolution: "evolution"
            case let .ability(name, _): "ability-\(name)"
            }
        }
    }
    private var interacting: Bool { searching || sheet != nil || importError != nil }
    private var hasIslandActions: Bool { !floating && portraitTopInset >= 51 }

    var body: some View {
        Group {
            if experimentsEnabled, let catalog, let pokemon = catalog.pokemon(id: choice.speciesID) ?? catalog.species.first {
                GeometryReader { geometry in
                    if floating {
                        floatingCard(pokemon: pokemon, catalog: catalog, size: geometry.size)
                    } else if geometry.size.height < 140 {
                        // Keep fixed controls reachable when the portrait strip
                        // is too short to hold them beside a scrolling list.
                        ScrollView {
                            compactCard(pokemon: pokemon, catalog: catalog)
                                .frame(width: geometry.size.width)
                        }
                        .id((layout == .layout4 || layout == .layout5 || layout == .layout6) && (searching || !query.isEmpty))
                        .scrollDismissesKeyboard(.interactively)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        selectedCard(pokemon: pokemon, catalog: catalog, size: geometry.size)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .padding(.top, portraitTopInset)
                .overlay(alignment: .top) {
                    if hasIslandActions {
                        HStack(spacing: 0) {
                            detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses, besideIsland: true)
                            // Reserve the center for the Dynamic Island and its clearance.
                            Spacer().frame(width: 160)
                            detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset, besideIsland: true)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: portraitTopInset)
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("bound.rrdex")
                .accessibilityValue(layout.title)
                .onAppear { choice = preferences.read(gameID: gameID) }
                .sheet(item: $sheet, onDismiss: detailDismissed) { detail in
                    BoundRRDexDetail(title: detailTitle(detail)) {
                        switch detail {
                        case .weaknesses: BoundRRDexMatchups(pokemon: pokemon, catalog: catalog)
                        case .learnset: BoundRRDexLearnset(pokemon: pokemon, catalog: catalog, save: choice.save)
                        case .information: information(catalog: catalog)
                        case .evolution: evolutionDetail(pokemon: pokemon, catalog: catalog)
                        case let .ability(name, description):
                            ScrollView { Text(description).frame(maxWidth: .infinity, alignment: .leading).padding() }
                                .accessibilityIdentifier("bound.rrdex-ability-description")
                        }
                    }
                }
            } else if experimentsEnabled {
                ContentUnavailableView("RRDex unavailable", systemImage: "book.closed", description: Text("The bundled dex could not be loaded."))
            }
        }
        .tint(Color(uiColor: .deltaPurple))
        .alert("Save could not be imported", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .onChange(of: searching) { _, active in textEditingChanged(active) }
        .onChange(of: interacting) { _, active in
            if active || !awaitingDetailDismissal { presentationChanged(active) }
        }
        .onChange(of: experimentsEnabled) { _, enabled in
            if !enabled { searching = false; sheet = nil; importError = nil }
        }
        .onDisappear {
            searching = false; sheet = nil
            textEditingChanged(false)
            if !awaitingDetailDismissal { presentationChanged(false) }
        }
    }

    private func detailTitle(_ detail: Detail) -> String {
        switch detail {
        case .weaknesses: "Type matchups"
        case .learnset: "Learnset"
        case .information: "RRDex"
        case .evolution: "Evolution and methods"
        case let .ability(name, _): name
        }
    }

    @ViewBuilder
    private func floatingCard(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog, size: CGSize) -> some View {
        let scale = min(size.width / 360, size.height / 300)
        if layout == .layout1 {
            card(pokemon: pokemon, catalog: catalog)
                .frame(width: size.width / max(scale, 0.001), height: 300).scaleEffect(scale)
                .frame(width: size.width, height: size.height)
        } else {
            selectedCard(pokemon: pokemon, catalog: catalog, size: CGSize(width: size.width / max(scale, 0.001), height: 300))
                .frame(width: size.width / max(scale, 0.001), height: 300).scaleEffect(scale)
                .frame(width: size.width, height: size.height)
        }
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
        }
    }

    private func showDetail(_ detail: Detail) {
        guard experimentsEnabled else { return }
        awaitingDetailDismissal = true
        searching = false; sheet = detail
    }

    private func detailDismissed() {
        // Keep the pause until UIKit clears the sheet, including a search-to-detail handoff.
        awaitingDetailDismissal = false
        if !interacting { presentationChanged(false) }
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
                Button { showDetail(.information) } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Dex information").accessibilityIdentifier("bound.rrdex-info")
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
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        matchupSummary(pokemon: pokemon, catalog: catalog, compact: true)
                        statsLine(pokemon: pokemon, compact: true)
                        evolutionLine(pokemon: pokemon, catalog: catalog).font(.system(size: 10))
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
    /// short portrait panels room to reveal the lower modules while the search,
    /// import, and information controls stay reachable at the game edge.
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
            } else {
                ScrollView { content(denseSizing) }
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
            ForEach(Array(zip(["HP", "Atk", "Def", "SpA", "SpD", "Spe"], pokemon.stats)), id: \.0) { label, stat in
                VStack(spacing: 2) {
                    Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(String(stat)).font(.system(size: 11, weight: .semibold, design: .rounded))
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
            footerAction("Info", icon: "info.circle", identifier: "bound.rrdex-info", width: 44) { showDetail(.information) }
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
            Button { showDetail(.information) } label: {
                Image(systemName: "info.circle")
                    .frame(minWidth: comfortableTargets ? 44 : nil, minHeight: comfortableTargets ? 44 : nil)
                    .contentShape(Rectangle())
            }
                .accessibilityLabel("Dex information").accessibilityIdentifier("bound.rrdex-info")
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
            } else if searching {
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
                if let type = catalog.type(id: id) { BoundRRDexTypePill(type: type) }
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
        HStack(spacing: 5) {
            ForEach(Array(zip(["HP", "Atk", "Def", "SpA", "SpD", "Spe"], pokemon.stats)), id: \.0) { label, stat in
                VStack(spacing: 2) {
                    Text(label).font(.system(size: compact ? 8 : 9)).foregroundStyle(.secondary)
                    Text(String(stat)).font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
                }.frame(maxWidth: .infinity).padding(.vertical, compact ? 3 : 5)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(stat)")
            }
        }.accessibilityIdentifier("bound.rrdex-stats")
    }

    private func pinnedAbilities(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog,
                                compact: Bool = false, showTitle: Bool = true,
                                comfortableTargets: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showTitle { Text("ABILITIES").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            HStack(spacing: 5) {
                ForEach(Array(catalog.abilityNames(for: pokemon, save: choice.save).enumerated()), id: \.offset) { index, name in
                    Button { showDetail(.ability(name, abilityDescription(name))) } label: {
                        Group {
                            if comfortableTargets {
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
                        .frame(maxWidth: comfortableTargets ? .infinity : nil,
                               minHeight: comfortableTargets ? 44 : nil)
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

    private func abilityDescription(_ name: String) -> String {
        let key = name.replacingOccurrences(of: " (Hidden)", with: "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
        return BoundBossReferenceData.bundled?.abilityDescriptions[key]
            ?? "A description for this ability is not included in the bundled reference."
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

    private func details(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                BoundRRDexSprite(pokemon: pokemon).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pokemon.name).font(.system(size: 19, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                        .accessibilityIdentifier("bound.rrdex-pokemon")
                    HStack(spacing: 5) {
                        ForEach(pokemon.types, id: \.self) { id in
                            if let type = catalog.type(id: id) { BoundRRDexTypePill(type: type) }
                        }
                        Text("#\(pokemon.dexNumber)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(catalog.abilityNames(for: pokemon, save: choice.save).joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Abilities").accessibilityValue(catalog.abilityNames(for: pokemon, save: choice.save).joined(separator: ", "))
                .accessibilityIdentifier("bound.rrdex-abilities")
            HStack(spacing: 5) {
                ForEach(Array(zip(["HP", "Atk", "Def", "SpA", "SpD", "Spe"], pokemon.stats)), id: \.0) { label, stat in
                    VStack(spacing: 2) {
                        Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(String(stat)).font(.system(size: 13, weight: .semibold, design: .rounded))
                    }.frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(stat)")
                }
            }.accessibilityIdentifier("bound.rrdex-stats")
            evolutionLine(pokemon: pokemon, catalog: catalog)
        }
    }

    private func detailButton(_ title: String, icon: String, detail: Detail,
                              besideIsland: Bool = false, dense: Bool = false,
                              comfortableTargets: Bool = false) -> some View {
        Button {
            showDetail(detail)
        } label: {
            Label(title, systemImage: icon).font(.system(size: besideIsland ? 11 : dense ? 10 : 12, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: besideIsland ? 44 : nil)
                .frame(minHeight: comfortableTargets ? 44 : nil)
                .padding(.vertical, besideIsland || comfortableTargets ? 0 : dense ? 4 : 8)
                .background(Color(uiColor: .deltaPurple).opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        }.accessibilityIdentifier("bound.rrdex-\(detail.id)")
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
            ForEach(results) { pokemon in
                Button { select(pokemon) } label: {
                    HStack {
                        Text(pokemon.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                        Spacer()
                        Text(pokemon.types.compactMap { catalog.type(id: $0)?.name }.joined(separator: " / "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("bound.rrdex-suggestion-\(pokemon.id)")
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
        guard experimentsEnabled else { return }
        choice.speciesID = pokemon.id; query = ""; searching = false
        layout4EvolutionExpanded = false
        layout5EvolutionExpanded = false
        preferences.write(choice, gameID: gameID)
    }
    private func importCurrentGameSave() {
        guard experimentsEnabled else { return }
        searching = false
        do {
            let save = try currentSave()
            choice.save = save
            preferences.write(choice, gameID: gameID)
        } catch { importError = error.localizedDescription }
    }
    private func information(catalog: BoundRRDexCatalog) -> some View {
        List {
            Section("Save") {
                Text(choice.save?.summary ?? "Browsing the standard Normal dex")
                Text("Tap Import save to read the current Radical Red 4.1 Normal game's battery save automatically. Unsaved in-game changes aren't included. Tap Save loaded to refresh it after the game has saved new settings.")
                Text("Bound deletes the temporary export after reading it and keeps only the randomizer seed and settings for this ROM on this device.")
                if choice.save != nil {
                    Button("Use standard dex", role: .destructive) {
                        guard experimentsEnabled else { return }
                        choice.save = nil; preferences.write(choice, gameID: gameID)
                    }.accessibilityIdentifier("bound.rrdex-clear-save")
                }
            }
            Section("Reference") {
                Text("Radical Red 4.1 · Normal difficulty")
                Text("\(catalog.species.count) Pokémon and forms · \(catalog.moves.count) moves")
                Text("Stats are base stats. Evolution methods and type matchups follow this version of Radical Red.")
                Link("Radical Red Pokédex · JwowSquared", destination: catalog.sourceURL)
                Text("Pokémon characters and artwork belong to their respective owners. Radical Red is a community project.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Explicit UIKit traits match Notes, including spelling underlines and smart edits.
struct BoundRRDexSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = Self.makeTextField()
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
            if let data = Data(base64Encoded: pokemon.sprite), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.accessibilityLabel("\(pokemon.name) picture").accessibilityIdentifier("bound.rrdex-picture")
    }
}
private struct BoundRRDexTypePill: View {
    let type: BoundRRDexType
    private var color: Color {
        let hex = UInt32(type.color.dropFirst(), radix: 16) ?? 0x777777
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    var body: some View {
        Text(type.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.23), in: Capsule())
    }
}
private struct BoundRRDexDetail<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    var body: some View {
        NavigationStack {
            content().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("bound.rrdex-close-detail") } }
        }.tint(Color(uiColor: .deltaPurple))
            .onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
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
                Text("Based on typing. Abilities, items, and battle effects can change damage.").font(.callout).foregroundStyle(.secondary)
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
private struct BoundRRDexLearnset: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
    let save: BoundRRDexSave?
    @State private var query = ""
    private let methods = ["Level up", "TM/HM", "Tutor", "Egg", "Pre-evolution", "Event"]
    var body: some View {
        List {
            Section {
                Text(pokemon.name).font(.headline)
                if save?.randomLearnset == true { Text("Level-up moves match your imported save. TM/HM, tutor and egg moves keep their standard moves.").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(methods, id: \.self) { method in
                let entries = pokemon.learnset.enumerated().filter { _, entry in
                    entry.method == method && (query.isEmpty || catalog.learnedMove(entry, pokemon: pokemon, save: save)?.name.localizedCaseInsensitiveContains(query) == true)
                }
                if !entries.isEmpty {
                    Section(method) {
                        ForEach(entries, id: \.offset) { _, entry in
                            if let move = catalog.learnedMove(entry, pokemon: pokemon, save: save) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(move.name).font(.headline)
                                        Spacer()
                                        if let level = entry.level { Text(level == 0 ? "Evolution" : "Lv. \(level)").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    HStack {
                                        if let type = catalog.type(id: move.type) { BoundRRDexTypePill(type: type) }
                                        Text(move.category).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Pwr \(move.power == 0 ? "—" : String(move.power)) · Acc \(move.accuracy == 0 ? "—" : String(move.accuracy)) · PP \(move.pp)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3)
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

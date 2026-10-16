import SwiftUI
import UIKit

struct BoundBossGuideView: View {
    let gameID: String
    var floating = false
    var portraitTopInset: CGFloat = 0
    let presentationChanged: (Bool) -> Void
    private let catalog = BoundBossCatalog.bundled
    private let preferences = BoundBossGuidePreferences()
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @AppStorage(BoundReferenceLayoutPreferences.bossKey) private var layout = BoundReferenceLayout.layout1
    @State private var selection = BoundBossGuideSelection(teamID: "kanto-leaders-4", pokemonIndex: 0)
    @State private var showingPicker = false
    @State private var showingTeam = false
    @State private var detailSheet: DetailSheet?
    @State private var showsLayout4Stats = false

    private enum DetailSheet: Identifiable {
        case ability(String, String?), item(String, String?)
        case weaknesses(BoundRRDexSpecies, BoundRRDexCatalog)
        var id: String {
            switch self {
            case .ability(_, _): "ability"
            case .item(_, _): "item"
            case .weaknesses(_, _): "weaknesses"
            }
        }
    }
    private var anyPresentation: Bool {
        showingPicker || showingTeam || detailSheet != nil
    }
    private var usesIslandActions: Bool { (layout == .layout3 || layout == .layout4) && !floating && portraitTopInset >= 51 }

    var body: some View {
        Group {
            if experimentsEnabled, let catalog {
                let selected = selection.resolved(in: catalog)
                let team = catalog.team(id: selected.teamID) ?? catalog.defaultTeam
                let pokemon = team.pokemon[selected.pokemonIndex]
                GeometryReader { geometry in
                    sizedCard(team: team, pokemon: pokemon, index: selected.pokemonIndex, size: geometry.size)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.boss-guide")
                .accessibilityValue(layout.title)
                .padding(.top, floating ? 0 : portraitTopInset)
                .overlay(alignment: .top) {
                    if usesIslandActions {
                        islandActions(pokemon: pokemon, onIsland: portraitTopInset >= 51)
                            .padding(.horizontal, portraitTopInset >= 51 ? 8 : 12)
                            .frame(height: max(44, portraitTopInset))
                    }
                }
                .onAppear { selection = preferences.read(gameID: gameID, catalog: catalog) }
                .sheet(isPresented: $showingPicker, onDismiss: presentationDismissed) {
                    BoundBossPicker(catalog: catalog, selectedID: selected.teamID) { id in
                        choose(BoundBossGuideSelection(teamID: id, pokemonIndex: 0), catalog: catalog)
                    }
                }
                .sheet(isPresented: $showingTeam, onDismiss: presentationDismissed) {
                    BoundBossTeamView(catalog: catalog, team: team)
                }
                .sheet(item: $detailSheet, onDismiss: presentationDismissed) { sheet in
                    switch sheet {
                    case let .ability(name, description):
                        BoundBossTextDetail(title: "Ability", name: name, description: description)
                    case let .item(name, description):
                        BoundBossTextDetail(title: "Held item", name: name, description: description)
                    case let .weaknesses(species, dex):
                        BoundBossWeaknessDetail(pokemon: species, catalog: dex)
                    }
                }
            } else if experimentsEnabled {
                ContentUnavailableView("Boss guide unavailable", systemImage: "book.closed",
                                       description: Text("The bundled guide could not be loaded."))
            }
        }
        .tint(Color(uiColor: .deltaPurple))
        .onChange(of: experimentsEnabled) { _, enabled in
            if !enabled { showingPicker = false; showingTeam = false; detailSheet = nil }
        }
        .onChange(of: anyPresentation) { _, presented in
            if presented { presentationChanged(true) }
        }
    }

    @ViewBuilder
    private func sizedCard(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, size: CGSize) -> some View {
        if floating {
            floatingLayout(team: team, pokemon: pokemon, index: index, size: size)
        } else if size.height < 140 {
            // Very short strips scroll the entire card so pinned controls
            // cannot consume the space needed to read the content.
            ScrollView {
                Group {
                    if layout == .layout1 {
                        card(team: team, pokemon: pokemon, index: index, scrollsDetails: false)
                    } else if layout == .layout4 {
                        layout4Card(team: team, pokemon: pokemon, index: index,
                                    compact: true, scrollsDetails: false)
                    } else {
                        enhancedCard(team: team, pokemon: pokemon, index: index,
                                     compact: true, scrollsDetails: false)
                    }
                }.frame(width: size.width)
            }
        } else {
            Group {
                switch layout {
                case .layout1:
                    card(team: team, pokemon: pokemon, index: index)
                case .layout2:
                    enhancedCard(team: team, pokemon: pokemon, index: index,
                                 compact: size.height < 330)
                case .layout3:
                    if !usesIslandActions && size.height < 240 {
                        enhancedCard(team: team, pokemon: pokemon, index: index, compact: true)
                    } else {
                        fullHeightCard(team: team, pokemon: pokemon, index: index,
                                       width: size.width, height: size.height)
                    }
                case .layout4:
                    layout4Card(team: team, pokemon: pokemon, index: index,
                                compact: size.height < 235, scrollsDetails: true,
                                scrollsOverview: size.height < 235 && !usesIslandActions)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func floatingLayout(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, size: CGSize) -> some View {
        let scale = min(size.width / 360, size.height / 260)
        let floatingCard: AnyView
        switch layout {
        case .layout1:
            floatingCard = AnyView(card(team: team, pokemon: pokemon, index: index))
        case .layout2:
            floatingCard = AnyView(enhancedCard(team: team, pokemon: pokemon, index: index, compact: true))
        case .layout3:
            floatingCard = AnyView(enhancedCard(team: team, pokemon: pokemon, index: index, compact: true))
        case .layout4:
            floatingCard = AnyView(layout4Card(team: team, pokemon: pokemon, index: index,
                                              compact: true, scrollsDetails: true))
        }
        return floatingCard
            .frame(width: size.width / max(scale, 0.001), height: 260)
            .scaleEffect(scale)
            .frame(width: size.width, height: size.height)
    }

    private func presentationDismissed() {
        // The binding changes before UIKit finishes dismissing, while resuming is still blocked.
        guard !anyPresentation else { return }
        presentationChanged(false)
    }

    private func card(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, scrollsDetails: Bool = true) -> some View {
        let detail = BoundBossReference.bundled?.detail(for: pokemon, teamID: team.id, pokemonIndex: index)
        let details = VStack(alignment: .leading, spacing: 8) {
            BoundBossPokemonIdentity(pokemon: pokemon, species: detail?.species, types: detail?.types ?? [])
            BoundBossStats(stats: pokemon.stats)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(Array(pokemon.moves.enumerated()), id: \.offset) { index, move in
                    BoundBossMoveRow(name: move, type: detail?.moves[index].type,
                                     category: detail?.moves[index].categoryLabel ?? "—", index: index)
                }
            }
            BoundBossDescription(title: "Ability", name: pokemon.ability, description: detail?.abilityDescription,
                                 identifier: "bound.boss-ability-description")
            BoundBossDescription(title: "Item", name: pokemon.item, description: detail?.itemDescription,
                                 identifier: "bound.boss-item-description")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RR 4.1 · DEFAULT").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cap = team.levelCap {
                    Text("Cap \(cap)").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color(uiColor: .deltaPurple).opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("bound.boss-cap")
                }
            }
            Button { showingPicker = true } label: {
                HStack(spacing: 5) {
                    Text(team.name).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if !team.variant.isEmpty {
                        Text(team.variant).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 130)
                            .foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Choose boss, \(team.name)")
            .accessibilityIdentifier("bound.boss-picker")
            Group {
                if scrollsDetails { ScrollView { details } } else { details }
            }
            .accessibilityIdentifier("bound.boss-details")
            .id("\(team.id)-\(index)")
            HStack(spacing: 12) {
                Button { advance(-1, team: team) } label: { Image(systemName: "chevron.left") }
                    .frame(width: 28, height: 28).disabled(index == 0)
                    .accessibilityLabel("Previous Pokémon").accessibilityIdentifier("bound.boss-previous")
                Text("\(index + 1) / \(team.pokemon.count)").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary).accessibilityIdentifier("bound.boss-page")
                Button { advance(1, team: team) } label: { Image(systemName: "chevron.right") }
                    .frame(width: 28, height: 28).disabled(index == team.pokemon.count - 1)
                    .accessibilityLabel("Next Pokémon").accessibilityIdentifier("bound.boss-next")
                Spacer()
                Button { showingTeam = true } label: {
                    Label("Full team", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                }.accessibilityIdentifier("bound.boss-full-team")
            }
            .offset(y: floating ? 0 : 8)
        }
        .padding(12).background(Color(uiColor: .systemBackground))
    }

    private func enhancedCard(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, compact: Bool,
                              scrollsDetails: Bool = true) -> some View {
        let reference = BoundBossReference.bundled
        let detail = reference?.detail(for: pokemon, teamID: team.id, pokemonIndex: index)
        return VStack(alignment: .leading, spacing: compact ? 1 : 7) {
            HStack(spacing: 5) {
                BoundBossTrainerIcon(team: team, size: compact ? 30 : 38)
                Button { showingPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.name).font(.system(size: compact ? 14 : 17, weight: .bold)).lineLimit(1)
                        Text([team.location, team.variant].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Choose boss, \(team.name)")
                .accessibilityIdentifier("bound.boss-picker")
                if !usesIslandActions {
                    Button { showWeaknesses(pokemon, reference: .bundled) } label: {
                        Image(systemName: "shield.lefthalf.filled").frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                    }.accessibilityLabel("Show typing matchups")
                        .accessibilityIdentifier("bound.boss-weaknesses")
                }
                capBadge(team)
            }
            conditionBadges(team, compact: compact)
            teamStrip(team: team, selectedIndex: index, reference: reference, compact: compact)
            selectedPokemonSummary(pokemon: pokemon, detail: detail)
            let details = VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                moveGrid(pokemon: pokemon, detail: detail, compact: compact)
                BoundBossStats(stats: pokemon.stats)
            }
            Group {
                if scrollsDetails { ScrollView { details }.frame(maxHeight: .infinity) }
                else { details }
            }
            .accessibilityIdentifier("bound.boss-details")
            .id("\(team.id)-\(index)")
            navigationControls(team: team, index: index, compact: compact, includesFullTeam: !usesIslandActions)
        }
        .padding(compact ? 4 : 12)
        .background(Color(uiColor: .systemBackground))
    }

    private func fullHeightCard(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, width: CGFloat,
                                height: CGFloat) -> some View {
        let reference = BoundBossReference.bundled
        let detail = reference?.detail(for: pokemon, teamID: team.id, pokemonIndex: index)
        return VStack(alignment: .leading, spacing: 2) {
                if !usesIslandActions { islandActions(pokemon: pokemon, onIsland: false).frame(height: 44) }
                HStack(spacing: 7) {
                    BoundBossTrainerIcon(team: team, size: 30)
                    Button { showingPicker = true } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                            Text([team.location, team.variant].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Choose boss, \(team.name)")
                    .accessibilityIdentifier("bound.boss-picker")
                    capBadge(team)
                }
                conditionBadges(team, compact: true)
                teamStrip(team: team, selectedIndex: index, reference: reference, compact: true)
                selectedPokemonSummary(pokemon: pokemon, detail: detail)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        moveGrid(pokemon: pokemon, detail: detail, compact: true)
                        BoundBossStats(stats: pokemon.stats)
                    }
                }
                .accessibilityIdentifier("bound.boss-details")
                .id("\(team.id)-\(index)")
                .frame(maxHeight: .infinity)
                navigationControls(team: team, index: index, compact: true, includesFullTeam: false)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .frame(width: width, height: height, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    /// A more touch-friendly version of the full-height guide. The team strip is the
    /// primary Pokémon navigator; the arrows stay available for one-at-a-time review.
    /// Moves remain the first detail module, while stats can be opened on demand.
    private func layout4Card(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int, compact: Bool,
                             scrollsDetails: Bool, scrollsOverview: Bool = false) -> some View {
        let reference = BoundBossReference.bundled
        let detail = reference?.detail(for: pokemon, teamID: team.id, pokemonIndex: index)
        let overview = VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            HStack(spacing: 6) {
                BoundBossTrainerIcon(team: team, size: compact ? 30 : 34)
                Button { showingPicker = true } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name).font(.system(size: compact ? 14 : 16, weight: .bold)).lineLimit(1)
                        Text([team.location, team.variant].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Choose boss, \(team.name)")
                .accessibilityIdentifier("bound.boss-picker")
                capBadge(team)
            }
            conditionBadges(team, compact: true)
            layout4SelectedSummary(pokemon: pokemon, detail: detail, index: index, count: team.pokemon.count)
        }
        let details = VStack(alignment: .leading, spacing: 3) {
            moveGrid(pokemon: pokemon, detail: detail, compact: true)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showsLayout4Stats.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsLayout4Stats ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("Stats").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(showsLayout4Stats ? "Hide" : "Show").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsLayout4Stats ? "Hide Pokémon stats" : "Show Pokémon stats")
            .accessibilityIdentifier("bound.boss-layout4-stats-toggle")
            .accessibilityValue(showsLayout4Stats ? "Expanded" : "Collapsed")
            if showsLayout4Stats {
                BoundBossStats(stats: pokemon.stats)
                    .accessibilityIdentifier("bound.boss-layout4-stats")
            }
        }
        return VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            if !usesIslandActions {
                islandActions(pokemon: pokemon, onIsland: false).frame(height: 44)
            }
            if scrollsOverview {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        overview
                        details
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.boss-details")
                .id("layout4-\(team.id)-\(index)")
            } else {
                overview
                Group {
                    if scrollsDetails { ScrollView(.vertical) { details }.frame(maxHeight: .infinity) }
                    else { details }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.boss-details")
                .id("layout4-\(team.id)-\(index)")
            }
            layout4Navigation(team: team, index: index, reference: reference)
        }
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    private func layout4SelectedSummary(pokemon: BoundBossPokemon, detail: BoundBossReference.Detail?,
                                       index: Int, count: Int) -> some View {
        HStack(spacing: 5) {
            pokemonPicture(pokemon, species: detail?.species, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(pokemon.species).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                typeNames(detail?.types ?? [])
                HStack(spacing: 6) {
                    Text(pokemon.levelLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(index + 1) / \(count)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bound.boss-page")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            layout4TagButton(icon: "sparkles", name: pokemon.ability) {
                guard experimentsEnabled else { return }
                detailSheet = .ability(pokemon.ability, detail?.abilityDescription)
            }
            .accessibilityLabel("Ability: \(pokemon.ability). Show description")
            .accessibilityIdentifier("bound.boss-ability")
            layout4TagButton(icon: "shippingbox", name: pokemon.item) {
                guard experimentsEnabled else { return }
                detailSheet = .item(pokemon.item, detail?.itemDescription)
            }
            .accessibilityLabel("Held item: \(pokemon.item). Show description")
            .accessibilityIdentifier("bound.boss-item")
        }
        .frame(minHeight: 48)
    }

    private func layout4TagButton(icon: String, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 11))
                Text(name).font(.system(size: 10, weight: .medium)).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(width: 64, height: 44)
            .contentShape(Rectangle())
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func layout4Navigation(team: BoundBossTeam, index: Int, reference: BoundBossReference?) -> some View {
        HStack(spacing: 4) {
            Button { advance(-1, team: team) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous Pokémon")
            .accessibilityIdentifier("bound.boss-previous")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(team.pokemon.enumerated()), id: \.offset) { memberIndex, member in
                            let species = reference?.detail(for: member, teamID: team.id, pokemonIndex: memberIndex).species
                            Button {
                                if let catalog {
                                    choose(BoundBossGuideSelection(teamID: team.id, pokemonIndex: memberIndex), catalog: catalog)
                                }
                            } label: {
                                pokemonPicture(member, species: species, size: 28)
                                    .frame(width: 50, height: 44)
                                    .background(memberIndex == index ? Color(uiColor: .deltaPurple).opacity(0.20) : Color(uiColor: .tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(memberIndex == index ? Color(uiColor: .deltaPurple) : .clear, lineWidth: 1.5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(member.species), team member \(memberIndex + 1) of \(team.pokemon.count)")
                            .accessibilityIdentifier("bound.boss-team-member-\(memberIndex)")
                            .accessibilityAddTraits(memberIndex == index ? .isSelected : [])
                            .id(memberIndex)
                        }
                    }.padding(.vertical, 1)
                }
                .onAppear { proxy.scrollTo(index, anchor: .center) }
                .onChange(of: index) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }.id(team.id)
            Button { advance(1, team: team) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(index == team.pokemon.count - 1)
            .accessibilityLabel("Next Pokémon")
            .accessibilityIdentifier("bound.boss-next")
            Spacer(minLength: 0)
        }
        .frame(height: 46)
    }

    private func capBadge(_ team: BoundBossTeam) -> some View {
        Group {
            if let cap = team.levelCap {
                Text("Cap \(cap)").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(uiColor: .deltaPurple).opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("bound.boss-cap")
            }
        }
    }

    private func conditionBadges(_ team: BoundBossTeam, compact: Bool) -> some View {
        let badges = team.battleConditionBadges
        return Group {
            if !badges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(badges.reduce(into: [String]()) { result, badge in
                            if !result.contains(badge) { result.append(badge) }
                        }, id: \.self) { badge in
                            Text(badge).font(.system(size: compact ? 9 : 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.17), in: Capsule())
                                .accessibilityIdentifier("bound.boss-condition-\(badge.lowercased().replacingOccurrences(of: " ", with: "-"))")
                        }
                    }
                }.frame(height: compact ? 18 : 20).accessibilityLabel("Battle conditions")
            }
        }
    }

    private func teamStrip(team: BoundBossTeam, selectedIndex: Int, reference: BoundBossReference?,
                           compact: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(team.pokemon.enumerated()), id: \.offset) { index, member in
                    let species = reference?.detail(for: member, teamID: team.id, pokemonIndex: index).species
                    Button {
                        if let catalog {
                            choose(BoundBossGuideSelection(teamID: team.id, pokemonIndex: index), catalog: catalog)
                        }
                    } label: {
                        VStack(spacing: 1) {
                            pokemonPicture(member, species: species, size: compact ? 30 : 36)
                            if !compact {
                                Text(member.species).font(.system(size: 7, weight: index == selectedIndex ? .bold : .regular))
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                        }
                        .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
                        .background(index == selectedIndex ? Color(uiColor: .deltaPurple).opacity(0.23) : Color(uiColor: .tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(index == selectedIndex ? Color(uiColor: .deltaPurple) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(member.species), team member \(index + 1) of \(team.pokemon.count)")
                    .accessibilityIdentifier("bound.boss-team-member-\(index)")
                    .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                }
            }.padding(.vertical, compact ? 1 : 2)
        }.frame(height: compact ? 38 : 52)
    }

    @ViewBuilder private func pokemonPicture(_ pokemon: BoundBossPokemon, species: BoundRRDexSpecies?, size: CGFloat) -> some View {
        if let sprite = species?.sprite, let data = Data(base64Encoded: sprite), let picture = UIImage(data: data) {
            Image(uiImage: picture).resizable().interpolation(.none).scaledToFit()
                .frame(width: size, height: size).accessibilityLabel("\(pokemon.species) picture")
        } else {
            Image(systemName: "photo").resizable().scaledToFit().frame(width: size * 0.6, height: size * 0.6)
                .foregroundStyle(.secondary).accessibilityLabel("\(pokemon.species) picture unavailable")
        }
    }

    private func typeNames(_ types: [BoundRRDexType]) -> some View {
        HStack(spacing: 4) {
            ForEach(types) { type in
                Text(type.name).font(.system(size: 9, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("bound.boss-types")
    }

    private func selectedPokemonSummary(pokemon: BoundBossPokemon, detail: BoundBossReference.Detail?) -> some View {
        HStack(spacing: 6) {
            pokemonPicture(pokemon, species: detail?.species, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(pokemon.species).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier("bound.boss-pokemon")
                typeNames(detail?.types ?? [])
                Text(pokemon.levelLabel).font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button {
                    guard experimentsEnabled else { return }
                    detailSheet = .ability(pokemon.ability, detail?.abilityDescription)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "sparkles")
                        Text(pokemon.ability).lineLimit(2).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Ability: \(pokemon.ability). Show description")
                .accessibilityIdentifier("bound.boss-ability")
                Button {
                    guard experimentsEnabled else { return }
                    detailSheet = .item(pokemon.item, detail?.itemDescription)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "shippingbox")
                        Text(pokemon.item).lineLimit(2).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Held item: \(pokemon.item). Show description")
                .accessibilityIdentifier("bound.boss-item")
            }
            .buttonStyle(.plain).font(.system(size: 9, weight: .medium))
            .frame(maxWidth: 170)
            .padding(.horizontal, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func moveGrid(pokemon: BoundBossPokemon, detail: BoundBossReference.Detail?, compact: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 3 : 5) {
            ForEach(Array(pokemon.moves.enumerated()), id: \.offset) { index, move in
                BoundBossMoveRow(name: move, type: detail?.moves[index].type,
                                 category: detail?.moves[index].categoryLabel ?? "—", index: index, compact: compact)
            }
        }
    }

    private func navigationControls(team: BoundBossTeam, index: Int, compact: Bool,
                                    includesFullTeam: Bool = true) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Button { advance(-1, team: team) } label: { Image(systemName: "chevron.left") }
                .frame(width: 30, height: 30).disabled(index == 0)
                .accessibilityLabel("Previous Pokémon").accessibilityIdentifier("bound.boss-previous")
            Text("\(index + 1) / \(team.pokemon.count)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).accessibilityIdentifier("bound.boss-page")
            Button { advance(1, team: team) } label: { Image(systemName: "chevron.right") }
                .frame(width: 30, height: 30).disabled(index == team.pokemon.count - 1)
                .accessibilityLabel("Next Pokémon").accessibilityIdentifier("bound.boss-next")
            Spacer()
            if includesFullTeam {
                Button { showingTeam = true } label: {
                    Label("Full team", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .medium))
                }.accessibilityIdentifier("bound.boss-full-team")
            }
        }
        .offset(y: floating || compact ? 0 : 8)
    }

    private func showWeaknesses(_ pokemon: BoundBossPokemon, reference: BoundBossReference?) {
        guard experimentsEnabled, let species = reference?.detail(for: pokemon).species,
              let dex = BoundRRDexCatalog.bundled else { return }
        detailSheet = .weaknesses(species, dex)
    }

    private func islandActions(pokemon: BoundBossPokemon, onIsland: Bool) -> some View {
        HStack(spacing: 0) {
            Button { showWeaknesses(pokemon, reference: .bundled) } label: {
                Label("Weaknesses", systemImage: "shield.lefthalf.filled")
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity).frame(height: 44)
            }
            .accessibilityLabel("Typing matchups, including 4× weaknesses and immunities")
            .accessibilityIdentifier("bound.boss-weaknesses")
            if onIsland { Spacer().frame(width: 160) }
            Button { showingTeam = true } label: {
                Label("Full team", systemImage: "person.3")
                    .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).frame(height: 44)
            }
            .accessibilityIdentifier("bound.boss-full-team")
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func choose(_ next: BoundBossGuideSelection, catalog: BoundBossCatalog) {
        guard experimentsEnabled else { return }
        showsLayout4Stats = false
        selection = next.resolved(in: catalog)
        preferences.write(selection, gameID: gameID, catalog: catalog)
    }
    private func advance(_ direction: Int, team: BoundBossTeam) {
        guard let catalog else { return }
        choose(BoundBossGuideSelection(teamID: team.id, pokemonIndex: selection.pokemonIndex + direction), catalog: catalog)
    }
}

private struct BoundBossTextDetail: View {
    let title: String
    let name: String
    let description: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(name).font(.title2.bold())
                    Text(description ?? "Description unavailable for this entry.")
                        .font(.body).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
    }
}

private struct BoundBossWeaknessDetail: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    var body: some View {
        NavigationStack {
            BoundRRDexMatchups(pokemon: pokemon, catalog: catalog, highlightsExtremes: true)
                .navigationTitle("Type matchups")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
    }
}

private struct BoundBossPokemonIdentity: View {
    let pokemon: BoundBossPokemon
    let species: BoundRRDexSpecies?
    let types: [BoundRRDexType]

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let sprite = species?.sprite, let data = Data(base64Encoded: sprite), let picture = UIImage(data: data) {
                    Image(uiImage: picture).resizable().interpolation(.none).scaledToFit()
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }.frame(width: 46, height: 46)
                .accessibilityLabel("\(pokemon.species) picture").accessibilityIdentifier("bound.boss-picture")
            VStack(alignment: .leading, spacing: 4) {
                Text(pokemon.species).font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier("bound.boss-pokemon")
                HStack(spacing: 6) {
                    ForEach(types) { type in
                        HStack(spacing: 3) {
                            BoundBossTypeIcon(type: type).frame(width: 13, height: 13).accessibilityHidden(true)
                            Text(type.name).font(.system(size: 10, weight: .medium))
                        }
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel("Pokémon types")
                    .accessibilityValue(types.map(\.name).joined(separator: ", "))
                    .accessibilityIdentifier("bound.boss-types")
            }
            Spacer(minLength: 4)
            Text(pokemon.levelLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct BoundBossStats: View {
    let stats: [BoundBossPokemon.Stat]
    private static let labels: [String: (short: String, full: String)] = [
        "HP": ("HP", "HP"), "ATK": ("Atk", "Attack"), "DEF": ("Def", "Defense"),
        "SPA": ("SpAtk", "Special Attack"), "SPD": ("SpDef", "Special Defense"), "SPE": ("Speed", "Speed")
    ]

    var body: some View {
        HStack(spacing: 0) {
            Text("Base stats").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            ForEach(stats, id: \.name) { stat in
                let label = Self.labels[stat.name] ?? (short: stat.name, full: stat.name)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text(label.short).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Text(stat.base.map(String.init) ?? "—")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label.full)
                .accessibilityValue(stat.base.map(String.init) ?? "Unavailable")
                .accessibilityIdentifier("bound.boss-stat-\(stat.name.lowercased())")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("bound.boss-stats")
    }
}

private struct BoundBossTypeIcon: View {
    let type: BoundRRDexType
    var body: some View {
        Group {
            if let data = BoundBossReference.bundled?.typeIconData(for: type), let icon = UIImage(data: data) {
                Image(uiImage: icon).resizable().scaledToFit()
            } else {
                Text(type.name).font(.system(size: 8, weight: .medium)).minimumScaleFactor(0.6)
            }
        }.accessibilityLabel(type.name)
    }
}

private struct BoundBossMoveRow: View {
    let name: String
    let type: BoundRRDexType?
    let category: String
    let index: Int
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            if let type {
                BoundBossTypeIcon(type: type).frame(width: 15, height: 15)
                    .accessibilityIdentifier("bound.boss-move-type-\(index)")
            }
            Text(name == "-" ? "—" : name).font(.system(size: 11))
                .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("bound.boss-move-\(index)")
            Text(category).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                .accessibilityIdentifier("bound.boss-move-category-\(index)")
        }
        .padding(.horizontal, 7).padding(.vertical, compact ? 3 : 7)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct BoundBossDescription: View {
    let title: String
    let name: String
    let description: String?
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) · \(name)").font(.system(size: 11, weight: .semibold))
            Text(description ?? "Description unavailable for this entry.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoundBossPicker: View {
    let catalog: BoundBossCatalog
    let selectedID: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @State private var query = ""
    @State private var category: String?
    @State private var expandedEncounters: Set<String> = []
    var body: some View {
        NavigationStack {
            List {
                Picker("Category", selection: $category) {
                    Text("All bosses").tag(nil as String?)
                    ForEach(catalog.categories, id: \.self) { Text($0).tag(Optional($0)) }
                }.listRowBackground(Color.black)
                ForEach(catalog.encounters(matching: query, category: category)) { encounter in
                    if encounter.teams.count > 1 {
                        DisclosureGroup(isExpanded: Binding(get: { expandedEncounters.contains(encounter.id) }, set: { expanded in
                            if expanded { expandedEncounters.insert(encounter.id) }
                            else { expandedEncounters.remove(encounter.id) }
                        })) {
                            ForEach(encounter.teams) { team in
                                selectionButton(team, title: encounter.optionTitle(for: team), subtitle: team.name)
                            }
                        } label: {
                            pickerRow(encounter.primary, title: encounter.primary.name, subtitle: encounter.primary.location,
                                      detail: "\(encounter.primary.category) · \(encounter.teams.count) options",
                                      selected: encounter.teams.contains { $0.id == selectedID },
                                      showsCap: encounter.teams.allSatisfy { $0.levelCap == encounter.primary.levelCap })
                                .accessibilityIdentifier("bound.boss-options-\(encounter.id)")
                        }
                        .listRowBackground(Color.black)
                    } else {
                        selectionButton(encounter.primary, title: encounter.primary.name, subtitle: encounter.primary.subtitle)
                            .listRowBackground(Color.black)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundStyle(.white)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Boss, location, or Pokémon")
            .navigationTitle("Choose boss")
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { BoundBossGuideInfo(catalog: catalog) } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Guide information")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .onAppear {
            if let current = catalog.encounters(matching: "").first(where: { $0.teams.count > 1 && $0.teams.contains { $0.id == selectedID } }) {
                expandedEncounters.insert(current.id)
            }
        }
        .onChange(of: query) { _, text in
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                expandedEncounters.formUnion(catalog.encounters(matching: text, category: category).filter { $0.teams.count > 1 }.map(\.id))
            }
        }
        .onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
    }
    private func selectionButton(_ team: BoundBossTeam, title: String, subtitle: String) -> some View {
        Button {
            guard experimentsEnabled else { return }
            choose(team.id); dismiss()
        } label: {
            pickerRow(team, title: title, subtitle: subtitle, detail: "\(team.category) · \(team.pokemon.count) Pokémon", selected: team.id == selectedID)
        }
        .accessibilityIdentifier("bound.boss-select-\(team.id)")
        .listRowBackground(Color.black)
    }
    private func pickerRow(_ team: BoundBossTeam, title: String, subtitle: String, detail: String, selected: Bool, showsCap: Bool = true) -> some View {
        HStack(spacing: 12) {
            BoundBossTrainerIcon(team: team)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !subtitle.isEmpty { Text(subtitle).font(.caption) }
                Text(detail).font(.caption2)
            }
            Spacer(minLength: 4)
            if selected { Image(systemName: "checkmark") }
            if showsCap, let cap = team.levelCap { Text("Cap \(cap)").font(.caption).fixedSize() }
        }.foregroundStyle(.white)
    }
}

private struct BoundBossTrainerIcon: View {
    let team: BoundBossTeam
    var size: CGFloat = 48
    var body: some View {
        let pictures = BoundBossReference.bundled?.trainerIconData(for: team).compactMap { UIImage(data: $0) } ?? []
        HStack(spacing: -size / 6) {
            if pictures.isEmpty {
                Image(systemName: "person.crop.square.fill").font(.system(size: size * 0.625))
            } else {
                ForEach(pictures.indices, id: \.self) { index in
                    Image(uiImage: pictures[index]).resizable().interpolation(.none).scaledToFit()
                        .frame(width: size * (pictures.count > 1 ? 28 : 44) / 48, height: size * 44 / 48)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(team.name) trainer icon")
        .accessibilityIdentifier("bound.boss-trainer-icon-\(team.id)")
    }
}

private struct BoundBossTeamView: View {
    let catalog: BoundBossCatalog
    let team: BoundBossTeam
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Radical Red 4.1 · Default").foregroundStyle(.secondary)
                    Text(team.subtitle)
                    if let cap = team.levelCap { LabeledContent("Earliest level cap", value: String(cap)) }
                    ForEach(Array(team.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.callout) }
                }
                ForEach(Array(team.pokemon.enumerated()), id: \.offset) { index, pokemon in
                    Section("\(index + 1). \(pokemon.species)") {
                        LabeledContent("Level", value: pokemon.level)
                        LabeledContent("Nature", value: pokemon.nature)
                        LabeledContent("Ability", value: pokemon.ability)
                        LabeledContent("Item", value: pokemon.item)
                        ForEach(Array(pokemon.moves.enumerated()), id: \.offset) { _, move in
                            Text(move == "-" ? "—" : move)
                        }
                        DisclosureGroup("Base stats, EVs, and speed") {
                            ForEach(pokemon.stats, id: \.name) { stat in
                                LabeledContent(stat.name, value: "Base \(stat.base.map(String.init) ?? "—") · \(stat.ev) EVs")
                            }
                            ForEach(Array(pokemon.speed.enumerated()), id: \.offset) { _, speed in
                                LabeledContent(speed.label, value: speed.value)
                            }
                        }
                    }
                }
                NavigationLink("Level caps and source") { BoundBossGuideInfo(catalog: catalog) }
            }
            .accessibilityIdentifier("bound.boss-full-team-list")
            .navigationTitle(team.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("bound.boss-close-full-team")
            } }
        }.onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
    }
}

private struct BoundBossGuideInfo: View {
    let catalog: BoundBossCatalog
    var body: some View {
        List {
            Section("Guide") {
                Text("Radical Red 4.1 · Default difficulty")
                Text("\(catalog.teams.count) team variants · \(catalog.teams.reduce(0) { $0 + $1.pokemon.count }) Pokémon")
                Text("Choose your fight manually. This guide does not read your ROM or save to detect progress.")
                Text("Caps come from the source's trainer order and represent the earliest cap for that fight. Scaling level rules are preserved as listed.")
                Text("The source's speed figures use the example level beside each stat table; postgame figures assume level 100.")
                Text("In Minimal Grinding Mode, opponents lose their EVs, except Ghost Marowak's 252 HP EVs. These teams list the Default-mode EVs from the source.")
                Text("For the rival's Squirtle team, the player chose a Fire-type starter. Gyro Ball and Trick Room teams generally use zero Speed IVs in the source.")
                Text("After becoming Champion, non-postgame scaling trainers gain two levels.")
            }
            Section("Level caps") {
                ForEach(catalog.levelCaps, id: \.stage) { LabeledContent($0.stage, value: String($0.level)) }
            }
            Section("Trainer order") {
                ForEach(Array(catalog.trainerOrder.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(entry.location).font(.caption).foregroundStyle(.secondary)
                        if let cap = entry.levelCap { Text("Cap \(cap)").font(.caption) }
                        if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Source") {
                Link(catalog.sourceTitle, destination: catalog.sourceURL)
                Link("Pokémon and moves · Radical Red Pokédex", destination: URL(string: "https://dex.radicalred.net/")!)
                Link("Type icons · PokeSprite", destination: URL(string: "https://github.com/msikma/pokesprite")!)
                Link("Trainer icons · Pokémon Showdown", destination: URL(string: "https://play.pokemonshowdown.com/sprites/trainers/")!)
                Text("Bundled for offline use. Check the original documentation for corrections.").font(.footnote)
                Text("Boss teams use the Default guide, independently of any save imported into the Dex.").font(.footnote)
                Text("Pokémon characters and artwork belong to their respective owners.").font(.footnote)
            }
        }.navigationTitle("Guide information")
    }
}

import SwiftUI
import UIKit

struct BoundBossGuideView: View {
    let gameID: String
    var floating = false
    let presentationChanged: (Bool) -> Void
    private let catalog = BoundBossCatalog.bundled
    private let preferences = BoundBossGuidePreferences()
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @State private var selection = BoundBossGuideSelection(teamID: "kanto-leaders-4", pokemonIndex: 0)
    @State private var showingPicker = false
    @State private var showingTeam = false

    var body: some View {
        Group {
            if experimentsEnabled, let catalog {
                let selected = selection.resolved(in: catalog)
                let team = catalog.team(id: selected.teamID) ?? catalog.defaultTeam
                let pokemon = team.pokemon[selected.pokemonIndex]
                GeometryReader { geometry in
                    if floating {
                        let scale = min(geometry.size.width / 360, geometry.size.height / 260)
                        card(team: team, pokemon: pokemon, index: selected.pokemonIndex)
                            .frame(width: geometry.size.width / max(scale, 0.001), height: 260)
                            .scaleEffect(scale)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else if geometry.size.height < 140 {
                        // Short portrait strips scroll the controls with the details.
                        ScrollView {
                            card(team: team, pokemon: pokemon, index: selected.pokemonIndex, scrollsDetails: false)
                                .frame(width: geometry.size.width)
                        }
                    } else {
                        card(team: team, pokemon: pokemon, index: selected.pokemonIndex)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bound.boss-guide")
                .onAppear { selection = preferences.read(gameID: gameID, catalog: catalog) }
                .sheet(isPresented: $showingPicker, onDismiss: presentationDismissed) {
                    BoundBossPicker(catalog: catalog, selectedID: selected.teamID) { id in
                        choose(BoundBossGuideSelection(teamID: id, pokemonIndex: 0), catalog: catalog)
                    }
                }
                .sheet(isPresented: $showingTeam, onDismiss: presentationDismissed) {
                    BoundBossTeamView(catalog: catalog, team: team)
                }
            } else if experimentsEnabled {
                ContentUnavailableView("Boss guide unavailable", systemImage: "book.closed",
                                       description: Text("The bundled guide could not be loaded."))
            }
        }
        .tint(Color(uiColor: .deltaPurple))
        .onChange(of: experimentsEnabled) { _, enabled in
            if !enabled { showingPicker = false; showingTeam = false }
        }
        .onChange(of: showingPicker || showingTeam) { _, presented in
            if presented { presentationChanged(true) }
        }
    }

    private func presentationDismissed() {
        // The binding changes before UIKit finishes dismissing, while resuming is still blocked.
        guard !showingPicker && !showingTeam else { return }
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

    private func choose(_ next: BoundBossGuideSelection, catalog: BoundBossCatalog) {
        guard experimentsEnabled else { return }
        selection = next.resolved(in: catalog)
        preferences.write(selection, gameID: gameID, catalog: catalog)
    }
    private func advance(_ direction: Int, team: BoundBossTeam) {
        guard let catalog else { return }
        choose(BoundBossGuideSelection(teamID: team.id, pokemonIndex: selection.pokemonIndex + direction), catalog: catalog)
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
        .padding(.horizontal, 7).padding(.vertical, 7)
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
    var body: some View {
        let pictures = BoundBossReference.bundled?.trainerIconData(for: team).compactMap { UIImage(data: $0) } ?? []
        HStack(spacing: -8) {
            if pictures.isEmpty {
                Image(systemName: "person.crop.square.fill").font(.system(size: 30))
            } else {
                ForEach(pictures.indices, id: \.self) { index in
                    Image(uiImage: pictures[index]).resizable().interpolation(.none).scaledToFit()
                        .frame(width: pictures.count > 1 ? 28 : 44, height: 44)
                }
            }
        }
        .frame(width: 48, height: 48)
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

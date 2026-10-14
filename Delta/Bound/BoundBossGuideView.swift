import SwiftUI
import UIKit

struct BoundBossGuideView: View {
    let gameID: String
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
                    let scale = min(geometry.size.width / 360, geometry.size.height / 260)
                    card(team: team, pokemon: pokemon, index: selected.pokemonIndex)
                        .frame(width: 360, height: 260)
                        .scaleEffect(scale)
                        .frame(width: geometry.size.width, height: geometry.size.height)
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

    private func card(team: BoundBossTeam, pokemon: BoundBossPokemon, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            HStack(alignment: .firstTextBaseline) {
                Text(pokemon.species).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    .accessibilityIdentifier("bound.boss-pokemon")
                Spacer()
                Text(pokemon.levelLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Ability · \(pokemon.ability)").foregroundStyle(.secondary)
                Text("Item · \(pokemon.item)")
            }.font(.system(size: 12)).lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(Array(pokemon.moves.enumerated()), id: \.offset) { index, move in
                    Text(move == "-" ? "—" : move).font(.system(size: 12))
                        .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("bound.boss-move-\(index)")
                }
            }
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

private struct BoundBossPicker: View {
    let catalog: BoundBossCatalog
    let selectedID: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @State private var query = ""
    @State private var category: String?
    var body: some View {
        NavigationStack {
            List {
                Picker("Category", selection: $category) {
                    Text("All bosses").tag(nil as String?)
                    ForEach(catalog.categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                ForEach(catalog.teams(matching: query, category: category)) { team in
                    Button {
                        guard experimentsEnabled else { return }
                        choose(team.id); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(team.name).foregroundStyle(.primary).font(.headline)
                                Text(team.subtitle).foregroundStyle(.secondary).font(.caption)
                                Text("\(team.category) · \(team.pokemon.count) Pokémon")
                                    .foregroundStyle(.secondary).font(.caption2)
                            }
                            Spacer()
                            if team.id == selectedID { Image(systemName: "checkmark") }
                            if let cap = team.levelCap { Text("Cap \(cap)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("bound.boss-select-\(team.id)")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Boss, location, or Pokémon")
            .navigationTitle("Choose boss")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { BoundBossGuideInfo(catalog: catalog) } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Guide information")
                }
            }
        }.onChange(of: experimentsEnabled) { _, enabled in if !enabled { dismiss() } }
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
                Text("Bundled for offline use. Check the original documentation for corrections.").font(.footnote)
            }
        }.navigationTitle("Guide information")
    }
}

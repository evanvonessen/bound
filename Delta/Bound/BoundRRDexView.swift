import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct BoundRRDexView: View {
    let gameID: String
    let presentationChanged: (Bool) -> Void
    private let catalog = BoundRRDexCatalog.bundled
    private let preferences = BoundRRDexPreferences()
    @AppStorage(BoundExperimentalFeaturesPreferences.enabledKey) private var experimentsEnabled = false
    @State private var choice = BoundRRDexPreferences.Choice()
    @State private var query = ""
    // UIKit owns focus; a SwiftUI FocusState without a .focused view resets it.
    @State private var searching = false
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var sheet: Detail?
    private enum Detail: String, Identifiable { case weaknesses, learnset, information; var id: String { rawValue } }
    private var interacting: Bool { searching || showingImporter || sheet != nil || importError != nil }

    var body: some View {
        Group {
            if experimentsEnabled, let catalog, let pokemon = catalog.pokemon(id: choice.speciesID) ?? catalog.species.first {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / 360, geometry.size.height / 300)
                    card(pokemon: pokemon, catalog: catalog)
                        .frame(width: 360, height: 300).scaleEffect(scale)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("bound.rrdex")
                .onAppear { choice = preferences.read(gameID: gameID) }
                .sheet(item: $sheet) { detail in
                    BoundRRDexDetail(title: detail == .weaknesses ? "Type matchups" : detail == .learnset ? "Learnset" : "RRDex") {
                        switch detail {
                        case .weaknesses: BoundRRDexMatchups(pokemon: pokemon, catalog: catalog)
                        case .learnset: BoundRRDexLearnset(pokemon: pokemon, catalog: catalog, save: choice.save)
                        case .information: information(catalog: catalog)
                        }
                    }
                }
            } else if experimentsEnabled {
                ContentUnavailableView("RRDex unavailable", systemImage: "book.closed", description: Text("The bundled dex could not be loaded."))
            }
        }
        .tint(Color(uiColor: .deltaPurple))
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in importSave(result) }
        .alert("Save could not be imported", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .onChange(of: interacting) { _, active in presentationChanged(active) }
        .onChange(of: experimentsEnabled) { _, enabled in
            if !enabled { searching = false; showingImporter = false; sheet = nil; importError = nil }
        }
        .onDisappear { searching = false; showingImporter = false; sheet = nil; presentationChanged(false) }
    }

    private func card(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("RR 4.1 · NORMAL").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard experimentsEnabled else { return }; searching = false; showingImporter = true
                } label: { Label(choice.save == nil ? "Import save" : "Save loaded", systemImage: choice.save == nil ? "square.and.arrow.down" : "checkmark.circle") }
                    .font(.system(size: 11, weight: .medium)).accessibilityIdentifier("bound.rrdex-import")
                Button { searching = false; sheet = .information } label: { Image(systemName: "info.circle") }
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
                suggestions(catalog: catalog).frame(maxHeight: .infinity)
            } else {
                ScrollView {
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
                }.scrollDismissesKeyboard(.interactively)
                HStack(spacing: 8) {
                    detailButton("Weaknesses", icon: "shield.lefthalf.filled", detail: .weaknesses)
                    detailButton("Learnset", icon: "list.bullet.rectangle", detail: .learnset)
                }
            }
        }.padding(12).background(Color(uiColor: .systemBackground))
    }

    private func detailButton(_ title: String, icon: String, detail: Detail) -> some View {
        Button {
            guard experimentsEnabled else { return }; searching = false; sheet = detail
        } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Color(uiColor: .deltaPurple).opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        }.accessibilityIdentifier("bound.rrdex-\(detail.rawValue)")
    }
    private func suggestions(catalog: BoundRRDexCatalog) -> some View {
        let results = catalog.suggestions(query)
        return ScrollView {
            LazyVStack(spacing: 0) {
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
        }.accessibilityIdentifier("bound.rrdex-suggestions")
    }
    private func evolutionLine(pokemon: BoundRRDexSpecies, catalog: BoundRRDexCatalog) -> some View {
        let links = catalog.evolutionLine(for: pokemon)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("EVOLUTION").font(.system(size: 9, weight: .medium, design: .monospaced))
                Spacer()
                Text("BST \(pokemon.stats.reduce(0, +))").font(.system(size: 9, design: .monospaced))
            }.foregroundStyle(.secondary)
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
    private func select(_ pokemon: BoundRRDexSpecies) {
        guard experimentsEnabled else { return }
        choice.speciesID = pokemon.id; query = ""; searching = false
        preferences.write(choice, gameID: gameID)
    }
    private func importSave(_ result: Result<URL, Error>) {
        guard experimentsEnabled else { return }
        do {
            let url = try result.get()
            guard ["sav", "srm"].contains(url.pathExtension.lowercased()) else { throw BoundRRDexSave.ImportError.format }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 0x20000 else { throw BoundRRDexSave.ImportError.format }
            choice.save = try BoundRRDexSave.parse(Data(contentsOf: url))
            preferences.write(choice, gameID: gameID)
        } catch CocoaError.userCancelled { } catch { importError = error.localizedDescription }
    }
    private func information(catalog: BoundRRDexCatalog) -> some View {
        List {
            Section("Save") {
                Text(choice.save?.summary ?? "Browsing the standard Normal dex")
                Text("Import a Radical Red 4.1 Normal battery save (.sav or .srm) to match randomized abilities and level-up moves. Save in-game before exporting. Import again when you start a new run.")
                Text("Your save stays on this device. Bound keeps only the randomizer seed and settings for this ROM; it never changes your game save.")
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
private struct BoundRRDexMatchups: View {
    let pokemon: BoundRRDexSpecies
    let catalog: BoundRRDexCatalog
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
                        HStack { BoundRRDexTypePill(type: entry.type); Spacer(); Text(entry.label).monospacedDigit() }
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

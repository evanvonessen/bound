import SwiftUI

struct BoundServerBackupView: View {
    @ObservedObject private var manager = BoundServerBackupManager.shared
    @State private var restoring: BoundServerBackupManager.Save?

    var body: some View {
        Form {
            Section {
                if !manager.statusText.isEmpty {
                    Text(manager.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                if manager.busy { ProgressView() }
                Button("Back Up Now") { Task { await manager.backupNow() } }
                    .disabled(manager.busy || !manager.approved || manager.provider != .server)
            }
            if manager.approved, manager.provider == .server {
                Section("Saved Games") {
                    if manager.saves.isEmpty {
                        Text("No server backups").foregroundStyle(.secondary)
                    }
                    ForEach(manager.saves) { save in
                        Button {
                            restoring = save
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(save.name)
                                    if let date = modificationDate(save.modifiedAt) {
                                        Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .disabled(manager.busy)
                    }
                }
            }
        }
        .navigationTitle("Server Backups")
        .task { await manager.refresh() }
        .refreshable { await manager.refresh() }
        .alert(item: $restoring) { save in
            Alert(title: Text("Restore \(save.name)?"),
                  message: Text("Close the game first. Matching local saves will be replaced; originals are kept on this device."),
                  primaryButton: .destructive(Text("Restore")) { Task { await manager.restore(save) } },
                  secondaryButton: .cancel())
        }
    }

    private func modificationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

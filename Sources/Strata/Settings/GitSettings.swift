import SwiftUI
import StrataDev

/// The repositories whose hooks and filters Strata may run, each one revocable.
struct GitSettings: View {
    private let trust = GitTrust(defaults: Prefs.shared.defaults, notifications: Prefs.shared.notifications)
    @State private var entries: [GitTrust.Entry] = []

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("No repository is trusted yet. Strata only reads repositories until you trust one from its git status.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.path) { entry in
                    HStack {
                        Text(verbatim: entry.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Revoke") {
                            trust.revoke(path: entry.path)
                            entries = trust.entries
                        }
                        .accessibilityLabel(Text("Revoke trust in \(entry.path)"))
                    }
                }
            } header: {
                Text("Trusted repositories")
            } footer: {
                Text("Git runs a trusted repository’s own hooks and filters when Strata stages, commits or changes it. Revoking makes it read only again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onAppear { entries = trust.entries }
    }
}

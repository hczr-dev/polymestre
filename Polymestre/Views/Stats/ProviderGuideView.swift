import SwiftUI

/// Notice de configuration d'un fournisseur de tâches.
///
/// Objectif : qu'un étudiant qui n'a jamais entendu parler d'un « jeton d'API »
/// puisse brancher son outil sans quitter l'app pour chercher la procédure.
struct ProviderGuideView: View {
    let provider: TaskProvider

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    summary
                    steps
                    if let warning = provider.setupCaveat {
                        caveatCard(warning)
                    }
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .carnetForm()
            .navigationTitle(provider.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { dismiss() }
                }
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(spacing: Layout.control) {
                    Image(systemName: provider.icon)
                        .font(.title3)
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 28)
                    Text(provider.label)
                        .font(.headline)
                    Spacer(minLength: Layout.inline)
                    Pill(text: provider.capabilityLabel,
                         color: provider.supportsReading ? .green : .orange)
                }

                Text(provider.setupSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        Card(title: String(localized: "Comment le brancher"), icon: "list.number") {
            VStack(alignment: .leading, spacing: Layout.cardGap) {
                ForEach(Array(provider.setupSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: Layout.block) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accentInk)
                            .frame(width: 20, alignment: .leading)
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Étape \(index + 1). \(step)")
                }

                if let urlString = provider.setupURLString, let url = URL(string: urlString) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Ouvrir la page des identifiants", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private func caveatCard(_ text: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: Layout.block) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange.accessibleMark)
                    .frame(width: 24)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

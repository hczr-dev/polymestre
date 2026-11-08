import SwiftUI
import SwiftData
import UIKit

/// Invitation : le code, un lien, et un QR code.
///
/// Trois façons parce qu'il y a trois situations : à côté de quelqu'un (QR), dans
/// une conversation (lien), ou au tableau en fin de cours (le code dicté).
struct GroupInviteView: View {
    let group: StudyGroup

    @Environment(\.dismiss) private var dismiss
    @State private var copiedField: String?
    @State private var shareItems: [Any] = []
    @State private var showingShare = false

    private var qrImage: UIImage? {
        QRCodeRenderer.image(from: group.inviteLink, scale: 12)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Layout.sectionGap) {
                    qrCard
                    codeCard
                    linkCard
                    shareButton
                    }
                .padding()
                .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .carnetBackground()
            .navigationTitle("Inviter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(items: shareItems)
            }
        }
    }

    // MARK: QR

    @ViewBuilder
    private var qrCard: some View {
        Card(title: String(localized: "À scanner"), icon: "qrcode") {
            VStack(spacing: Layout.block) {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .padding(Layout.block)
                        // Blanc en dur, et volontairement : un QR code inversé
                        // (clair sur sombre) n'est pas lu par tous les lecteurs.
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        // Un QR code est une image de service : VoiceOver n'a rien à
                        // en lire, le code et le lien juste en dessous suffisent.
                        .accessibilityHidden(true)
                } else {
                    Label("QR code indisponible sur cet appareil.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Code

    private var codeCard: some View {
        Card(title: String(localized: "Code d'invitation"), icon: "number") {
            HStack(spacing: Layout.block) {
                Text(group.inviteCode)
                    .font(.title3.weight(.bold).monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: Layout.inline)
                Button {
                    copy(group.inviteCode, field: "code")
                } label: {
                    Label(copiedField == "code" ? "Copié" : "Copier",
                          systemImage: copiedField == "code" ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Lien

    private var linkCard: some View {
        Card(title: "Lien", icon: "link") {
            VStack(alignment: .leading, spacing: Layout.block) {
                Text(group.inviteLink)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button {
                    copy(group.inviteLink, field: "lien")
                } label: {
                    Label(copiedField == "lien" ? "Copié" : "Copier le lien",
                          systemImage: copiedField == "lien" ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var shareButton: some View {
        Button {
            shareItems = [group.inviteMessage]
            showingShare = true
        } label: {
            Label("Partager l'invitation", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.carnetPrimary)
    }

    private func copy(_ value: String, field: String) {
        UIPasteboard.general.string = value
        copiedField = field
        Haptics.tap()
    }
}

/// Feuille de partage système (`UIActivityViewController`).
///
/// `ShareLink` ferait la même chose en une ligne, mais il faut pouvoir partager un
/// message **construit** (nom du groupe, matières, code, lien) — et lui faire
/// porter aussi le QR code en image serait la suite logique.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

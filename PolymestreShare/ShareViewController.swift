import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Extension de partage : « Partager › Polymestre » depuis Fichiers, Safari, Mail.
///
/// Elle ne fait qu'une chose — **prendre le PDF et le déposer** dans le conteneur
/// partagé — puis se referme. Analyser, c'est l'app qui le fait, avec son écran de
/// relecture : une extension n'a ni la place ni le temps de faire relire une série
/// à l'étudiant·e.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await handle() }
    }

    private func handle() async {
        let stored = await extract()
        await MainActor.run {
            let host = UIHostingController(rootView: ShareResultView(item: stored) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    /// Cherche un PDF, sinon du texte. Le premier trouvé gagne : une pièce jointe
    /// est plus précise qu'un corps de mail qui la décrit.
    private func extract() async -> PendingImport? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }

        for item in items {
            for attachment in item.attachments ?? [] {
                if attachment.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
                   let url = try? await attachment.loadItem(forTypeIdentifier: UTType.pdf.identifier)
                    as? URL,
                   let stored = copyIntoContainer(url) {
                    return stored
                }
            }
        }

        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                let payload = PendingImport(kind: .text, fileName: nil,
                                            text: text, receivedAt: Date())
                PendingImportBridge.store(payload)
                return payload
            }
            for attachment in item.attachments ?? [] {
                if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    let text: String?
                    if let string = value as? String { text = string }
                    else if let data = value as? Data { text = String(data: data, encoding: .utf8) }
                    else if let url = value as? URL { text = try? String(contentsOf: url, encoding: .utf8) }
                    else { text = nil }
                    if let text, !text.isEmpty {
                        let payload = PendingImport(kind: .text, fileName: nil,
                                                    text: text, receivedAt: Date())
                        PendingImportBridge.store(payload)
                        return payload
                    }
                }
            }
        }
        return nil
    }

    /// Copie le PDF dans le conteneur partagé : l'URL d'origine appartient à
    /// l'app qui partage et disparaît avec elle.
    private func copyIntoContainer(_ source: URL) -> PendingImport? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent.isEmpty ? "serie.pdf" : source.lastPathComponent
        guard let destination = PendingImportBridge.destinationURL(for: name) else { return nil }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        let payload = PendingImport(kind: .pdf, fileName: name, text: nil, receivedAt: Date())
        PendingImportBridge.store(payload)
        return payload
    }
}

/// Ce que voit l'utilisateur·trice après avoir partagé : une phrase, et la sortie.
struct ShareResultView: View {
    let item: PendingImport?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: item == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(item == nil ? Color.orange : Color.green)

            Text(item == nil ? "Rien à importer" : "Envoyé à Polymestre")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Fermer", action: dismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var message: String {
        guard let item else {
            return String(localized: "Aucun PDF ni texte n'a pu être lu dans ce partage.")
        }
        return String(localized: "\(item.displayName) t'attend dans Polymestre. Ouvre l'app : la relecture de la série s'affichera, et rien ne sera créé avant que tu valides.")
    }
}

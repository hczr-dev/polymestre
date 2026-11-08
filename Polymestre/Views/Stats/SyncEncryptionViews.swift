import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
import AVFoundation
#elseif canImport(AppKit)
import AppKit
#endif

// Le chiffrement de bout en bout de la synchronisation, dans Réglages — commun à l'iPhone et au Mac :
// activer, ajouter un appareil (code + QR), clé de secours, réinitialiser le coffre.
// Voir docs/sync-e2ee.md. La WebSocket d'appairage n'existe que pendant la feuille « Ajouter un
// appareil » ; la fermer la ferme.

private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// Le QR d'un texte, net (pas d'interpolation) et sur fond blanc quel que soit le thème.
struct SyncQRCodeView: View {
    let text: String
    var side: CGFloat = 176

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Text(ui: "QR code d'appairage"))
        }
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct SyncEncryptionPanel: View {
    let sync: SupabaseSync
    @State private var sheet: Sheet?
    @State private var busy = false
    @State private var error: String?

    enum Sheet: Identifiable {
        case recoveryCreated(String), confirmRecovery, showRecovery(String), pairHost, pairJoin, restore, reset
        var id: String {
            switch self {
            case .recoveryCreated: return "created"
            case .confirmRecovery: return "confirm"
            case .showRecovery: return "show"
            case .pairHost: return "host"
            case .pairJoin: return "join"
            case .restore: return "restore"
            case .reset: return "reset"
            }
        }
    }

    var body: some View {
        Group {
            Text(ui: "Tes données sont chiffrées sur tes appareils ; le serveur ne peut pas les lire. Il voit seulement quand une ligne change et combien il y en a.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Dans une liste, les modificateurs d'un Group se posent sur **chaque** ligne : la feuille
            // était présentée par plusieurs lignes à la fois et se refermait aussitôt. Une seule ligne la porte.
            .task { await sync.refreshVault() }
            .sheet(item: $sheet) { item in
                switch item {
                case .recoveryCreated(let key):
                    RecoveryKeySheet(keyText: key, title: String(localized: "Clé de secours"), done: String(localized: "J'ai noté la clé"))
                case .showRecovery(let key):
                    RecoveryKeySheet(keyText: key, title: String(localized: "Clé de secours"), done: "Masquer")
                case .confirmRecovery:
                    ConfirmSheet(title: String(localized: "Afficher la clé de secours ?"),
                                 message: String(localized: "Elle donne accès à toutes tes données chiffrées. Vérifie que personne ne regarde l'écran."),
                                 action: String(localized: "Afficher")) {
                        if let key = sync.recoveryKey() { sheet = .showRecovery(key) } else { sheet = nil; error = String(localized: "Cet appareil n'a pas la clé du compte.") }
                    }
                case .pairHost:
                    PairHostSheet(sync: sync)
                case .pairJoin:
                    CodeEntrySheet(title: "Entrer un code d'appairage", prompt: "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX", action: "Ajouter",
                                   hint: String(localized: "Sur un appareil déjà connecté : Réglages › Synchronisation › Ajouter un appareil. Saisis le code affiché, ou scanne le QR code."),
                                   scanner: true) { try await sync.joinPairing(code: $0) }
                case .restore:
                    CodeEntrySheet(title: "Utiliser la clé de secours", prompt: "XXXX-XXXX-…", action: "Restaurer",
                                   hint: String(localized: "La clé de secours de 54 caractères, montrée à l'activation du chiffrement."),
                                   scanner: false) { try await sync.restore(recoveryKey: $0) }
                case .reset:
                    ResetSheet(sync: sync) { key in sheet = .recoveryCreated(key) }
                }
            }

            switch sync.encryption {
            case .signedOut:
                EmptyView()
            case .unknown:
                Text(ui: "Lecture du coffre du compte…").font(.footnote).foregroundStyle(.secondary)
            case .noVault:
                Button { Task { await activate() } } label: {
                    Label { Text(ui: busy ? "Activation…" : "Activer la synchronisation chiffrée") } icon: { Image(systemName: "lock.shield") }
                }
                .disabled(busy)
            case .needsKey, .keyMismatch:
                Text(ui: "Ce compte est chiffré : ajoute cet appareil depuis un appareil déjà connecté.")
                    .font(.subheadline)
                if sync.pairingAvailable {
                    Button { sheet = .pairJoin } label: {
                        Label { Text(ui: "Entrer un code d'appairage") } icon: { Image(systemName: "keyboard") }
                    }
                }
                Button { sheet = .restore } label: {
                    Label { Text(ui: "Utiliser la clé de secours") } icon: { Image(systemName: "key") }
                }
            case .ready:
                if sync.pairingAvailable {
                    Button { sheet = .pairHost } label: {
                        Label { Text(ui: "Ajouter un appareil") } icon: { Image(systemName: "plus.rectangle.on.rectangle") }
                    }
                }
                Button { sheet = .confirmRecovery } label: {
                    Label { Text(ui: "Afficher la clé de secours") } icon: { Image(systemName: "key.horizontal") }
                }
            }

            if sync.encryption == .needsKey || sync.encryption == .keyMismatch || sync.encryption == .ready {
                Button(role: .destructive) { sheet = .reset } label: {
                    Label { Text(ui: "Réinitialiser le coffre") } icon: { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath") }
                }
            }
            if sync.skippedForeignKey > 0 {
                Text(String(format: Bundle.main.localizedString(forKey: "Clé différente : %d ligne(s) chiffrée(s) avec une autre clé ont été ignorées.", value: "Clé différente : %d ligne(s) chiffrée(s) avec une autre clé ont été ignorées.", table: nil), sync.skippedForeignKey))
                    .font(.footnote).foregroundStyle(.red)
            }
            if sync.skippedUnreadable > 0 {
                Text(String(format: Bundle.main.localizedString(forKey: "%d ligne(s) illisible(s) ont été ignorées.", value: "%d ligne(s) illisible(s) ont été ignorées.", table: nil), sync.skippedUnreadable))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }

    }

    private func activate() async {
        busy = true; error = nil
        defer { busy = false }
        do { sheet = .recoveryCreated(try await sync.enableEncryption()) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Feuilles

private struct RecoveryKeySheet: View {
    let keyText: String
    let title: String
    let done: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(keyText)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .privacySensitive()
                    Button { copyToPasteboard(keyText) } label: {
                        Label { Text(ui: "Copier") } icon: { Image(systemName: "doc.on.doc") }
                    }
                } header: {
                    Text(ui: "Clé de secours — garde-la hors de l'app")
                } footer: {
                    Text(ui: "Sans cette clé ni un autre appareil connecté, tes données chiffrées sont perdues pour de bon. Note-la sur papier ou dans un gestionnaire de mots de passe.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(ui: title))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text(ui: done) } } }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}

private struct ConfirmSheet: View {
    let title: String
    let message: String
    let action: String
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(ui: message).font(.subheadline) }
                Section {
                    Button { confirm() } label: { Text(ui: action) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(ui: title))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(ui: "Annuler") } } }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}

private struct PairHostSheet: View {
    let sync: SupabaseSync
    @Environment(\.dismiss) private var dismiss
    @State private var host: SyncPairingHost?
    @State private var state: SyncPairingHost.State = .waiting
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else if let host, state == .waiting {
                    Section {
                        HStack {
                            Spacer()
                            SyncQRCodeView(text: host.qr)
                            Spacer()
                        }
                        Text(host.code)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    } footer: {
                        Text(ui: "Sur le nouvel appareil, connecte-toi au même compte, puis « Entrer un code d'appairage ». Le code est valable 10 minutes et ne sert qu'une fois.")
                    }
                } else if state == .verifying {
                    Section { HStack { ProgressView(); Text(ui: "Vérification en cours…") } }
                } else if state == .done {
                    Section { Label { Text(ui: "Appareil ajouté") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
                } else if case .failed(let message) = state {
                    Section { Text(message).foregroundStyle(.red) }
                } else if state == .expired {
                    Section { Text(ui: "Le code a expiré : génères-en un autre.").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(ui: "Ajouter un appareil"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text(ui: state == .done ? "Terminé" : "Fermer") } } }
        }
        .frame(minWidth: 380, minHeight: 420)
        .task {
            do {
                host = try await sync.startPairing { new in Task { @MainActor in state = new } }
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { Task { await host?.cancel() } }
    }
}

private struct CodeEntrySheet: View {
    let title: String
    let prompt: String
    let action: String
    let hint: String
    let scanner: Bool
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if done {
                        Label { Text(ui: "Appareil ajouté") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    } else {
                        TextField(prompt, text: $text)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            #if canImport(UIKit)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .disabled(busy)
                        #if canImport(UIKit)
                        if scanner {
                            Button { scanning = true } label: {
                                Label { Text(ui: "Scanner le QR code") } icon: { Image(systemName: "qrcode.viewfinder") }
                            }
                            .disabled(busy)
                        }
                        #endif
                    }
                } footer: {
                    Text(ui: hint)
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if !done {
                    Section {
                        Button { Task { await run() } } label: { Text(ui: busy ? "Vérification…" : action) }
                            .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(ui: title))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(ui: done ? "Terminé" : "Annuler") } } }
            #if canImport(UIKit)
            .sheet(isPresented: $scanning) {
                QRScannerSheet { code in
                    scanning = false
                    text = code
                    Task { await run() }
                }
            }
            #endif
        }
        .frame(minWidth: 380, minHeight: 320)
    }

    private func run() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await submit(text); done = true }
        catch { self.error = error.localizedDescription }
    }
}

private struct ResetSheet: View {
    let sync: SupabaseSync
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?

    private static let word = String(localized: "RÉINITIALISER")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ui: "À n'utiliser que si tous tes appareils et ta clé de secours sont perdus. Les données chiffrées de ce compte seront effacées du serveur, définitivement, et les autres appareils ne pourront plus les lire. Cet appareil créera un coffre neuf et renverra ses propres données.")
                        .font(.subheadline)
                    TextField(Bundle.main.localizedString(forKey: "Tape RÉINITIALISER pour confirmer", value: "Tape RÉINITIALISER pour confirmer", table: nil), text: $confirmation)
                        .autocorrectionDisabled()
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button(role: .destructive) {
                        Task {
                            busy = true; error = nil
                            defer { busy = false }
                            do { created(try await sync.resetVault()) } catch { self.error = error.localizedDescription }
                        }
                    } label: { Text(ui: "Réinitialiser le coffre") }
                    .disabled(busy || confirmation.trimmingCharacters(in: .whitespaces).uppercased() != Self.word)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(ui: "Réinitialiser le coffre"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(ui: "Annuler") } } }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}

// MARK: - Lecteur de QR (iPhone)

#if canImport(UIKit)
/// Lit un QR code avec la caméra et rend son texte. Rien ne tourne une fois la feuille fermée.
private struct QRScannerSheet: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerRepresentable(found: found)
                .ignoresSafeArea()
                .navigationTitle(Text(ui: "Scanner le QR code"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(ui: "Annuler") } } }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.forEach { $0.frame = view.bounds }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  SyncCrypto.parsePairingInput(text) != nil else { return }
            delivered = true
            found?(text)
        }
    }
}
#endif

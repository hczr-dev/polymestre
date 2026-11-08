import Foundation

/// Ce qu'une autre app a partagé vers Polymestre, en attente d'être importé.
///
/// L'extension de partage et l'app sont **deux processus** : l'extension ne peut
/// pas ouvrir l'écran d'import. Elle dépose donc le fichier dans le conteneur
/// partagé et referme ; l'app le reprend au premier plan suivant.
struct PendingImport: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable {
        /// Un PDF de série, copié dans le conteneur partagé.
        case pdf
        /// Du texte collé depuis une page ou un mail.
        case text
    }

    var kind: Kind
    var fileName: String?
    var text: String?
    var receivedAt: Date

    var displayName: String {
        switch kind {
        case .pdf:
            return fileName.map { String(localized: "PDF « \($0) »") } ?? "PDF"
        case .text:
            let length = text?.count ?? 0
            return String(localized: "texte (\(length) caractères)")
        }
    }
}

/// Dépôt partagé, dans le conteneur du groupe d'app.
enum PendingImportBridge {

    static let fileName = "pending-import.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetBridge.appGroupID)
    }

    static var manifestURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    /// Où copier le fichier partagé.
    static func destinationURL(for name: String) -> URL? {
        containerURL?.appendingPathComponent("shared-\(name)")
    }

    static func store(_ item: PendingImport) {
        guard let url = manifestURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(item) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Retire et renvoie l'import en attente, s'il y en a un.
    ///
    /// Consommé une seule fois : un partage ne doit pas se rejouer à chaque
    /// ouverture de l'app.
    static func take() -> PendingImport? {
        guard let url = manifestURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingImport.self, from: data)
    }

    /// Le fichier d'un import en attente, s'il existe encore.
    static func file(for item: PendingImport) -> URL? {
        guard item.kind == .pdf, let name = item.fileName else { return nil }
        let url = containerURL?.appendingPathComponent("shared-\(name)")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

import Foundation

/// L'appairage d'un appareil à la synchronisation chiffrée, par le relais — le pendant
/// de `windows/src/services/syncPairing.ts`.
///
///   Appareil A (déjà connecté)            Appareil B (nouveau, même compte)
///   ─────────────────────────             ─────────────────────────────────
///   S = 16 octets aléatoires, montrés     saisit le code (ou lit le QR) → S
///   en code ; canal = pair-<hkdf(S)>      canal = pair-<hkdf(S)>
///                                         ← hello { pubB }
///   offer { pubA, box } →                 k = HKDF(ECDH ‖ S, … pubA ‖ pubB)
///   box = AES-GCM(k, AK)                  AK = ouvrir(box) ; keyId(AK) doit être
///                                         celui du coffre du compte connecté
///                                         ← ok { AES-GCM(k, "ok") }
///
/// `S` ne transite jamais : le relais ne voit que deux clés publiques et des chiffrés.
/// Une tentative par code : A ignore tout `hello` après le premier. La WebSocket n'est
/// ouverte que le temps de l'écran d'appairage. Pur : la socket est un protocole
/// (`URLSessionWebSocketTask` dans l'app, un relais en mémoire dans les tests).

protocol SyncPairSocket: AnyObject {
    func send(_ text: String)
    func close()
    var onOpen: (() -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
}

/// Ouvre une socket sur un canal (« pair-<32 hex> »).
typealias SyncPairSocketFactory = (_ channel: String) -> SyncPairSocket

enum SyncPairingError: LocalizedError, Equatable {
    case invalidCode, timeout, wrongCode, otherAccount, relay, cancelled

    var errorDescription: String? {
        switch self {
        case .invalidCode: return String(localized: "Ce code n'est pas valide : 26 caractères, par groupes de 4.")
        case .timeout: return String(localized: "Aucun appareil n'a répondu. Vérifie le code, et que l'autre appareil affiche toujours « Ajouter un appareil ».")
        case .wrongCode: return String(localized: "Le code ne correspond pas. Vérifie-le et réessaie.")
        case .otherAccount: return String(localized: "Cet appareil est connecté à un autre compte que celui qui affiche le code.")
        case .relay: return String(localized: "La connexion au relais a été coupée : réessaie.")
        case .cancelled: return String(localized: "Appairage annulé.")
        }
    }
}

private func pairMessage(step: String, pub: Data? = nil, box: Data? = nil) -> String {
    var object: [String: Any] = ["t": "pair", "step": step]
    if let pub { object["pub"] = pub.base64EncodedString() }
    if let box { object["box"] = box.base64EncodedString() }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private struct PairMessage {
    let step: String
    let pub: Data?
    let box: Data?

    init?(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["t"] as? String == "pair", let step = object["step"] as? String,
              ["hello", "offer", "ok"].contains(step) else { return nil }
        self.step = step
        self.pub = (object["pub"] as? String).flatMap { Data(base64Encoded: $0) }
        self.box = (object["box"] as? String).flatMap { Data(base64Encoded: $0) }
    }
}

// MARK: - Côté A

/// Côté A : montre un code, répond au premier appareil qui le connaît.
actor SyncPairingHost {
    enum State: Equatable, Sendable {
        case waiting, verifying, done, cancelled, expired
        case failed(String)
    }

    static let timeToLive: Duration = .seconds(600)

    nonisolated let code: String
    nonisolated let qr: String
    private(set) var state: State = .waiting

    private let secret: Data
    private let ephemeral: SyncCrypto.Ephemeral
    private let accountKey: Data
    private let ttl: Duration
    private let makeSocket: SyncPairSocketFactory
    private let onState: @Sendable (State) -> Void
    private var socket: SyncPairSocket?
    private var key: Data?
    private var engaged = false
    private var expiry: Task<Void, Never>?

    /// `secret` et `ephemeral` : pour les tests ; en usage réel, tirés au hasard.
    init(accountKey: Data, secret: Data? = nil, ephemeral: SyncCrypto.Ephemeral? = nil, ttl: Duration = SyncPairingHost.timeToLive,
         makeSocket: @escaping SyncPairSocketFactory, onState: @escaping @Sendable (State) -> Void = { _ in }) throws {
        let s = secret ?? SyncCrypto.newPairingSecret()
        self.secret = s
        self.ephemeral = try ephemeral ?? SyncCrypto.Ephemeral()
        self.accountKey = accountKey
        self.ttl = ttl
        self.makeSocket = makeSocket
        self.onState = onState
        self.code = SyncCrypto.encodePairingCode(s)
        self.qr = SyncCrypto.pairingQRText(s)
    }

    /// Ouvre la socket et arme l'expiration.
    func start() {
        guard socket == nil, state == .waiting else { return }
        let socket = makeSocket(SyncCrypto.pairChannel(secret))
        socket.onMessage = { [weak self] text in Task { await self?.receive(text) } }
        socket.onClose = { [weak self] in Task { await self?.closed() } }
        self.socket = socket
        let ttl = self.ttl
        expiry = Task { [weak self] in
            try? await Task.sleep(for: ttl)
            guard !Task.isCancelled else { return }
            await self?.finish(.expired)
        }
    }

    func cancel() {
        if state == .waiting || state == .verifying { finish(.cancelled) }
    }

    private func closed() {
        if state == .waiting || state == .verifying { finish(.failed(String(localized: "La connexion au relais a été coupée."))) }
    }

    private func finish(_ new: State) {
        switch state {
        case .done, .failed, .expired, .cancelled: return
        default: break
        }
        state = new
        expiry?.cancel()
        socket?.close()
        socket = nil
        key = nil
        onState(new)
    }

    private func receive(_ text: String) {
        guard let message = PairMessage(text) else { return }
        do {
            if message.step == "hello", !engaged, state == .waiting {
                guard let pubB = message.pub, pubB.count == 32 else { return }
                engaged = true // une tentative par code
                state = .verifying
                onState(.verifying)
                let pubA = ephemeral.publicKey
                let k = try SyncCrypto.pairKey(mine: ephemeral, theirPublic: pubB, secret: secret, pubA: pubA, pubB: pubB)
                key = k
                let box = try SyncCrypto.sealAccountKey(k, accountKey: accountKey)
                socket?.send(pairMessage(step: "offer", pub: pubA, box: box))
            } else if message.step == "ok", state == .verifying, let key {
                if let box = message.box, SyncCrypto.openOK(key, box: box) { finish(.done) }
                else { finish(.failed(String(localized: "Le code saisi sur l'autre appareil ne correspond pas."))) }
            }
        } catch {
            finish(.failed(String(localized: "L'appairage a échoué.")))
        }
    }
}

// MARK: - Côté B

/// Côté B : rend la clé du compte, vérifiée contre le coffre.
final class SyncPairingJoiner: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var socket: SyncPairSocket?
    private var resend: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let secret: Data
    private let ephemeral: SyncCrypto.Ephemeral
    private let expectedKeyID: String
    private let makeSocket: SyncPairSocketFactory
    private let timeout: Duration

    private init(secret: Data, ephemeral: SyncCrypto.Ephemeral, expectedKeyID: String, timeout: Duration, makeSocket: @escaping SyncPairSocketFactory) {
        self.secret = secret
        self.ephemeral = ephemeral
        self.expectedKeyID = expectedKeyID
        self.timeout = timeout
        self.makeSocket = makeSocket
    }

    /// `code` : ce que l'étudiant·e a saisi ou lu (« polymestre-pair:… » accepté).
    static func join(code: String, expectedKeyID: String, ephemeral: SyncCrypto.Ephemeral? = nil, timeout: Duration = .seconds(30),
                     makeSocket: @escaping SyncPairSocketFactory) async throws -> Data {
        guard let secret = SyncCrypto.parsePairingInput(code) else { throw SyncPairingError.invalidCode }
        let joiner = SyncPairingJoiner(secret: secret, ephemeral: try ephemeral ?? SyncCrypto.Ephemeral(),
                                       expectedKeyID: expectedKeyID, timeout: timeout, makeSocket: makeSocket)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { joiner.begin($0) }
        } onCancel: {
            joiner.finish(.failure(SyncPairingError.cancelled))
        }
    }

    private func begin(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: SyncPairingError.cancelled); return }
        self.continuation = continuation
        lock.unlock()
        let socket = makeSocket(SyncCrypto.pairChannel(secret))
        lock.lock(); self.socket = socket; lock.unlock()
        let hello = pairMessage(step: "hello", pub: ephemeral.publicKey)
        socket.onOpen = { [weak self] in
            socket.send(hello)
            self?.startResending(socket, hello)
        }
        socket.onClose = { [weak self] in self?.finish(.failure(SyncPairingError.relay)) }
        socket.onMessage = { [weak self] text in self?.receive(text) }
        let timeout = self.timeout
        lock.lock()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(SyncPairingError.timeout))
        }
        lock.unlock()
    }

    private func startResending(_ socket: SyncPairSocket, _ hello: String) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self?.isFinished == false else { return }
                socket.send(hello)
            }
        }
        lock.lock(); resend = task; lock.unlock()
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func receive(_ text: String) {
        guard !isFinished, let message = PairMessage(text), message.step == "offer",
              let pubA = message.pub, pubA.count == 32, let box = message.box else { return }
        do {
            let k = try SyncCrypto.pairKey(mine: ephemeral, theirPublic: pubA, secret: secret, pubA: pubA, pubB: ephemeral.publicKey)
            guard let ak = try? SyncCrypto.openAccountKey(k, box: box) else { return finish(.failure(SyncPairingError.wrongCode)) }
            guard let keys = try? SyncCrypto.keys(for: ak), keys.keyID == expectedKeyID else { return finish(.failure(SyncPairingError.otherAccount)) }
            let reply = pairMessage(step: "ok", box: try SyncCrypto.sealOK(k))
            lock.lock(); let socket = self.socket; lock.unlock()
            socket?.send(reply)
            // Laisse partir la confirmation avant de fermer.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.finish(.success(ak))
            }
        } catch {
            finish(.failure(SyncPairingError.relay))
        }
    }

    fileprivate func finish(_ result: Result<Data, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let socket = self.socket
        self.socket = nil
        let tasks = [resend, timeoutTask]
        lock.unlock()
        tasks.forEach { $0?.cancel() }
        socket?.close()
        continuation?.resume(with: result)
    }
}

import Foundation
import ImageIO
import MusicKit
import Observation
import SwiftUI
import OSLog
#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit
#else
import AppKit
#endif

/// La musique du mode étude : Apple Music, sans quitter l'écran d'étude.
///
/// **D'où ça vient.** Repris de Tournesol (`../tournesol`) : la lecture de
/// l'iPhone (`MusicPlayerSource`, le lecteur système), celle du Mac
/// (`MusicAppSource`, Music piloté par AppleScript) et la recherche dans le
/// catalogue (`SearchView`, `CatalogLookup`, `TrackMatcher`) — réduits à ce
/// qu'il faut pour écouter en travaillant.
///
/// **Où ça joue.** Dans Music, pas dans Polymestre : sur l'iPhone et l'iPad,
/// le lecteur système (la musique continue après la session, et se pilote
/// aussi depuis le centre de contrôle) ; sur le Mac, l'app Music, que le mode
/// étude laisse tourner en arrière-plan sans jamais la montrer.
@MainActor
@Observable
final class StudyMusic {
    static let shared = StudyMusic()

    /// Ce qui joue.
    struct NowPlaying: Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        /// L'instant où `elapsed` a été lu (la position avance d'elle-même).
        var readAt = Date()
        var isPlaying = false
        var shuffle = false
        var repeatMode: RepeatMode = .off
        /// La clé du morceau (son illustration change avec elle).
        var key: String?

        var hasTrack: Bool { title != nil }

        func elapsed(at date: Date) -> TimeInterval {
            guard isPlaying else { return elapsed }
            return min(duration > 0 ? duration : .infinity, max(0, elapsed + date.timeIntervalSince(readAt)))
        }

        var track: MusicTrackReference {
            MusicTrackReference(catalogID: nil, title: title, artist: artist, album: album, duration: duration)
        }
    }

    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var next: RepeatMode {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }

        var icon: String { self == .one ? "repeat.1" : "repeat" }
    }

    /// Un morceau d'« À suivre ». `id` est celui de la file de Music : c'est
    /// lui que les modifications désignent.
    struct QueueItem: Identifiable, Equatable {
        let id: String
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval = 0
    }

    private(set) var nowPlaying = NowPlaying() {
        didSet {
            let song = nowPlaying.title.map { MusicTrackMatcher.CurrentSong(title: $0, artist: nowPlaying.artist) }
            if song != currentSong { currentSong = song }
        }
    }
    /// Le morceau en cours, réduit à ce qui l'identifie : ne change qu'avec le
    /// morceau. Les listes ne suivent que lui, pas la position ni la lecture,
    /// et ne se redessinent plus à chaque annonce de Music.
    private(set) var currentSong: MusicTrackMatcher.CurrentSong?
    /// Ce que Music jouera ensuite (Mac : sa vraie file ; iPhone : vide).
    private(set) var upNext: [QueueItem] = []
    /// La file se réordonne et se vide (Mac, tant que Music l'accepte).
    private(set) var canEditQueue = false
    /// L'illustration du morceau, lue dans Music ou trouvée dans le catalogue.
    private(set) var artwork: PlatformImage?
    private(set) var artworkURL: URL?
    /// La couleur moyenne de la pochette, pour teinter le lecteur (comme Music).
    private(set) var artworkTint: Color?
    /// Le volume de Music (Mac seulement : sur l'iPhone, les boutons de l'appareil).
    private(set) var volume: Double?
    private(set) var authorization = MusicAuthorization.currentStatus
    /// La dernière chose qui n'a pas marché (lecture refusée, Music fermé…).
    var lastError: String?
    /// Remet à zéro le refus d'Automatisation de Music pour Polymestre, puis refait une
    /// demande : macOS reposera la question. Réversible, sans droits d'administration.
    func askAutomationAgain() {
        #if os(macOS)
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "ch.polymestre.mac"]
        try? reset.run()
        reset.waitUntilExit()
        automation = .undetermined
        // Une lecture neuve : le premier script refait la demande au système.
        if observers > 0 { backend.stop(); backend.start() }
        #endif
    }

    /// L'Automatisation de Music pour Polymestre : pas encore demandée, accordée (un
    /// script a répondu) ou refusée (erreur -1743) — sans cela, l'écran disait seulement
    /// « Rien ne joue ».
    enum Automation: Equatable { case undetermined, granted, denied }
    var automation: Automation = .undetermined
    var automationDenied: Bool { automation == .denied }

    var isAuthorized: Bool { authorization == .authorized }

    // MARK: Un seul lecteur (Mac et iPhone)

    /// Ce qui joue sur les autres appareils du compte (`MusicLink`).
    private(set) var remotes: [String: MusicLink.State] = [:]
    /// Le lecteur montré : ici, ou un autre appareil (celui qui joue).
    private(set) var route: MusicLink.Route = .local
    /// L'appareil choisi à la main (« Écouter sur… »), quand rien ne joue.
    @ObservationIgnored private var pinned: String?
    /// L'état d'ici, gardé à part quand le lecteur montre un autre appareil.
    @ObservationIgnored private var local = NowPlaying()
    @ObservationIgnored private var localVolume: Double?
    @ObservationIgnored private var localUpNext: [QueueItem] = []
    @ObservationIgnored private var localCanEdit = false
    @ObservationIgnored private var localArtwork: PlatformImage?
    @ObservationIgnored private var localArtworkURL: URL?
    @ObservationIgnored private var localTint: Color?
    @ObservationIgnored private var published: MusicLink.State?
    @ObservationIgnored private var publishedArtwork: (key: String, url: String?)?

    /// L'appareil dont le lecteur montre la musique.
    var playingOn: MusicLink.Platform {
        if case .remote(let id) = route, let state = remotes[id] { return state.platform }
        return Self.here
    }

    var isRemote: Bool { if case .remote = route { return true }; return false }

    /// Les appareils où la musique peut aller (ici compris).
    var devices: [(id: String, platform: MusicLink.Platform, isHere: Bool)] {
        [(CloudRelay.deviceID, Self.here, true)] + remotes.values.sorted { $0.platform.rawValue < $1.platform.rawValue }
            .map { ($0.device, $0.platform, false) }
    }

    /// Le partage entre appareils (réglage ; allumé par défaut).
    static var sharingEnabled: Bool {
        UserDefaults.standard.object(forKey: "music.shareAcrossDevices") as? Bool ?? true
    }

    static var here: MusicLink.Platform {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }

    @ObservationIgnored private let backend = Backend()
    @ObservationIgnored private var observers = 0
    @ObservationIgnored private var queueViewers = 0
    @ObservationIgnored private var artworkKey: String?

    private init() {
        backend.onChange = { [weak self] in self?.receive() }
    }

    // MARK: Suivre

    /// Une vue qui montre la musique s'abonne (`attach`) et se désabonne en
    /// partant : sur le Mac, Music n'est interrogé que pendant ce temps.
    func attach() {
        observers += 1
        if observers == 1 { backend.start() }
    }

    func detach() {
        observers = max(0, observers - 1)
        if observers == 0 { backend.stop() }
    }

    /// « À suivre » à l'écran : la file est lue (Mac) — et seulement alors.
    func watchQueue() {
        queueViewers += 1
        if queueViewers == 1 { backend.setQueueWanted(true) }
    }

    func unwatchQueue() {
        queueViewers = max(0, queueViewers - 1)
        if queueViewers == 0 { backend.setQueueWanted(false) }
    }

    func requestAuthorization() async {
        if MusicAuthorization.currentStatus == .notDetermined {
            authorization = await MusicAuthorization.request()
        } else {
            authorization = MusicAuthorization.currentStatus
        }
    }

    private func receive() {
        let next = backend.state
        local = next
        localVolume = backend.volume
        localUpNext = backend.upNext
        localCanEdit = backend.canEditQueue
        reroute()
        publishLocal()
        guard next.key != artworkKey else { return }
        artworkKey = next.key
        localArtwork = nil
        localArtworkURL = nil
        localTint = nil
        showLocalArtwork()
        guard let key = next.key, next.hasTrack else { return }
        Task {
            if let image = await backend.artwork(), artworkKey == key {
                localArtwork = image
                localTint = MusicArtworkTint.average(of: image)
                showLocalArtwork()
                return
            }
            // Pas d'illustration dans Music (un morceau en streaming) : le catalogue.
            let url = await MusicCatalogLookup.artworkURL(for: next.track)
            if artworkKey == key {
                localArtworkURL = url
                showLocalArtwork()
            }
        }
    }

    /// Ce que le lecteur montre : ici, ou l'appareil qui joue.
    private func reroute() {
        let now = Date()
        let chosen = Self.sharingEnabled
            ? MusicLink.route(localPlaying: local.isPlaying, localHasTrack: local.hasTrack, remotes: Array(remotes.values), pinned: pinned, now: now)
            : .local
        if chosen != route { route = chosen }
        switch chosen {
        case .local:
            if local != nowPlaying { nowPlaying = local }
            if localVolume != volume { volume = localVolume }
            if localUpNext != upNext { upNext = localUpNext }
            if localCanEdit != canEditQueue { canEditQueue = localCanEdit }
            showLocalArtwork()
        case .remote(let id):
            guard let state = remotes[id] else { return }
            var mirrored = NowPlaying()
            mirrored.title = state.title
            mirrored.artist = state.artist
            mirrored.album = state.album
            mirrored.duration = state.duration
            mirrored.elapsed = state.elapsed
            mirrored.readAt = state.readAt
            mirrored.isPlaying = state.isPlaying
            mirrored.shuffle = state.shuffle
            mirrored.repeatMode = RepeatMode(rawValue: state.repeatMode) ?? .off
            mirrored.key = "remote|\(id)|\(state.title ?? "")|\(state.artist ?? "")"
            if mirrored != nowPlaying { nowPlaying = mirrored }
            if state.volume != volume { volume = state.volume }
            let items = state.upNext.enumerated().map { QueueItem(id: "remote-\($0.offset)", title: $0.element.title, artist: $0.element.artist,
                                                                  album: $0.element.album, duration: $0.element.duration) }
            if items != upNext { upNext = items }
            if canEditQueue { canEditQueue = false }
            let url = state.artworkURL.flatMap(URL.init(string:))
            if artworkURL != url || artwork != nil {
                artwork = nil
                artworkURL = url
                artworkTint = nil
            }
        }
    }

    private func showLocalArtwork() {
        guard route == .local else { return }
        artwork = localArtwork
        artworkURL = localArtworkURL
        artworkTint = localTint
    }

    // MARK: Commandes

    // Chaque geste se voit tout de suite : Music met un instant à le refléter,
    // et un bouton qui ne réagit pas sous le doigt paraît cassé.
    /// Le geste va à l'appareil montré : ici, ou par le lien.
    private func perform(_ command: Command, remote action: MusicLink.Action) {
        if case .remote(let id) = route { sendCommand(action, to: id) } else { backend.send(command) }
    }

    func togglePlayPause() {
        let now = Date()
        nowPlaying.elapsed = nowPlaying.elapsed(at: now)
        nowPlaying.readAt = now
        nowPlaying.isPlaying.toggle()
        perform(.toggle, remote: .toggle)
    }
    func next() { perform(.next, remote: .next) }
    func previous() { perform(.previous, remote: .previous) }
    func seek(to position: TimeInterval) {
        nowPlaying.elapsed = position
        nowPlaying.readAt = Date()
        perform(.seek(position), remote: .seek(position))
    }
    func setShuffle(_ on: Bool) {
        nowPlaying.shuffle = on
        perform(.shuffle(on), remote: .shuffle(on))
    }
    func cycleRepeat() {
        nowPlaying.repeatMode = nowPlaying.repeatMode.next
        perform(.repeatMode(nowPlaying.repeatMode), remote: .repeatMode(nowPlaying.repeatMode.rawValue))
    }
    func setVolume(_ value: Double) {
        volume = value
        perform(.volume(value), remote: .volume(value))
    }

    /// Joue `songs[index]` et met la suite en file.
    func play(_ songs: [Song], from index: Int = 0, shuffled: Bool = false) {
        guard songs.indices.contains(index) else { return }
        // Mélangé : un ordre au hasard, depuis le début (l'index visait l'ordre d'origine).
        let (songs, index) = shuffled ? (songs.shuffled(), 0) : (songs, index)
        lastError = nil
        if case .remote(let id) = route {
            sendCommand(.playCatalog(songs.map(\.id.rawValue), index: index, shuffled: shuffled), to: id)
            return
        }
        Task { await report(backend.play(songs, from: index, shuffled: shuffled)) }
    }

    /// Joue un album ou une playlist en entier.
    func play(_ collection: MusicCollection, shuffled: Bool = false) {
        lastError = nil
        if case .remote(let id) = route {
            Task {
                guard let songs = try? await collection.songs(), !songs.isEmpty else { return }
                sendCommand(.playCatalog(songs.map(\.id.rawValue), index: 0, shuffled: shuffled), to: id)
            }
            return
        }
        Task { await report(backend.play(collection, shuffled: shuffled)) }
    }

    /// « À suivre » (`next`) ou « Ajouter à la file ».
    func enqueue(_ songs: [Song], next: Bool) {
        guard !songs.isEmpty else { return }
        lastError = nil
        if case .remote(let id) = route {
            sendCommand(.enqueue(songs.map(\.id.rawValue), next: next), to: id)
            return
        }
        Task { await report(backend.enqueue(songs, next: next)) }
    }

    // MARK: Changer d'appareil

    /// Faire jouer la musique ici ou là : elle part d'où elle joue et reprend
    /// sur l'appareil choisi, au même morceau, à la même seconde.
    func move(to device: String) {
        let current = route
        let target: MusicLink.Route = device == CloudRelay.deviceID ? .local : .remote(device)
        pinned = device == CloudRelay.deviceID ? nil : device
        guard current != target else { return }
        let now = Date()
        let source = nowPlaying
        guard source.hasTrack else { reroute(); return }
        let item = MusicLink.Item(title: source.title, artist: source.artist, album: source.album, duration: source.duration)
        let elapsed = source.elapsed(at: now)
        let playing = source.isPlaying
        // Arrêter là où ça joue…
        switch current {
        case .local: if local.isPlaying { backend.send(.toggle) }
        case .remote(let id): sendCommand(.pause, to: id)
        }
        // …et reprendre là où on veut.
        switch target {
        case .local:
            Task { await resume(item, at: elapsed + 0.4, playing: playing) }
        case .remote(let id):
            // L'iPhone endormi est réveillé par le relais, la commande jointe.
            sendCommand(.handoff(item, elapsed: elapsed + 0.8, playing: playing), to: id, wake: true)
        }
        route = target
    }

    /// Reprendre ici un morceau entendu ailleurs (retrouvé dans le catalogue).
    private func resume(_ item: MusicLink.Item, at elapsed: TimeInterval, playing: Bool) async {
        let reference = MusicTrackReference(catalogID: nil, title: item.title, artist: item.artist, album: item.album, duration: item.duration)
        guard let song = await MusicCatalogLookup.song(for: reference) else {
            lastError = String(localized: "Morceau introuvable dans Apple Music : il n'a pas pu changer d'appareil.")
            return
        }
        let started = Date()
        if let error = await backend.play([song], from: 0, shuffled: false) {
            lastError = error
            return
        }
        // Le temps de démarrer compte : la seconde reste la bonne.
        try? await Task.sleep(for: .milliseconds(600))
        backend.send(.seek(elapsed + Date().timeIntervalSince(started)))
        if !playing { backend.send(.toggle) }
    }

    // MARK: Le lien

    private func sendCommand(_ action: MusicLink.Action, to device: String?, wake: Bool = false) {
        let command = MusicLink.Command(from: CloudRelay.deviceID, to: device, action: action, sentAt: Date())
        TimerLink.shared.sendMusic(.command(command), wake: wake)
    }

    /// Le lien vient de s'ouvrir : on se présente, et on demande aux autres
    /// ce qu'ils jouent.
    func linkConnected() {
        guard Self.sharingEnabled else { return }
        published = nil
        publishLocal(force: true)
        sendCommand(.announce, to: nil)
    }

    /// Un message d'un autre appareil.
    func receive(_ message: MusicLink.Message) {
        guard Self.sharingEnabled else { return }
        switch message {
        case .state(let state):
            guard state.device != CloudRelay.deviceID else { return }
            remotes[state.device] = state
            reroute()
        case .command(let command):
            guard command.from != CloudRelay.deviceID, command.to == nil || command.to == CloudRelay.deviceID else { return }
            // Une commande vieille (un réveil tardif) n'a plus de sens.
            guard Date().timeIntervalSince(command.sentAt) < 120 else { return }
            execute(command.action)
        }
    }

    /// Une commande venue d'ailleurs, jouée ici.
    func execute(_ action: MusicLink.Action) {
        switch action {
        case .toggle: backend.send(.toggle)
        case .play: if !local.isPlaying { backend.send(.toggle) }
        case .pause: if local.isPlaying { backend.send(.toggle) }
        case .next: backend.send(.next)
        case .previous: backend.send(.previous)
        case .seek(let position): backend.send(.seek(position))
        case .volume(let value): backend.send(.volume(value))
        case .shuffle(let on): backend.send(.shuffle(on))
        case .repeatMode(let raw): backend.send(.repeatMode(RepeatMode(rawValue: raw) ?? .off))
        case .playCatalog(let ids, let index, let shuffled):
            Task {
                let songs = await Self.catalogSongs(ids)
                guard songs.indices.contains(min(index, songs.count - 1)), !songs.isEmpty else { return }
                await report(backend.play(songs, from: min(index, songs.count - 1), shuffled: shuffled))
            }
        case .enqueue(let ids, let next):
            Task {
                let songs = await Self.catalogSongs(ids)
                guard !songs.isEmpty else { return }
                await report(backend.enqueue(songs, next: next))
            }
        case .handoff(let item, let elapsed, let playing):
            pinned = nil
            route = .local
            Task { await resume(item, at: elapsed, playing: playing) }
        case .announce:
            published = nil
            publishLocal(force: true)
        }
    }

    private static func catalogSongs(_ ids: [String]) async -> [Song] {
        guard !ids.isEmpty else { return [] }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        guard let response = try? await request.response() else { return [] }
        // Dans l'ordre demandé.
        let byID = Dictionary(response.items.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Publie l'état d'ici quand il change vraiment (pas la position qui avance).
    private func publishLocal(force: Bool = false) {
        guard Self.sharingEnabled, TimerLink.shared.isConnected else { return }
        var state = MusicLink.State(device: CloudRelay.deviceID, platform: Self.here, title: local.title, artist: local.artist,
                                    album: local.album, duration: local.duration, elapsed: local.elapsed, readAt: local.readAt,
                                    isPlaying: local.isPlaying, shuffle: local.shuffle, repeatMode: local.repeatMode.rawValue,
                                    volume: localVolume, artworkURL: nil,
                                    upNext: localUpNext.prefix(10).map { MusicLink.Item(title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration) },
                                    updatedAt: Date())
        let key = "\(local.title ?? "")|\(local.artist ?? "")"
        if let cached = publishedArtwork, cached.key == key { state.artworkURL = cached.url }
        guard force || MusicLink.changed(published, state) else { return }
        published = state
        TimerLink.shared.sendMusic(.state(state))
        // La pochette, pour l'autre appareil : une adresse du catalogue (une
        // recherche par morceau, seulement quand quelqu'un regarde).
        if local.hasTrack, publishedArtwork?.key != key, !remotes.isEmpty {
            publishedArtwork = (key, nil)
            let track = local.track
            Task {
                let url = await MusicCatalogLookup.artworkURL(for: track)
                guard publishedArtwork?.key == key, var latest = published else { return }
                publishedArtwork = (key, url?.absoluteString)
                latest.artworkURL = url?.absoluteString
                latest.updatedAt = Date()
                published = latest
                TimerLink.shared.sendMusic(.state(latest))
            }
        }
    }

    // MARK: À suivre

    /// Saute à ce morceau de la file.
    func playQueued(_ item: QueueItem) {
        // Seulement la file de cet appareil : sur celle d'un autre (miroir), la
        // commande serait fausse, et deux échecs coupent l'édition de la file.
        guard canEditQueue, !isRemote else { return }
        lastError = nil
        Task { await report(backend.playQueued(item)) }
    }

    func removeQueued(_ items: [QueueItem]) {
        let removed = Set(items.map(\.id))
        editQueue(upNext.filter { !removed.contains($0.id) })
    }

    func moveQueued(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = upNext
        order.move(fromOffsets: source, toOffset: destination)
        editQueue(order)
    }

    /// Le place juste après le morceau en cours.
    func playQueuedNext(_ item: QueueItem) {
        guard let index = upNext.firstIndex(of: item), index > 0 else { return }
        moveQueued(fromOffsets: [index], toOffset: 0)
    }

    func clearQueue() { editQueue([]) }

    private func editQueue(_ target: [QueueItem]) {
        guard canEditQueue, target != upNext else { return }
        lastError = nil
        upNext = target
        Task { await report(backend.editQueue(to: target)) }
    }

    private func report(_ error: String?) {
        if let error { lastError = error }
    }
}

/// Un album ou une playlist, pour les jouer en entier.
enum MusicCollection {
    case album(Album)
    case playlist(Playlist)

    var title: String {
        switch self {
        case .album(let album): return album.title
        case .playlist(let playlist): return playlist.name
        }
    }

    var subtitle: String? {
        switch self {
        case .album(let album): return album.artistName
        case .playlist(let playlist): return playlist.curatorName
        }
    }

    var artwork: Artwork? {
        switch self {
        case .album(let album): return album.artwork
        case .playlist(let playlist): return playlist.artwork
        }
    }

    func songs() async throws -> [Song] {
        let tracks: MusicItemCollection<Track>?
        switch self {
        case .album(let album): tracks = try await album.with([.tracks]).tracks
        case .playlist(let playlist): tracks = try await playlist.with([.tracks]).tracks
        }
        return (tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
    }
}

private enum Command {
    case toggle, next, previous
    case seek(TimeInterval)
    case shuffle(Bool)
    case repeatMode(StudyMusic.RepeatMode)
    case volume(Double)
}

private let log = Logger(subsystem: "ch.polymestre", category: "music")

// MARK: - iPhone, iPad : le lecteur système

#if os(iOS)
/// Repris de `MusicPlayerSource` (Tournesol) : on lit et on pilote le lecteur
/// système par MediaPlayer ; on remplit sa file par MusicKit, qui sait jouer
/// aussi bien un morceau du catalogue que de la bibliothèque.
@MainActor
private final class Backend {
    var onChange: (() -> Void)?
    private(set) var state = StudyMusic.NowPlaying()
    /// Le volume du téléphone (0…1) : lu sur la session audio, réglé par un `MPVolumeView`
    /// caché (la seule voie permise) — comme dans Tournesol.
    private(set) var volume: Double?

    /// La file du lecteur système : lue par les sélecteurs `numberOfItems` et
    /// `nowPlayingItemAtIndex:` (comme Tournesol), modifiée en ajoutant, en sautant ce
    /// qu'on retire, ou en la rebâtissant autour du morceau en cours.
    private(set) var upNext: [StudyMusic.QueueItem] = []
    let canEditQueue = true

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []
    private let session = AVAudioSession.sharedInstance()
    private var volumeObservation: NSKeyValueObservation?
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    /// Les morceaux retirés de la file : le lecteur ne sait pas en lâcher un, alors chacun
    /// est sauté quand il arrive.
    private var skipped: [String] = []
    private var queueWanted = false

    func start() {
        guard observers.isEmpty else { return }
        player.beginGeneratingPlaybackNotifications()
        let names: [Notification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // Les boutons de volume du téléphone : lus quand ils bougent.
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        attachVolumeView()
        // Pas de relecture périodique : l'aléatoire et la répétition, qui ne
        // préviennent pas, sont relus au retour dans l'app et après nos gestes.
        refresh()
    }

    func setQueueWanted(_ wanted: Bool) {
        queueWanted = wanted
        if wanted { refresh() }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        volumeObservation = nil
        volumeView.removeFromSuperview()
        player.endGeneratingPlaybackNotifications()
    }

    /// Le curseur de volume du système doit être dans une fenêtre pour répondre.
    private func attachVolumeView() {
        guard volumeView.superview == nil else { return }
        volumeView.alpha = 0.01
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(volumeView)
    }

    func refresh() {
        // Un morceau retiré de la file qui arrive : on le saute.
        if let item = player.nowPlayingItem, !skipped.isEmpty,
           let index = skipped.firstIndex(of: Self.signature(item.title, item.artist, item.albumTitle)) {
            skipped.remove(at: index)
            player.skipToNextItem()
            return
        }
        volume = Double(session.outputVolume)
        upNext = queueWanted ? upcoming() : []
        var next = StudyMusic.NowPlaying()
        if let item = player.nowPlayingItem {
            next.title = item.title
            next.artist = item.artist
            next.album = item.albumTitle
            next.duration = item.playbackDuration
            next.elapsed = player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0
            next.isPlaying = player.playbackState == .playing
            next.key = item.persistentID != 0 ? String(item.persistentID) : item.playbackStoreID
        }
        next.shuffle = player.shuffleMode != .off && player.shuffleMode != .default
        next.repeatMode = switch player.repeatMode {
        case .one: .one
        case .all: .all
        default: .off
        }
        state = next
        onChange?()
    }

    func artwork() async -> UIImage? {
        player.nowPlayingItem?.artwork?.image(at: CGSize(width: 600, height: 600))
    }

    func send(_ command: Command) {
        switch command {
        case .toggle: player.playbackState == .playing ? player.pause() : player.play()
        case .next: player.skipToNextItem()
        case .previous: player.currentPlaybackTime > 3 ? player.skipToBeginning() : player.skipToPreviousItem()
        case .seek(let position): player.currentPlaybackTime = position
        case .shuffle(let on): player.shuffleMode = on ? .songs : .off
        case .repeatMode(let mode):
            player.repeatMode = switch mode {
            case .off: .none
            case .all: .all
            case .one: .one
            }
        case .volume(let value): setVolume(value)
        }
        settle()
    }

    // MARK: Volume

    private func setVolume(_ value: Double) {
        attachVolumeView()
        let level = Float(min(1, max(0, value)))
        if let slider = volumeView.subviews.lazy.compactMap({ $0 as? UISlider }).first {
            slider.setValue(level, animated: false)
            slider.sendActions(for: .valueChanged)
            volume = Double(level)
        }
    }

    // MARK: File

    private static func signature(_ title: String?, _ artist: String?, _ album: String?) -> String {
        [title, artist, album].map { ($0 ?? "").lowercased() }.joined(separator: "|")
    }

    /// Les morceaux à venir (vingt-cinq au plus), moins ceux qu'on a retirés.
    private func upcoming() -> [StudyMusic.QueueItem] {
        let countSelector = NSSelectorFromString("numberOfItems")
        let itemSelector = NSSelectorFromString("nowPlayingItemAtIndex:")
        guard player.responds(to: countSelector), player.responds(to: itemSelector) else { return [] }
        typealias Count = @convention(c) (AnyObject, Selector) -> UInt
        typealias Item = @convention(c) (AnyObject, Selector, UInt) -> MPMediaItem?
        let count = unsafeBitCast(player.method(for: countSelector), to: Count.self)(player, countSelector)
        let itemAt = unsafeBitCast(player.method(for: itemSelector), to: Item.self)
        let current = UInt(player.indexOfNowPlayingItem)
        guard current != UInt(NSNotFound), count > current + 1 else { return [] }
        var pending = skipped
        var items: [StudyMusic.QueueItem] = []
        for index in (current + 1)..<min(count, current + 26) {
            guard let item = itemAt(player, itemSelector, index) else { continue }
            let signature = Self.signature(item.title, item.artist, item.albumTitle)
            if let at = pending.firstIndex(of: signature) { pending.remove(at: at); continue }
            let store = item.playbackStoreID == "0" ? "" : item.playbackStoreID
            items.append(StudyMusic.QueueItem(id: "\(item.persistentID)|\(store)|\(index)", title: item.title, artist: item.artist,
                                              album: item.albumTitle, duration: item.playbackDuration))
        }
        return items
    }

    /// L'identité d'un morceau de la file : son numéro dans la bibliothèque, ou son numéro du catalogue.
    private func reference(_ item: StudyMusic.QueueItem) -> (library: UInt64?, store: String?) {
        let parts = item.id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return (nil, nil) }
        let library = UInt64(parts[0]).flatMap { $0 == 0 ? nil : $0 }
        return (library, parts[1].isEmpty ? nil : parts[1])
    }

    private func libraryItem(_ id: UInt64) -> MPMediaItem? {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
        return query.items?.first
    }

    /// Les retraits seuls (l'ordre est gardé) : les signatures retirées ; `nil` si l'ordre a changé.
    private static func removals(from existing: [StudyMusic.QueueItem], to target: [StudyMusic.QueueItem]) -> [StudyMusic.QueueItem]? {
        var kept = 0
        var removed: [StudyMusic.QueueItem] = []
        for item in existing {
            if kept < target.count, item.id == target[kept].id { kept += 1 } else { removed.append(item) }
        }
        return kept == target.count ? removed : nil
    }

    func editQueue(to target: [StudyMusic.QueueItem]) async -> String? {
        let existing = upcoming()
        guard existing.map(\.id) != target.map(\.id) else { return nil }
        if !target.isEmpty, let removed = Self.removals(from: existing, to: target) {
            skipped += removed.map { Self.signature($0.title, $0.artist, $0.album) }
            upNext = target
            return nil
        }
        skipped = []
        return await rebuild(current: player.nowPlayingItem, upcoming: target)
    }

    func playQueued(_ item: StudyMusic.QueueItem) async -> String? {
        let existing = upcoming()
        guard let index = existing.firstIndex(where: { $0.id == item.id }) else { return nil }
        skipped = []
        // Le morceau choisi devient le morceau en cours ; la suite est celle qui le suivait.
        return await rebuild(currentReference: reference(item), upcoming: Array(existing.dropFirst(index + 1)), start: true)
    }

    /// La file est remplacée autour d'un morceau : identifiants du catalogue si tous en ont,
    /// sinon morceaux de la bibliothèque.
    private func rebuild(current: MPMediaItem?, upcoming target: [StudyMusic.QueueItem]) async -> String? {
        guard let current else { return nil }
        let store = current.playbackStoreID == "0" ? nil : current.playbackStoreID
        let library: UInt64? = current.persistentID == 0 ? nil : current.persistentID
        return await rebuild(currentReference: (library, store), upcoming: target, start: player.playbackState == .playing,
                             position: player.currentPlaybackTime)
    }

    private func rebuild(currentReference: (library: UInt64?, store: String?), upcoming target: [StudyMusic.QueueItem],
                         start: Bool, position: TimeInterval = 0) async -> String? {
        let references = [currentReference] + target.map(reference)
        if references.allSatisfy({ $0.store != nil }) {
            player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: references.compactMap(\.store)))
        } else {
            let items = references.compactMap { $0.library.flatMap(libraryItem) }
            guard items.count == references.count else { return String(localized: "Un morceau de la file n'a pas pu être retrouvé.") }
            player.setQueue(with: MPMediaItemCollection(items: items))
        }
        try? await player.prepareToPlay()
        if position > 0 { player.currentPlaybackTime = position }
        if start { player.play() }
        settle()
        return nil
    }

    func play(_ songs: [Song], from index: Int, shuffled: Bool) async -> String? {
        let system = SystemMusicPlayer.shared
        system.queue = SystemMusicPlayer.Queue(for: songs, startingAt: songs[index])
        system.state.shuffleMode = shuffled ? .songs : .off
        return await start(system)
    }

    func play(_ collection: MusicCollection, shuffled: Bool) async -> String? {
        let system = SystemMusicPlayer.shared
        switch collection {
        case .album(let album): system.queue = [album]
        case .playlist(let playlist): system.queue = [playlist]
        }
        system.state.shuffleMode = shuffled ? .songs : .off
        return await start(system)
    }

    func enqueue(_ songs: [Song], next: Bool) async -> String? {
        let system = SystemMusicPlayer.shared
        guard player.nowPlayingItem != nil else { return await play(songs, from: 0, shuffled: false) }
        do {
            try await system.queue.insert(songs, position: next ? .afterCurrentEntry : .tail)
            settle()
            return nil
        } catch {
            log.error("file : \(error.localizedDescription, privacy: .public)")
            return MusicCatalogLookup.describe(error)
        }
    }

    private func start(_ system: SystemMusicPlayer) async -> String? {
        do {
            try await system.prepareToPlay()
            try await system.play()
            settle()
            return nil
        } catch {
            log.error("lecture : \(error.localizedDescription, privacy: .public)")
            return MusicCatalogLookup.describe(error)
        }
    }

    /// Le lecteur met un instant à refléter un geste.
    private func settle() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            refresh()
        }
    }
}

// MARK: - Mac : l'app Music

#else
/// Repris de `MusicAppSource` (Tournesol), mais **sans rien interroger en
/// boucle** : Music annonce chaque changement (`com.apple.Music.playerInfo`),
/// et c'est seulement alors qu'on le lit, d'un seul AppleScript (~40 ms de
/// processeur). Un rappel unique à la fin du morceau rattrape une annonce
/// manquée. La file (MediaRemote, par un `osascript` ponctuel) n'est lue que
/// pendant qu'« À suivre » est à l'écran.
///
/// Mesuré : l'ancien flux continu (quatre lectures par seconde) coûtait
/// ~3,5 % d'un cœur et 16 Mo en permanence. Au repos, ceci ne coûte rien.
///
/// Les commandes privées de MediaRemote (démarrer, mettre en file, modifier
/// la file) sont vérifiées après coup et ont chacune un repli.
@MainActor
private final class Backend {
    var onChange: (() -> Void)?
    private(set) var state = StudyMusic.NowPlaying()
    private(set) var volume: Double?
    private(set) var upNext: [StudyMusic.QueueItem] = []
    private(set) var canEditQueue = false

    private let script = MusicScript()
    private var reading: Reading?
    private var settings = Settings()
    private var queueSnapshot: MusicScript.QueueSnapshot?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshTask: Task<Void, Never>?
    private var endOfTrackTask: Task<Void, Never>?
    /// Tant qu'« À suivre » est à l'écran : une relecture lente (volume, file
    /// modifiés dans Music même, qui ne préviennent pas).
    private var queueWatch: Task<Void, Never>?
    private var queueLoading = false

    /// Un geste pas encore reflété par Music : il l'emporte un instant.
    private var playingOverride: (value: Bool, until: Date)?
    private var queueOverride: (items: [StudyMusic.QueueItem], until: Date)?
    private var settingsHoldUntil = Date.distantPast
    private var volumeTask: Task<Void, Never>?

    private var health = MusicNativeHealth()
    /// Les titres mis en file par l'app et pas encore joués : « Ajouter à la
    /// file » se range derrière eux, devant la suite de l'album.
    private var pendingAdds: [String] = []
    /// Une modification à la fois, chacune planifiée sur la file laissée par la précédente.
    private var editTask: Task<String?, Never>?

    private struct Reading: Equatable, Sendable {
        var playing = false
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double = 0
        var position: Double = 0
        var id: String?
        var readAt = Date()

        var key: String? {
            guard let title, !title.isEmpty else { return nil }
            return id ?? "\(title)|\(artist ?? "")"
        }
    }

    private struct Settings: Equatable, Sendable {
        var shuffle = false
        var repeatMode: StudyMusic.RepeatMode = .off
        var volume: Int?
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"),
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.Music" else { return }
                MainActor.assumeIsolated { self?.refresh(after: 1) }
            }))
        }
        refresh(after: 0)
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        refreshTask?.cancel()
        endOfTrackTask?.cancel()
        setQueueWanted(false)
    }

    func setQueueWanted(_ wanted: Bool) {
        queueWatch?.cancel()
        queueWatch = nil
        guard wanted else { return }
        queueWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                await self?.refreshQueue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    // MARK: Lire

    /// Plusieurs annonces d'un coup (changement de morceau) : une seule lecture.
    private func refresh(after delay: TimeInterval = 0.15) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.read()
        }
    }

    private func read() async {
        // Jamais de `tell application "Music"` si Music est fermé : il se lancerait.
        guard Self.isRunning else {
            if reading != nil || queueSnapshot != nil {
                reading = nil
                queueSnapshot = nil
                publish()
            }
            return
        }
        let source = """
            tell application "Music"
                set s to player state as text
                set sh to shuffle enabled
                set rp to (song repeat) as text
                set v to sound volume
                if s is "stopped" then return {s, sh, rp, v}
                try
                    set t to current track
                    return {s, sh, rp, v, name of t, artist of t, album of t, duration of t, player position, persistent ID of t}
                on error
                    return {s, sh, rp, v}
                end try
            end tell
            """
        let found = await script.run(source) { result -> (Reading, Settings)? in
            guard result.numberOfItems >= 4, let status = result.atIndex(1)?.stringValue else { return nil }
            let settings = Settings(shuffle: result.atIndex(2)?.booleanValue ?? false,
                                    repeatMode: result.atIndex(3)?.stringValue.flatMap(StudyMusic.RepeatMode.init(rawValue:)) ?? .off,
                                    volume: result.atIndex(4).map { Int($0.int32Value) })
            var reading = Reading(playing: status == "playing")
            if result.numberOfItems >= 10 {
                reading.title = result.atIndex(5)?.stringValue
                reading.artist = result.atIndex(6)?.stringValue
                reading.album = result.atIndex(7)?.stringValue
                reading.duration = result.atIndex(8)?.doubleValue ?? 0
                reading.position = result.atIndex(9)?.doubleValue ?? 0
                reading.id = result.atIndex(10)?.stringValue
            }
            return (reading, settings)
        }
        guard let (next, newSettings) = found else { return }
        let trackChanged = next.key != reading?.key
        reading = next
        if Date() > settingsHoldUntil { settings = newSettings }
        publish()
        scheduleEndOfTrack()
        if trackChanged, queueWatch != nil { await refreshQueue() }
    }

    /// Un seul rappel, à la fin prévue du morceau : rattrape une annonce manquée
    /// sans rien interroger entre-temps.
    private func scheduleEndOfTrack() {
        endOfTrackTask?.cancel()
        guard state.isPlaying, state.duration > 0 else { return }
        let remaining = max(0, state.duration - state.elapsed(at: Date()))
        endOfTrackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining + 0.8))
            guard !Task.isCancelled else { return }
            await self?.read()
        }
    }

    private func refreshQueue() async {
        guard Self.isRunning, !queueLoading else { return }
        queueLoading = true
        defer { queueLoading = false }
        guard let snapshot = await script.queueSnapshot() else { return }
        queueSnapshot = snapshot
        publish()
    }

    /// La file native : l'élément en cours (l'ancre des modifications) et ce qui suit.
    private var nativeQueue: (anchor: String?, items: [StudyMusic.QueueItem])? {
        guard let snapshot = queueSnapshot, snapshot.client == "com.apple.Music", !snapshot.queue.isEmpty else { return nil }
        let items = snapshot.queue
        let current = items.firstIndex { $0.id != nil && $0.id == snapshot.itemID }
            ?? items.firstIndex { MusicTrackMatcher.sameSong($0.title, reading?.title) }
            ?? 0
        let upcoming = items.dropFirst(current + 1).compactMap { item -> StudyMusic.QueueItem? in
            guard let id = item.id else { return nil }
            return StudyMusic.QueueItem(id: id, title: item.title,
                                        artist: item.artist.flatMap { $0.isEmpty ? nil : $0 },
                                        album: item.album.flatMap { $0.isEmpty ? nil : $0 },
                                        duration: item.duration ?? 0)
        }
        return (items[current].id, upcoming)
    }

    private func publish() {
        let now = Date()
        var next = StudyMusic.NowPlaying()
        if let reading, let title = reading.title, !title.isEmpty {
            next.title = title
            next.artist = reading.artist.flatMap { $0.isEmpty ? nil : $0 }
            next.album = reading.album.flatMap { $0.isEmpty ? nil : $0 }
            next.duration = reading.duration
            next.elapsed = reading.position
            next.readAt = reading.readAt
            next.isPlaying = reading.playing
            next.key = reading.key
        }
        if let override = playingOverride {
            if override.until > now, next.isPlaying != override.value {
                next.elapsed = next.elapsed(at: now)
                next.readAt = now
                next.isPlaying = override.value
            } else {
                playingOverride = nil
            }
        }
        next.shuffle = settings.shuffle
        next.repeatMode = settings.repeatMode

        let native = nativeQueue
        var queue = native?.items ?? []
        if let override = queueOverride {
            if override.until > now { queue = override.items } else { queueOverride = nil }
        }
        let editable = native?.anchor != nil && health.isUsable(NativeFeature.edit)
        let newVolume = settings.volume.map { Double($0) / 100 }

        guard next != state || newVolume != volume || queue != upNext || editable != canEditQueue else { return }
        state = next
        volume = newVolume
        upNext = queue
        canEditQueue = editable
        onChange?()
    }

    /// La pochette, réduite à 600 px : celle de Music est souvent en 3000 px,
    /// soit ~36 Mo une fois décodée, pour une vignette de 300 pt.
    func artwork() async -> NSImage? {
        let image = await script.run("tell application \"Music\" to get data of artwork 1 of current track") { descriptor -> CGImage? in
            descriptor.data.isEmpty ? nil : MusicArtworkThumbnail.make(from: descriptor.data)
        }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    // MARK: Commandes

    func send(_ command: Command) {
        switch command {
        case .toggle:
            let playing = state.isPlaying
            playingOverride = (!playing, Date().addingTimeInterval(1.5))
            script.send(playing ? "pause" : "play")
        case .next:
            script.send("next track")
        case .previous:
            script.send("back track")
        case .seek(let position):
            script.send("set player position to \(position)")
            if var current = reading {
                current.position = position
                current.readAt = Date()
                reading = current
            }
        case .shuffle(let on):
            settings.shuffle = on
            holdSettings()
            script.send("set shuffle enabled to \(on)")
        case .repeatMode(let mode):
            settings.repeatMode = mode
            holdSettings()
            script.send("set song repeat to \(mode.rawValue)")
        case .volume(let value):
            let level = Int((value * 100).rounded())
            settings.volume = level
            holdSettings()
            // Un curseur qu'on glisse : seule la dernière valeur part.
            volumeTask?.cancel()
            volumeTask = Task { [script] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                script.send("set sound volume to \(level)")
            }
        }
        publish()
        // Music n'annonce ni l'aléatoire, ni la répétition, ni le volume :
        // une lecture pour confirmer le geste.
        refresh(after: 0.4)
    }

    private func holdSettings() {
        settingsHoldUntil = Date().addingTimeInterval(1.5)
    }

    // MARK: Jouer

    /// Une playlist de la bibliothèque se joue par son nom ; le reste morceau par morceau.
    func play(_ collection: MusicCollection, shuffled: Bool) async -> String? {
        if case .playlist(let playlist) = collection, !playlist.id.rawValue.allSatisfy(\.isNumber),
           !playlist.id.rawValue.hasPrefix("pl.") {
            await ensureMusicRunning()
            settings.shuffle = shuffled
            holdSettings()
            script.send("set shuffle enabled to \(shuffled)")
            if await script.run("tell application \"Music\" to play user playlist \(MusicScript.quoted(playlist.name))", parse: { _ in true }) == true {
                pendingAdds = []
                return nil
            }
        }
        do {
            var songs = try await collection.songs()
            guard !songs.isEmpty else { return String(localized: "Rien à jouer.") }
            if shuffled { songs.shuffle() }
            return await play(songs, from: 0, shuffled: shuffled)
        } catch {
            return MusicCatalogLookup.describe(error)
        }
    }

    /// Trois chemins, du plus direct au plus sûr : la commande de Music
    /// (identifiants du catalogue), le morceau de la bibliothèque, puis
    /// l'adresse du morceau. La suite part ensuite dans « À suivre ».
    func play(_ songs: [Song], from index: Int, shuffled: Bool) async -> String? {
        let slice = Array(songs[index...].prefix(100))
        guard let first = slice.first else { return nil }
        await ensureMusicRunning()
        // Notre ordre fait foi : l'aléatoire de Music le mélangerait encore.
        settings.shuffle = false
        holdSettings()
        script.send("set shuffle enabled to false")

        let ids = await catalogIDs(for: slice)
        pendingAdds = []

        // 1. La commande de Music : toute la file d'un coup.
        if ids[0] != nil, await musicHoldsNowPlaying() {
            let storeIDs = ids.compactMap { $0 }
            if await attemptNative(.start, reload: .state, send: { script.startPlayback(storeIDs: storeIDs) },
                                   confirm: { self.isPlaying(first.title) }) {
                return nil
            }
        }
        let rest = Array(zip(slice.dropFirst(), ids.dropFirst()))

        // 2. Le morceau de la bibliothèque, par AppleScript.
        if let libraryID = await libraryTrackID(matching: first) {
            script.send("play (track id \(libraryID) of library playlist 1)")
            if await waitUntilPlaying(first.title) {
                await queue(rest)
                return nil
            }
        }

        // 3. L'adresse du morceau dans le catalogue.
        guard let catalogID = ids[0] else {
            return String(localized: "Ce morceau n'est pas dans le catalogue Apple Music.")
        }
        let storefront = (try? await MusicDataRequest.currentCountryCode) ?? Locale.current.region?.identifier.lowercased() ?? "ch"
        log.notice("lecture par l'adresse du morceau")
        script.send("open location \"music://music.apple.com/\(storefront)/song/\(catalogID)\"")
        guard await waitUntilPlaying(first.title, timeout: 8) else {
            return String(localized: "Music n'a pas pu lancer ce morceau.")
        }
        await queue(rest)
        return nil
    }

    /// La suite d'un morceau lancé seul.
    private func queue(_ rest: [(Song, String?)]) async {
        let found = rest.compactMap { song, id in id.map { (song.title, $0) } }
        guard !found.isEmpty else { return }
        script.insertIntoQueue(storeIDs: found.map(\.1), after: nil)
        pendingAdds = found.map(\.0)
    }

    func enqueue(_ songs: [Song], next: Bool) async -> String? {
        guard state.hasTrack else { return await play(songs, from: 0, shuffled: false) }
        let found = zip(songs, await catalogIDs(for: songs)).compactMap { song, id in id.map { (song.title, $0) } }
        guard let firstTitle = found.first?.0 else {
            return String(localized: "Ce morceau n'est pas dans le catalogue Apple Music.")
        }
        return await serialized { [self] in
            // Derrière ce qu'on a déjà mis en file, devant la suite de Music.
            let upcoming = nativeQueue?.items ?? []
            let waiting = zip(upcoming, pendingAdds).prefix(while: { MusicTrackMatcher.sameSong($0.0.title, $0.1) }).count
            pendingAdds = Array(pendingAdds.prefix(waiting))
            let anchor = next || waiting == 0 ? nil : upcoming[waiting - 1].id
            let position = next ? 0 : waiting
            let titles = found.map(\.0)
            let send = { self.script.insertIntoQueue(storeIDs: found.map(\.1), after: anchor) }
            // Sans lecture de la file, on ne peut rien vérifier : on fait confiance.
            if nativeQueue == nil {
                send()
            } else if !(await attemptNative(.insert, reload: .queue, send: send, confirm: { self.holds(firstTitle, at: position) })) {
                return String(localized: "Music n'a pas accepté l'ajout à la file.")
            }
            if next { pendingAdds.insert(contentsOf: titles, at: 0) } else { pendingAdds.append(contentsOf: titles) }
            return nil
        }
    }

    // MARK: À suivre

    func playQueued(_ item: StudyMusic.QueueItem) async -> String? {
        await serialized { [self] in
            let worked = await attemptNative(.edit, reload: .state, send: {
                self.script.editQueue([.play(item.id)])
                self.script.send("play")
            }, confirm: { self.isPlaying(item.title) })
            return worked ? nil : String(localized: "Music n'a pas pu sauter à ce morceau.")
        }
    }

    func editQueue(to target: [StudyMusic.QueueItem]) async -> String? {
        await serialized { [self] in
            guard let native = nativeQueue, let anchor = native.anchor else { return nil }
            let operations = MusicQueuePlanner.plan(target: target.map(\.id), upcoming: native.items.map(\.id), anchor: anchor)
                .map { operation -> MusicScript.QueueOperation in
                    switch operation {
                    case .remove(let id): return .remove(id)
                    case .move(let id, let after): return .move(id, after: after)
                    }
                }
            guard !operations.isEmpty else { return nil }
            queueOverride = (target, Date().addingTimeInterval(4))
            publish()
            let worked = await attemptNative(.edit, reload: .queue, send: { self.script.editQueue(operations) }, confirm: {
                MusicQueuePlanner.matches(self.nativeQueue?.items.map(\.id) ?? [], target.map(\.id))
            })
            queueOverride = nil
            publish()
            if worked { await read() }
            return worked ? nil : String(localized: "Music n'a pas pris la modification de la file.")
        }
    }

    // MARK: Outils

    private func isPlaying(_ title: String?) -> Bool {
        MusicTrackMatcher.sameSong(state.title, title)
    }

    private func holds(_ title: String, at index: Int) -> Bool {
        let items = nativeQueue?.items ?? []
        return items.indices.contains(index) && MusicTrackMatcher.sameSong(items[index].title, title)
    }

    private enum NativeFeature: Hashable { case start, insert, edit }
    /// Ce qu'il faut relire pour voir l'effet d'une commande.
    private enum Reload { case state, queue }

    /// Envoie une commande privée et attend d'en voir l'effet. On ne relit
    /// qu'ici, juste après un geste, et quelques secondes au plus.
    private func attemptNative(_ feature: NativeFeature, reload: Reload, timeout: TimeInterval = 4,
                               send: () -> Void, confirm: () -> Bool) async -> Bool {
        guard health.isUsable(feature) else { return false }
        let started = Date()
        send()
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(300))
            switch reload {
            case .state: await read()
            case .queue: await refreshQueue()
            }
            if confirm() {
                health.succeeded(feature)
                return true
            }
        }
        let count = health.failed(feature)
        log.error("commande native \(String(describing: feature), privacy: .public) sans effet (\(count) de suite)")
        publish()
        return false
    }

    private func serialized(_ work: @escaping @MainActor () async -> String?) async -> String? {
        let previous = editTask
        let task = Task { @MainActor in
            _ = await previous?.value
            return await work()
        }
        editTask = task
        return await task.value
    }

    /// Attend que Music joue ce morceau ; un morceau chargé mais à l'arrêt est relancé une fois.
    private func waitUntilPlaying(_ title: String, timeout: TimeInterval = 5) async -> Bool {
        let started = Date()
        var pressedPlay = false
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(250))
            await read()
            guard isPlaying(title) else { continue }
            if state.isPlaying { return true }
            if !pressedPlay {
                script.send("play")
                pressedPlay = true
            }
        }
        return isPlaying(title)
    }

    /// La commande de Music passe par l'app qui tient « À l'écoute » : si c'est
    /// Safari, elle s'y perdrait — on n'attend pas quatre secondes pour rien.
    private func musicHoldsNowPlaying() async -> Bool {
        await refreshQueue()
        return queueSnapshot?.client == "com.apple.Music"
    }

    /// Music, lancé sans se montrer : le mode étude le laisse jouer derrière.
    private func ensureMusicRunning() async {
        guard !Self.isRunning else { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        for _ in 0..<24 {
            if Self.isRunning, await script.run("tell application \"Music\" to return player state as text", parse: { _ in true }) == true {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private nonisolated struct Candidate: Sendable {
        let id: Int
        let title: String
        let artist: String
        let album: String?
        let duration: Double?
    }

    /// Le morceau dans la bibliothèque de Music, s'il y est.
    private func libraryTrackID(matching song: Song) async -> Int? {
        let source = """
            tell application "Music"
                set found to search library playlist 1 for \(MusicScript.quoted(song.title)) only songs
                set output to {}
                repeat with t in found
                    set end of output to {id of t, name of t, artist of t, album of t, duration of t}
                end repeat
                return output
            end tell
            """
        let candidates = await script.run(source) { list -> [Candidate]? in
            guard list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { index in
                guard let entry = list.atIndex(index), entry.numberOfItems >= 5, let id = entry.atIndex(1)?.int32Value else { return nil }
                return Candidate(id: Int(id), title: entry.atIndex(2)?.stringValue ?? "", artist: entry.atIndex(3)?.stringValue ?? "",
                                 album: entry.atIndex(4)?.stringValue, duration: entry.atIndex(5)?.doubleValue)
            }
        } ?? []
        let wanted = MusicTrackReference(catalogID: nil, title: song.title, artist: song.artistName,
                                         album: song.albumTitle, duration: song.duration ?? 0)
        let scored = candidates.map { ($0.id, MusicTrackMatcher.score(title: $0.title, artist: $0.artist, album: $0.album,
                                                                       duration: $0.duration, against: wanted)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= MusicTrackMatcher.acceptable else { return nil }
        return best.0
    }

    /// L'identifiant du catalogue de chaque morceau (nil s'il n'y est pas) :
    /// ceux de la bibliothèque se retrouvent par le titre, l'artiste et la durée.
    private func catalogIDs(for songs: [Song]) async -> [String?] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, song) in songs.enumerated() {
                group.addTask {
                    let id = song.id.rawValue
                    if !id.isEmpty, id.allSatisfy(\.isNumber) { return (index, id) }
                    let reference = MusicTrackReference(catalogID: nil, title: song.title, artist: song.artistName,
                                                        album: song.albumTitle, duration: song.duration ?? 0)
                    return (index, await MusicCatalogLookup.song(for: reference)?.id.rawValue)
                }
            }
            var found: [Int: String] = [:]
            for await (index, id) in group { found[index] = id }
            return songs.indices.map { found[$0] }
        }
    }
}

/// Les scripts envoyés à Music, sur une file à eux (repris de Tournesol).
private final class MusicScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ch.polymestre.music-script", qos: .userInitiated)

    /// Dernier état connu, lu et écrit sur la file seulement.
    private var state = StudyMusic.Automation.undetermined

    /// -1743 : « l'utilisateur·rice n'a pas autorisé ce contrôle » (Automatisation) ; une
    /// réponse sans erreur : accordée.
    private func note(_ error: NSDictionary?) {
        let next: StudyMusic.Automation
        if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { next = .denied }
        else if error == nil { next = .granted }
        else { return }
        guard next != state else { return }
        state = next
        Task { @MainActor in StudyMusic.shared.automation = next }
    }

    func send(_ command: String) {
        queue.async { [self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Music\" to \(command)")?.executeAndReturnError(&error)
            if let error { log.error("script [\(command, privacy: .public)] : \(String(describing: error), privacy: .public)") }
            note(error)
        }
    }

    func run<T: Sendable>(_ source: String, parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { log.error("script : \(String(describing: error), privacy: .public)") }
                note(error)
                continuation.resume(returning: error == nil ? result.flatMap(parse) : nil)
            }
        }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// L'app qui tient « À l'écoute », l'élément en cours et la file (60 au
    /// plus), lus une fois par MediaRemote. `osascript` est un binaire d'Apple :
    /// MediaRemote lui répond, pas à nous. ~50 ms de processeur, à la demande.
    struct QueueSnapshot: Decodable, Equatable, Sendable {
        var client: String
        var itemID: String?
        var queue: [Item]

        struct Item: Decodable, Equatable, Sendable {
            var id: String?
            var title: String?
            var artist: String?
            var album: String?
            var duration: Double?

            private enum CodingKeys: String, CodingKey { case id, title, artist, album, duration }

            // Un champ mal typé ne doit pas faire tomber toute la file.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try? container.decodeIfPresent(String.self, forKey: .id)
                title = try? container.decodeIfPresent(String.self, forKey: .title)
                artist = try? container.decodeIfPresent(String.self, forKey: .artist)
                album = try? container.decodeIfPresent(String.self, forKey: .album)
                duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
            }
        }
    }

    func queueSnapshot() async -> QueueSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", "-e", Self.queueSnapshotScript]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: try? JSONDecoder().decode(QueueSnapshot.self, from: data))
                } catch {
                    log.error("osascript : \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static let queueSnapshotScript = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        function run() {
          const Request = $.NSClassFromString('MRNowPlayingRequest')
          const out = { client: '', itemID: null, queue: [] }
          try {
            out.client = ObjC.unwrap(Request.localNowPlayingPlayerPath.client.bundleIdentifier) || ''
            out.itemID = ObjC.unwrap(Request.localNowPlayingItem.identifier) || null
            if (out.client !== 'com.apple.Music') return JSON.stringify(out)
            const destination = $.NSClassFromString('MRDestination').localDestination
            const configuration = $.NSClassFromString('MRNowPlayingControllerConfiguration').alloc.initWithDestination(destination)
            const request = $.NSClassFromString('MRPlaybackQueueRequest').defaultPlaybackQueueRequest
            request.setIncludeMetadata(true)
            request.setIncludeInfo(true)
            request.setLocation(0)
            request.setLength(60)
            configuration.setPlaybackQueueRequest(request)
            configuration.setRequestPlaybackQueue(true)
            const controller = $.NSClassFromString('MRNowPlayingController').alloc.initWithConfiguration(configuration)
            controller.beginLoadingUpdates
            // La file arrive en quelques dizaines de millisecondes ; 1,5 s au plus.
            for (let i = 0; i < 30; i++) {
              $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05))
              const items = controller.response.playbackQueue.contentItems
              if (!items.isNil() && items.count > 0) break
            }
            const items = controller.response.playbackQueue.contentItems
            if (!items.isNil()) {
              for (let i = 0; i < items.count; i++) {
                const item = items.objectAtIndex(i)
                const md = item.metadata
                out.queue.push({ id: ObjC.unwrap(item.identifier), title: ObjC.unwrap(md.title),
                                 artist: ObjC.unwrap(md.trackArtistName), album: ObjC.unwrap(md.albumName), duration: md.duration })
              }
            }
          } catch (e) {}
          return JSON.stringify(out)
        }
        """

    /// Une modification de la file : retirer (129), déplacer (130) ou jouer (131).
    struct QueueOperation: Encodable, Sendable {
        var command: Int
        var id: String
        var after: String?

        static func remove(_ id: String) -> Self { Self(command: 129, id: id) }
        static func move(_ id: String, after: String) -> Self { Self(command: 130, id: id, after: after) }
        static func play(_ id: String) -> Self { Self(command: 131, id: id) }
    }

    func editQueue(_ operations: [QueueOperation]) {
        guard !operations.isEmpty, let data = try? JSONEncoder().encode(operations),
              let json = String(data: data, encoding: .utf8) else { return }
        runJXA(Self.queueEditScript, arguments: [json])
    }

    /// Ajoute des morceaux juste après celui en cours, ou derrière l'élément `anchor`.
    ///
    /// La position 3 veut une ancre : sans elle, Music ignorait la demande —
    /// c'est ce qui rendait « Ajouter à la file » muet.
    func insertIntoQueue(storeIDs: [String], after anchor: String?) {
        sendQueuePayload(command: 125, storeIDs: storeIDs, immediate: false, position: anchor == nil ? 0 : 3, after: anchor)
    }

    /// Remplace la file et lance le premier morceau.
    func startPlayback(storeIDs: [String]) {
        sendQueuePayload(command: 122, storeIDs: storeIDs, immediate: true, position: nil, after: nil)
    }

    /// Music refuse toute autre forme que cette plist (voir `docs/native-queue.md` de Tournesol).
    private func sendQueuePayload(command: Int, storeIDs: [String], immediate: Bool, position: Int?, after anchor: String?) {
        let payload: [String: Any] = ["PQty": 3, "PQst": storeIDs, "PQip": immediate, "PQri": 0, "PQtr": 0, "PQts": 0]
        guard !storeIDs.isEmpty, storeIDs.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) else { return }
        runJXA(Self.queuePayloadScript, arguments: [data.base64EncodedString(), position.map(String.init) ?? "", String(command), anchor ?? ""])
    }

    private func runJXA(_ source: String, arguments: [String]) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log.error("osascript : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let queuePayloadScript = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        function run(argv) {
          const Request = $.NSClassFromString('MRNowPlayingRequest')
          const request = Request.alloc.initWithPlayerPath(Request.localNowPlayingPlayerPath)
          const options = $.NSMutableDictionary.dictionary
          options.setObjectForKey($.NSData.alloc.initWithBase64EncodedStringOptions(argv[0], 0), 'kMRMediaRemoteOptionSystemAppPlaybackQueueData')
          if (argv[1] !== '') options.setObjectForKey($.NSNumber.numberWithInt(parseInt(argv[1])), 'kMRMediaRemoteOptionPlaybackQueueInsertionPosition')
          if (argv[3]) options.setObjectForKey(argv[3], 'kMRMediaRemoteOptionInsertAfterContentItemID')
          request.sendCommandOptionsQueueCompletion(parseInt(argv[2]), options, $(), $())
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.5))
        }
        """

    private static let queueEditScript = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        function run(argv) {
          const Request = $.NSClassFromString('MRNowPlayingRequest')
          const request = Request.alloc.initWithPlayerPath(Request.localNowPlayingPlayerPath)
          for (const op of JSON.parse(argv[0])) {
            const options = $.NSMutableDictionary.dictionary
            options.setObjectForKey(op.id, 'kMRMediaRemoteOptionContentItemID')
            if (op.after) options.setObjectForKey(op.after, 'kMRMediaRemoteOptionInsertAfterContentItemID')
            request.sendCommandOptionsQueueCompletion(op.command, options, $(), $())
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.15))
          }
        }
        """
}

/// Une commande privée qui échoue deux fois de suite est laissée de côté dix
/// minutes : son repli prend le relais (repris de `NativeHealth`).
private struct MusicNativeHealth {
    private var failures: [AnyHashable: (count: Int, last: Date)] = [:]

    func isUsable(_ feature: AnyHashable) -> Bool {
        guard let failure = failures[feature], failure.count >= 2 else { return true }
        return Date().timeIntervalSince(failure.last) > 600
    }

    mutating func succeeded(_ feature: AnyHashable) { failures[feature] = nil }

    @discardableResult
    mutating func failed(_ feature: AnyHashable) -> Int {
        let count = (failures[feature]?.count ?? 0) + 1
        failures[feature] = (count, Date())
        return count
    }
}
#endif

/// La couleur d'une pochette : sa moyenne, ramenée vers une teinte calme
/// qui tient sur le papier de nuit (ni néon, ni boue).
enum MusicArtworkTint {
    static func average(of image: PlatformImage) -> Color? {
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cgImage = image.cgImage else { return nil }
        #endif
        // Un pixel : le système fait la moyenne en réduisant l'image.
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue: CGFloat = 0
        if delta > 0 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC == 0 ? 0 : delta / maxC
        return Color(hue: hue, saturation: min(saturation * 1.1, 0.55), brightness: min(max(maxC, 0.45), 0.7))
    }
}

/// Une pochette réduite sans décoder l'image entière.
enum MusicArtworkThumbnail {
    static func make(from data: Data, maxPixels: Int = 600) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Les modifications qui font passer la file de Music de `upcoming` à `target`
/// (repris de `QueuePlanner`, Tournesol). Pur, donc vérifié dans `Validation`.
enum MusicQueuePlanner {
    /// Music ne montre pas plus d'éléments que cela après le morceau en cours.
    static let visibleLimit = 59

    enum Operation: Equatable {
        case remove(String)
        case move(String, after: String)
    }

    /// Retirer, puis remonter un à un : Music sort l'élément avant de compter,
    /// donc un élément qu'on descend atterrit une place trop tôt — on ne fait
    /// que remonter.
    static func plan(target: [String], upcoming: [String], anchor: String) -> [Operation] {
        let wanted = target.filter(upcoming.contains)
        var operations = upcoming.filter { !wanted.contains($0) }.map(Operation.remove)
        var order = upcoming.filter(wanted.contains)
        for (position, id) in wanted.enumerated() where order[position] != id {
            guard let from = order.firstIndex(of: id) else { continue }
            order.insert(order.remove(at: from), at: position)
            operations.append(.move(id, after: position == 0 ? anchor : wanted[position - 1]))
        }
        return operations
    }

    /// La file montre-t-elle `target` (en tête, si Music en tronque la fin) ?
    static func matches(_ upcoming: [String], _ target: [String]) -> Bool {
        guard upcoming.count >= target.count, upcoming.count == target.count || upcoming.count >= visibleLimit else { return false }
        return zip(upcoming, target).allSatisfy { $0.0 == $0.1 }
    }
}

// MARK: - Catalogue

/// Un morceau tel qu'on le connaît (titre, artiste, album, durée).
struct MusicTrackReference: Equatable, Sendable {
    var catalogID: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval
}

/// Retrouver un morceau dans le catalogue (repris de `CatalogLookup`).
enum MusicCatalogLookup {
    static func song(for track: MusicTrackReference) async -> Song? {
        guard MusicAuthorization.currentStatus == .authorized else { return nil }
        if let id = track.catalogID {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            return try? await request.response().items.first
        }
        guard let title = track.title else { return nil }
        var best: (song: Song, score: Int)?
        for term in searchTerms(title: title, artist: track.artist, album: track.album) {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            for song in (try? await request.response().songs) ?? [] {
                let score = MusicTrackMatcher.score(title: song.title, artist: song.artistName, album: song.albumTitle,
                                                    duration: song.duration, against: track)
                if score > best?.score ?? 0 { best = (song, score) }
            }
            if let best, best.score >= MusicTrackMatcher.confident { break }
        }
        return best.flatMap { $0.score >= MusicTrackMatcher.acceptable ? $0.song : nil }
    }

    static func artworkURL(for track: MusicTrackReference) async -> URL? {
        guard let url = await song(for: track)?.artwork?.url(width: 600, height: 600), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private static func searchTerms(title: String, artist: String?, album: String?) -> [String] {
        let base = [title, artist].compactMap { $0 }.joined(separator: " ")
        guard let album, !album.isEmpty else { return [base] }
        return ["\(base) \(album)", base]
    }

    /// Une erreur de MusicKit, dite simplement.
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "" }
        if let url = error as? URLError, url.code == .notConnectedToInternet || url.code == .networkConnectionLost {
            return String(localized: "Pas de connexion. Vérifie le réseau et réessaie.")
        }
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("developer token") || message.localizedCaseInsensitiveContains("permission") {
            return String(localized: "Apple Music a refusé la demande : vérifie que MusicKit est activé pour l'identifiant de l'app et que l'accès est permis.") + " (\(message))"
        }
        return message
    }
}

/// Deux morceaux sont-ils le même ? (repris de `TrackMatcher`)
enum MusicTrackMatcher {
    static let loose = 4
    static let acceptable = 8
    static let confident = 14

    static func score(title: String, artist: String, album: String?, duration: TimeInterval?, against track: MusicTrackReference) -> Int {
        guard let wanted = track.title else { return 0 }
        var score = 0
        if normalize(title) == normalize(wanted) {
            score += 6
        } else if stripDecorations(title) == stripDecorations(wanted) {
            score += 1
        } else {
            return 0
        }
        if let wantedArtist = track.artist {
            let lhs = normalize(artist), rhs = normalize(wantedArtist)
            if lhs == rhs { score += 3 } else if lhs.contains(rhs) || rhs.contains(lhs) { score += 2 } else { score -= 3 }
        }
        if let wantedAlbum = track.album, let album, stripAlbumSuffix(album) == stripAlbumSuffix(wantedAlbum) {
            score += 5
        }
        if let duration, track.duration > 0 {
            let delta = abs(duration - track.duration)
            if delta < 2 { score += 3 } else if delta < 5 { score += 1 } else if delta > 15 { score -= 3 }
        }
        return score
    }

    /// Le morceau en cours, normalisé une fois pour toutes les lignes.
    struct CurrentSong: Equatable {
        let title: String
        let bare: String
        let artist: String

        init(title: String, artist: String?) {
            self.title = MusicTrackMatcher.normalize(title)
            self.bare = MusicTrackMatcher.stripDecorations(title)
            self.artist = MusicTrackMatcher.normalize(artist ?? "")
        }

        func matches(title other: String, artist otherArtist: String) -> Bool {
            guard MusicTrackMatcher.normalize(otherArtist) == artist else { return false }
            return MusicTrackMatcher.normalize(other) == title || MusicTrackMatcher.stripDecorations(other) == bare
        }
    }

    static func sameSong(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return normalize(lhs) == normalize(rhs) || stripDecorations(lhs) == stripDecorations(rhs)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    static func stripDecorations(_ text: String) -> String {
        normalize(text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression))
    }

    private static func stripAlbumSuffix(_ text: String) -> String {
        normalize(text.replacingOccurrences(of: #"\s+-\s+(Single|EP)$"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }
}

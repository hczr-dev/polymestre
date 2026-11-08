import MusicKit
import SwiftUI

// Chercher et parcourir Apple Music sans quitter le mode étude. Repris de
// `SearchView` (Tournesol) : la même recherche, les mêmes pages d'album,
// d'artiste et de playlist, sur le papier de nuit.

enum MusicDestination: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct MusicBrowseItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let artwork: Artwork?
    let destination: MusicDestination
}

struct MusicBrowseSection: Identifiable {
    let id: String
    let title: String
    let items: [MusicBrowseItem]
}

private extension Album {
    var browseItem: MusicBrowseItem {
        MusicBrowseItem(id: "album-\(id.rawValue)", title: title, subtitle: artistName, artwork: artwork, destination: .album(self))
    }
}

private extension Playlist {
    var browseItem: MusicBrowseItem {
        MusicBrowseItem(id: "playlist-\(id.rawValue)", title: name, subtitle: curatorName, artwork: artwork, destination: .playlist(self))
    }
}

struct MusicSearchResults {
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []

    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// Ce qu'on a écouté, ses playlists, les suggestions. Ce qui ne se charge pas
/// est simplement laissé de côté.
enum MusicBrowseLoader {
    static func sections() async -> [MusicBrowseSection] {
        async let recents = recentlyPlayed()
        async let playlists = libraryPlaylists()
        async let recommended = recommendations()
        return await ([recents, playlists].compactMap { $0 }) + recommended
    }

    private static func recentlyPlayed() async -> MusicBrowseSection? {
        var request = MusicRecentlyPlayedContainerRequest()
        request.limit = 12
        guard let response = try? await request.response() else { return nil }
        let items = response.items.compactMap { item -> MusicBrowseItem? in
            switch item {
            case .album(let album): return album.browseItem
            case .playlist(let playlist): return playlist.browseItem
            default: return nil
            }
        }
        return items.isEmpty ? nil : MusicBrowseSection(id: "recents", title: String(localized: "Écouté récemment"), items: items)
    }

    // La bibliothèque du Mac plante sur certains tris : les playlists se trient ici.
    private static func libraryPlaylists() async -> MusicBrowseSection? {
        guard let response = try? await MusicLibraryRequest<Playlist>().response() else { return nil }
        let recent = response.items.sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }.prefix(25)
        let items = recent.map(\.browseItem)
        return items.isEmpty ? nil : MusicBrowseSection(id: "library", title: String(localized: "Tes playlists"), items: items)
    }

    private static func recommendations() async -> [MusicBrowseSection] {
        var request = MusicPersonalRecommendationsRequest()
        request.limit = 6
        guard let response = try? await request.response() else { return [] }
        return response.recommendations.compactMap { recommendation in
            let items = recommendation.items.compactMap { item -> MusicBrowseItem? in
                switch item {
                case .album(let album): return album.browseItem
                case .playlist(let playlist): return playlist.browseItem
                default: return nil
                }
            }
            guard let title = recommendation.title, !items.isEmpty else { return nil }
            return MusicBrowseSection(id: "recommendation-\(recommendation.id.rawValue)", title: title, items: items)
        }
    }
}

extension MusicDestination {
    /// Ce qui se joue d'un geste depuis une vignette (pas un artiste).
    var collection: MusicCollection? {
        switch self {
        case .album(let album): return .album(album)
        case .playlist(let playlist): return .playlist(playlist)
        case .artist: return nil
        }
    }
}

// MARK: - Mesures

/// Les mesures du lecteur, prises une fois : des étagères de pochettes comme
/// dans Music, plus serrées sur l'iPhone.
enum MusicMetrics {
    #if os(macOS)
    static let card: CGFloat = 148
    static let gutter: CGFloat = 24
    static let rowArtwork: CGFloat = 40
    #else
    static let card: CGFloat = 136
    static let gutter: CGFloat = 16
    static let rowArtwork: CGFloat = 44
    #endif
    static let cardSpacing: CGFloat = 16
    static let artworkCorner: CGFloat = 8
}

// MARK: - Chercher, parcourir

/// Chercher, parcourir, jouer.
struct MusicBrowser: View {
    @State private var music = StudyMusic.shared
    @State private var query: String
    @State private var path: [MusicDestination] = []

    /// `query` : une recherche déjà tapée (captures, essais).
    init(query: String = "") {
        _query = State(initialValue: query)
    }
    @State private var results = MusicSearchResults()
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var browse: [MusicBrowseSection] = []
    @State private var browseLoaded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if music.isAuthorized { searchField }
                ScrollView {
                    content
                        .padding(.bottom, 32)
                }
                .scrollIndicators(.automatic)
            }
            .background(StudyPalette.ground)
            .navigationDestination(for: MusicDestination.self) { destination in
                Group {
                    switch destination {
                    case .album(let album): MusicCollectionView(source: .album(album))
                    case .playlist(let playlist): MusicCollectionView(source: .playlist(playlist))
                    case .artist(let artist): MusicArtistView(artist: artist)
                    }
                }
                .background(StudyPalette.ground)
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .task(id: query) { await search() }
            .task(id: music.isAuthorized) { await loadBrowse() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !music.isAuthorized {
            MusicAccessView().padding(.top, 60)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("La recherche n'a pas abouti", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Réessayer") { Task { await search(debounce: false) } }
                    .buttonStyle(PaperButtonStyle())
            }
            .padding(.top, 60)
        } else if query.isEmpty {
            if browse.isEmpty {
                if browseLoaded {
                    ContentUnavailableView("Apple Music", systemImage: "music.note",
                                           description: Text("Cherche un morceau, un album, une playlist."))
                        .padding(.top, 60)
                } else {
                    ProgressView().controlSize(.small).padding(.top, 80)
                }
            } else {
                MusicHome(sections: browse)
            }
        } else if results.isEmpty {
            if isSearching {
                ProgressView().controlSize(.small).padding(.top, 80)
            } else {
                ContentUnavailableView.search(text: query).padding(.top, 60)
            }
        } else {
            MusicResults(results: results)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(StudyPalette.inkTertiary)
            TextField("Rechercher dans Apple Music", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(StudyPalette.ink)
                .focused($searchFocused)
                .onSubmit { Task { await search(debounce: false) } }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if isSearching, !query.isEmpty {
                ProgressView().controlSize(.mini)
            }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudyPalette.inkTertiary)
                    .accessibilityLabel("Effacer")
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? StudyPalette.inkTertiary : .clear, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
        .padding(.horizontal, MusicMetrics.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func loadBrowse() async {
        guard music.isAuthorized, browse.isEmpty else { return }
        browse = await MusicBrowseLoader.sections()
        browseLoaded = true
    }

    private func search(debounce: Bool = true) async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard music.isAuthorized, !term.isEmpty else {
            results = MusicSearchResults()
            errorMessage = nil
            return
        }
        if debounce { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
        request.limit = 15
        do {
            let response = try await request.response()
            guard !Task.isCancelled else { return }
            results = MusicSearchResults(songs: Array(response.songs), albums: Array(response.albums),
                                         artists: Array(response.artists), playlists: Array(response.playlists))
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            let message = MusicCatalogLookup.describe(error)
            if !message.isEmpty { errorMessage = message }
        }
    }
}

/// L'accueil : ce qu'on a écouté et les suggestions en étagères, ses
/// playlists en grille.
private struct MusicHome: View {
    let sections: [MusicBrowseSection]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(sections) { section in
                if section.id == "library" {
                    VStack(alignment: .leading, spacing: 12) {
                        MusicShelfTitle(section.title)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: MusicMetrics.card, maximum: MusicMetrics.card + 40),
                                                     spacing: MusicMetrics.cardSpacing, alignment: .top)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(section.items) { item in
                                MusicCard(item: item, fills: true)
                            }
                        }
                        .padding(.horizontal, MusicMetrics.gutter)
                    }
                } else {
                    MusicShelf(title: section.title, items: section.items)
                }
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Les résultats : les morceaux d'abord, puis une étagère par genre.
struct MusicResults: View {
    let results: MusicSearchResults
    @State private var music = StudyMusic.shared

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if !results.songs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MusicShelfTitle(String(localized: "Morceaux"))
                    VStack(spacing: 0) {
                        ForEach(Array(results.songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(song: song) { music.play(Array(results.songs), from: index) }
                        }
                    }
                    .padding(.horizontal, MusicMetrics.gutter - 8)
                }
            }
            if !results.artists.isEmpty {
                MusicShelf(title: "Artistes", items: results.artists.map {
                    MusicBrowseItem(id: "artist-\($0.id.rawValue)", title: $0.name, subtitle: nil, artwork: $0.artwork, destination: .artist($0))
                })
            }
            if !results.albums.isEmpty {
                MusicShelf(title: "Albums", items: results.albums.map {
                    MusicBrowseItem(id: "album-\($0.id.rawValue)", title: $0.title, subtitle: $0.artistName, artwork: $0.artwork, destination: .album($0))
                })
            }
            if !results.playlists.isEmpty {
                MusicShelf(title: String(localized: "Playlists"), items: results.playlists.map {
                    MusicBrowseItem(id: "playlist-\($0.id.rawValue)", title: $0.name, subtitle: $0.curatorName, artwork: $0.artwork, destination: .playlist($0))
                })
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Un titre d'étagère : la serif du carnet.
private struct MusicShelfTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(verbatim: Bundle.main.localizedString(forKey: title, value: title, table: nil))
            .font(Carnet.serif(.title3, weight: .semibold))
            .foregroundStyle(StudyPalette.ink)
            .padding(.horizontal, MusicMetrics.gutter)
    }
}

/// Une rangée de vignettes qui défile de côté.
private struct MusicShelf: View {
    let title: String
    let items: [MusicBrowseItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MusicShelfTitle(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MusicMetrics.cardSpacing) {
                    ForEach(items) { item in
                        MusicCard(item: item)
                            .frame(width: MusicMetrics.card)
                    }
                }
                .padding(.horizontal, MusicMetrics.gutter)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Une vignette : la pochette, le titre, le sous-titre. Au survol, un bouton
/// de lecture pour jouer sans ouvrir.
private struct MusicCard: View {
    let item: MusicBrowseItem
    /// Dans une grille : la pochette prend la largeur de la colonne.
    var fills = false
    @State private var music = StudyMusic.shared
    @State private var hovering = false

    private var round: Bool {
        if case .artist = item.destination { return true }
        return false
    }

    var body: some View {
        NavigationLink(value: item.destination) {
            VStack(alignment: round ? .center : .leading, spacing: 7) {
                artwork
                VStack(alignment: round ? .center : .leading, spacing: 1) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(StudyPalette.ink)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: round ? .center : .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settledHover($hovering)
        .contextMenu {
            if let collection = item.destination.collection {
                Button("Lire", systemImage: "play.fill") { music.play(collection) }
                Button("Lire en aléatoire", systemImage: "shuffle") { music.play(collection, shuffled: true) }
            }
        }
    }

    private var artwork: some View {
        MusicArtwork(artwork: item.artwork, side: nil, radius: round ? .infinity : MusicMetrics.artworkCorner)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: fills ? nil : MusicMetrics.card)
            .overlay(alignment: .bottomTrailing) {
                if let collection = item.destination.collection, hovering {
                    Button { music.play(collection) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.92), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(MusicPressStyle())
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .help("Lire")
                    .accessibilityLabel("Lire")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: round ? 999 : MusicMetrics.artworkCorner, style: .continuous)
                    .fill(.black.opacity(hovering ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Avant la première écoute : demander l'accès à Apple Music.
struct MusicAccessView: View {
    @State private var music = StudyMusic.shared

    var body: some View {
        ContentUnavailableView {
            Label("Apple Music", systemImage: "music.note")
        } description: {
            Text(music.authorization == .denied
                 ? "L'accès à Apple Music a été refusé. Autorise Polymestre dans les réglages (Confidentialité › Médias et Apple Music)."
                 : "Écoute ta musique sans quitter le mode étude.")
        } actions: {
            if music.authorization == .notDetermined {
                Button("Autoriser") { Task { await music.requestAuthorization() } }
                    .buttonStyle(InkButtonStyle())
            }
        }
    }
}

// MARK: - Albums, playlists

struct MusicCollectionView: View {
    let source: MusicCollection
    @State private var music = StudyMusic.shared
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var totalDuration: TimeInterval { songs.compactMap(\.duration).reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MusicBackButton()
                MusicPageHeader(artwork: source.artwork, round: false, title: source.title, subtitle: source.subtitle,
                                detail: songs.isEmpty ? nil : Self.summary(count: songs.count, duration: totalDuration)) {
                    MusicPlayButtons(play: { music.play(source) },
                                     shuffle: { music.play(source, shuffled: true) },
                                     queue: songs.isEmpty ? nil : { next in music.enqueue(songs, next: next) })
                }
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Impossible de charger les morceaux", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { Task { await load() } }
                            .buttonStyle(PaperButtonStyle())
                    }
                } else if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            MusicSongRow(song: song, showsArtwork: false, number: index + 1,
                                         showsArtist: song.artistName != source.subtitle) {
                                music.play(songs, from: index)
                            }
                        }
                    }
                    .padding(.horizontal, -8)
                }
            }
            .padding(.horizontal, MusicMetrics.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(source.title)
        .task { await load() }
    }

    static func summary(count: Int, duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        let tracks = count == 1 ? String(localized: "1 morceau") : String(localized: "\(count) morceaux")
        return tracks + " · " + length
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            songs = try await source.songs()
        } catch {
            errorMessage = MusicCatalogLookup.describe(error)
        }
    }
}

// MARK: - Artistes

private struct MusicArtistView: View {
    let artist: Artist
    @State private var music = StudyMusic.shared
    @State private var topSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    MusicBackButton()
                    MusicPageHeader(artwork: artist.artwork, round: true, title: artist.name, subtitle: nil, detail: nil) {
                        if !topSongs.isEmpty {
                            MusicPlayButtons(play: { music.play(topSongs) }, shuffle: { music.play(topSongs, shuffled: true) },
                                             queue: { next in music.enqueue(topSongs, next: next) })
                        }
                    }
                }
                .padding(.horizontal, MusicMetrics.gutter)
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Impossible de charger l'artiste", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { Task { await load() } }
                            .buttonStyle(PaperButtonStyle())
                    }
                } else if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        MusicShelfTitle("Titres phares")
                        LazyVStack(spacing: 0) {
                            ForEach(Array(topSongs.prefix(10).enumerated()), id: \.element.id) { index, song in
                                MusicSongRow(song: song, showsArtist: false) { music.play(topSongs, from: index) }
                            }
                        }
                        .padding(.horizontal, MusicMetrics.gutter - 8)
                    }
                }
                if !albums.isEmpty {
                    MusicShelf(title: "Albums", items: albums.map {
                        MusicBrowseItem(id: "album-\($0.id.rawValue)", title: $0.title,
                                        subtitle: $0.releaseDate.map { $0.formatted(.dateTime.year()) },
                                        artwork: $0.artwork, destination: .album($0))
                    })
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(artist.name)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detailed = try await artist.with([.topSongs, .albums])
            topSongs = Array(detailed.topSongs ?? [])
            albums = Array(detailed.albums ?? [])
        } catch {
            errorMessage = MusicCatalogLookup.describe(error)
        }
    }
}

// MARK: - Pièces

/// L'en-tête d'une page : la pochette, le titre en serif, et les actions.
private struct MusicPageHeader<Actions: View>: View {
    let artwork: Artwork?
    let round: Bool
    let title: String
    let subtitle: String?
    let detail: String?
    @ViewBuilder var actions: Actions

    #if os(macOS)
    private let side: CGFloat = 176
    #else
    private let side: CGFloat = 132
    #endif

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                art
                texts(alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(alignment: .center, spacing: 16) {
                art
                texts(alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var art: some View {
        MusicArtwork(artwork: artwork, side: side, radius: round ? .infinity : 10)
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    private func texts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 12) {
            VStack(alignment: alignment, spacing: 4) {
                Text(title)
                    .font(Carnet.serif(.title, weight: .semibold))
                    .foregroundStyle(StudyPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            actions
        }
        // Une largeur idéale : sans elle, `ViewThatFits` mesure le titre sur une
        // seule ligne et bascule en colonne même sur un écran large.
        .frame(minWidth: 240, idealWidth: 340, maxWidth: 520, alignment: alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Retour à la page précédente (le mode étude a sa propre barre, sans titre).
private struct MusicBackButton: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hovering = false

    var body: some View {
        Button { dismiss() } label: {
            Label("Retour", systemImage: "chevron.left")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(StudyPalette.ink.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyPalette.inkSecondary)
        .onHover { hovering = $0 }
        .padding(.leading, -8)
        #if os(macOS)
        .keyboardShortcut("[", modifiers: .command)
        #endif
    }
}

private struct MusicPlayButtons: View {
    var play: () -> Void
    var shuffle: () -> Void
    var queue: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                Label("Lire", systemImage: "play.fill").padding(.horizontal, 6)
            }
            .buttonStyle(InkButtonStyle())
            Button(action: shuffle) {
                Label("Aléatoire", systemImage: "shuffle").padding(.horizontal, 2)
            }
            .buttonStyle(PaperButtonStyle())
            if let queue {
                Menu {
                    Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") { queue(true) }
                    Button("Ajouter à la file", systemImage: "text.line.last.and.arrowtriangle.forward") { queue(false) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout.weight(.semibold))
                        .frame(width: InkButtonStyle.minHeight, height: InkButtonStyle.minHeight)
                        .background(StudyPalette.raisedMore, in: Circle())
                        .foregroundStyle(StudyPalette.ink)
                        .contentShape(Circle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Plus")
                .accessibilityLabel("Plus")
            }
        }
    }
}

struct MusicSongActions: View {
    let songs: [Song]
    @State private var music = StudyMusic.shared

    var body: some View {
        Button("Lire", systemImage: "play.fill") { music.play(songs) }
        Divider()
        Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") { music.enqueue(songs, next: true) }
        Button("Ajouter à la file", systemImage: "text.line.last.and.arrowtriangle.forward") { music.enqueue(songs, next: false) }
    }
}

/// Une pochette MusicKit. Sa couleur de fond (donnée par le catalogue) tient
/// la place pendant le chargement : pas de case grise qui clignote.
struct MusicArtwork: View {
    let artwork: Artwork?
    /// `nil` : la largeur proposée (grilles).
    let side: CGFloat?
    let radius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let length = side ?? proxy.size.width
            ZStack {
                Rectangle().fill(artwork?.backgroundColor.map { Color(cgColor: $0) } ?? StudyPalette.raisedMore)
                if let artwork {
                    // MusicKit sait lire les pochettes de la bibliothèque (`musickit://`), pas AsyncImage.
                    ArtworkImage(artwork, width: length, height: length)
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: length * 0.28))
                        .foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            .frame(width: length, height: length)
        }
        .frame(width: side, height: side)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: min(radius, (side ?? 400) / 2), style: .continuous))
        .clipShape(radius == .infinity ? AnyShape(Circle()) : AnyShape(Rectangle()))
    }
}

/// Un morceau : la pochette (ou le numéro), le titre, l'artiste, la durée.
/// Au survol, la pochette devient un bouton de lecture et « … » apparaît.
private struct MusicSongRow: View {
    let song: Song
    var showsArtwork = true
    var number: Int?
    var showsArtist = true
    let onPlay: () -> Void
    @State private var music = StudyMusic.shared
    @State private var hovering = false

    /// Ne lit que le morceau en cours (`currentSong`) : la position et la
    /// lecture qui changent ne redessinent pas toute la liste.
    private var isCurrent: Bool {
        music.currentSong?.matches(title: song.title, artist: song.artistName) ?? false
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? Carnet.correct : StudyPalette.ink)
                    let secondary = [showsArtist ? song.artistName : nil, showsArtwork ? song.albumTitle : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }
                    if !secondary.isEmpty {
                        Text(secondary.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if hovering {
                    Menu { MusicSongActions(songs: [song]) } label: {
                        Image(systemName: "ellipsis")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(StudyPalette.inkSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Plus")
                }
                if let duration = song.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, showsArtwork ? 5 : 8)
            .background(StudyPalette.ink.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settledHover($hovering)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { MusicSongActions(songs: [song]) }
        #if os(iOS)
        .swipeActions(edge: .leading) { MusicSongActions(songs: [song]) }
        #endif
    }

    @ViewBuilder
    private var leading: some View {
        if let number {
            ZStack {
                if isCurrent {
                    MusicPlayingGlyph(playing: music.nowPlaying.isPlaying)
                } else if hovering {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(StudyPalette.ink)
                } else {
                    Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            .frame(width: 22)
        } else if showsArtwork {
            MusicArtwork(artwork: song.artwork, side: MusicMetrics.rowArtwork, radius: 5)
                .overlay {
                    if isCurrent || hovering {
                        ZStack {
                            Color.black.opacity(0.45)
                            if isCurrent {
                                MusicPlayingGlyph(playing: music.nowPlaying.isPlaying, tint: .white)
                            } else {
                                Image(systemName: "play.fill").font(.callout).foregroundStyle(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
        }
    }
}

/// Le morceau en cours dans une liste : une onde qui bouge tant qu'il joue.
struct MusicPlayingGlyph: View {
    var playing: Bool
    var tint: Color = Carnet.correct

    var body: some View {
        Image(systemName: "waveform")
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: playing)
            .accessibilityLabel(playing ? "En cours" : "En pause")
    }
}

/// Un léger enfoncement au clic.
struct MusicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Survol posé

extension View {
    /// Un survol qui compte quand le pointeur s'arrête sur la vue, pas quand
    /// les lignes défilent sous lui : pendant un défilement, aucune ligne ne
    /// fait apparaître son menu « … » ni son bouton de lecture.
    func settledHover(_ hovering: Binding<Bool>) -> some View {
        modifier(SettledHover(hovering: hovering))
    }
}

private struct SettledHover: ViewModifier {
    @Binding var hovering: Bool
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            if inside {
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    if !Task.isCancelled { hovering = true }
                }
            } else if hovering {
                hovering = false
            }
        }
    }
}

import AVKit
import SwiftUI

// MARK: - Le livre d'un site Botafogo

/// Le site Botafogo d'un cours, lu en natif : le programme (séances, séries,
/// infos), le sommaire du polycopié, et chaque document, lu une fois puis
/// gardé. Partagé par le cours, la série et le côte à côte (`SiteHub.botafogo`).
@MainActor
@Observable
final class BotafogoBook {
    enum State {
        case idle, loading
        case ready([BotafogoNode])
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if case .ready = state { ready = true } }
    }
    private(set) var ready = false
    private(set) var root: URL?
    /// Les infos générales (`sect`) : présentation, forum, enregistrements.
    private(set) var infos: [BotafogoNode] = []
    /// Le sommaire du polycopié (vide si le site n'en a pas).
    private(set) var chapters: [BotafogoSite.Chapter] = []
    @ObservationIgnored private var bodies: [String: [String: Any]] = [:]
    @ObservationIgnored private var pages: [String: [BotafogoBlock]] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?

    var weeks: [BotafogoNode] {
        if case .ready(let weeks) = state { return weeks }
        return []
    }

    func reset() { state = .idle }

    func load(_ url: URL) async {
        if case .ready = state { return }
        if let loading { return await loading.value }
        let task = Task { await fetch(url) }
        loading = task
        await task.value
        loading = nil
    }

    private func fetch(_ url: URL) async {
        state = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let html = String(decoding: data, as: UTF8.self)
            let root = BotafogoParser.siteRoot(html: html, pageURL: url)
            self.root = root
            // Le sommaire du polycopié en même temps que le programme.
            async let handout = Self.chapters(root: root, html: html)
            if let program = await BotafogoClient.program(html: html, root: root, session: .shared), !program.isEmpty {
                infos = program.filter { $0.type == "sect" }
                chapters = await handout
                state = .ready(program.filter { $0.type == "week" })
            } else {
                state = .failed(String(localized: "Programme introuvable."))
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func chapters(root: URL, html: String) async -> [BotafogoSite.Chapter] {
        guard let collection = BotafogoSite.handoutCollection(html: html),
              let path = collection.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let address = URL(string: root.absoluteString + "api/content/nav?collection=handout&path=" + path),
              let (data, _) = try? await URLSession.shared.data(from: address) else { return [] }
        return BotafogoSite.chapters(fromNavJSON: data)
    }

    /// Le corps brut d'un document (du cours, ou du polycopié).
    func body(of url: String) async -> [String: Any]? {
        if let cached = bodies[url] { return cached }
        guard let root else { return nil }
        let handout = BotafogoSite.isHandout(url)
        let raw = handout ? url : BotafogoProgram.contentPath(url)
        for address in BotafogoClient.nodeURLs(root: root, collection: handout ? "handout" : "content", path: raw) {
            guard let (data, _) = try? await URLSession.shared.data(from: address),
                  let body = BotafogoDocument.body(fromNodeJSON: data) else { continue }
            bodies[url] = body
            return body
        }
        return nil
    }

    /// Un document prêt à dessiner.
    func page(_ url: String) async -> [BotafogoBlock]? {
        if let cached = pages[url] { return cached }
        guard let body = await body(of: url) else { return nil }
        let blocks = BotafogoPage.blocks(body)
        pages[url] = blocks
        return blocks
    }

    /// Les sections du polycopié qu'une semaine fait lire (citées par sa page).
    func readings(of weekContent: String) async -> [BotafogoSite.Chapter.Section] {
        guard let body = await body(of: weekContent) else { return [] }
        return BotafogoPage.references(body).map { reference in
            let path = BotafogoPage.handoutPath(target: reference.target)
            return .init(title: section(path)?.title ?? reference.title, path: path)
        }
    }

    /// Une section du sommaire, par son chemin.
    func section(_ path: String) -> BotafogoSite.Chapter.Section? {
        chapters.lazy.flatMap(\.sections).first { $0.path == path }
    }

    /// Le chapitre qui contient cette section.
    func chapter(of path: String) -> BotafogoSite.Chapter? {
        chapters.first { $0.sections.contains { $0.path == path } }
    }

    /// La semaine où se trouve cet élément du programme (une série, une séance).
    func week(containing url: String) -> BotafogoNode? {
        weeks.first { week in
            (week.children ?? []).contains { $0.url == url || ($0.children ?? []).contains { $0.url == url } }
        }
    }

    func assetURL(_ source: String) -> URL? {
        if source.hasPrefix("http") { return URL(string: source) }
        guard let root else { return nil }
        // « /media/… » est relatif au **site** du cours (`…/analyse-1-GM/`).
        return URL(string: root.absoluteString + (source.hasPrefix("/") ? String(source.dropFirst()) : source))
    }
}

// MARK: - Un document

/// Un document Botafogo en entier : titre, contexte, et ses blocs. Les renvois
/// au polycopié s'ouvrent par `openPoly` (dans l'app, jamais sur le web).
struct BotafogoDocumentView: View {
    var book: BotafogoBook
    let url: String
    let title: String
    var context: String?
    var desk: SiteHub
    var openPoly: (String) -> Void
    var openWeb: (URL, String) -> Void
    var ask: ((String) -> Void)?
    /// À côté de « Claude » (le signet « garder »).
    var accessory: AnyView? = nil

    @Environment(\.markStudied) private var markStudied
    @State private var blocks: [BotafogoBlock]?
    @State private var viewport: CGFloat = 800
    @State private var counted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let context { Kicker(context) }
                Spacer()
                if let accessory { accessory }
                if let ask {
                    Button { ask(String(localized: "J'ai une question sur « \(title) » (Botafogo).")) } label: {
                        Label("Claude", systemImage: "sparkle")
                    }
                    .buttonStyle(.paper)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MacMathText(title, size: 30, design: .serif)
                        .foregroundStyle(Carnet.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let blocks {
                        if blocks.isEmpty {
                            Text("Rien à lire ici.").foregroundStyle(Carnet.inkSecondary)
                        } else {
                            BotafogoBlocksView(blocks: blocks, book: book, desk: desk, openWeb: openWeb, anchored: true)
                            // La fin du document : arrivé là, il est lu.
                            Color.clear.frame(height: 1).background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: BotafogoBlockTops.self,
                                                           value: [-1: proxy.frame(in: .named("botafogo-doc")).minY])
                                }
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 8)
                .padding(.bottom, 48)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "botafogo-doc")
            .background { GeometryReader { proxy in Color.clear.onAppear { viewport = proxy.size.height } } }
            .onPreferenceChange(BotafogoBlockTops.self) { value in
                if let end = value[-1], end < viewport, !counted, blocks?.isEmpty == false {
                    counted = true
                    markStudied?(url)
                }
            }
            #if DEBUG
            // `-botafogoFirstQuiz` : défiler jusqu'au premier quiz (captures).
            .task(id: blocks?.count) {
                let arguments = CommandLine.arguments
                // `-botafogoFind <texte>` : jusqu'au premier bloc qui le contient.
                let phrase = arguments.firstIndex(of: "-botafogoFind").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                let target: Int?
                if let phrase { target = blocks?.firstIndex { String(describing: $0).contains(phrase) } }
                else if arguments.contains("-botafogoFirstQuiz") { target = blocks?.firstIndex(where: Self.holdsQuiz) }
                else { target = nil }
                guard let index = target else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo("block-\(index)", anchor: .top)
            }
            #endif
            }
        }
        .botafogoLinks(openPoly: openPoly, openWeb: openWeb)
        .task(id: url) { blocks = await book.page(url) ?? [] }
    }
}

#if DEBUG
extension BotafogoDocumentView {
    static func holdsQuiz(_ block: BotafogoBlock) -> Bool {
        switch block {
        case .quiz: return true
        case .exercise(_, let inner), .theorem(_, _, let inner), .aside(_, let inner), .folded(_, _, let inner): return inner.contains(where: holdsQuiz)
        default: return false
        }
    }
}
#endif

extension View {
    /// Les liens d'un document : le polycopié dans l'app, le reste dans l'onglet Web.
    func botafogoLinks(openPoly: @escaping (String) -> Void, openWeb: @escaping (URL, String) -> Void) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if let path = BotafogoPage.handoutPath(link: url) {
                openPoly(path)
            } else {
                openWeb(url, url.host ?? "")
            }
            return .handled
        })
    }
}

/// Une suite de blocs.
struct BotafogoBlocksView: View {
    let blocks: [BotafogoBlock]
    var book: BotafogoBook
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var size: CGFloat = 15
    /// Le premier niveau d'un document : chaque bloc a une ancre où défiler.
    var anchored = false
    /// Les blocs dont on suit la position (le plan « Sur cette page ») : leur
    /// haut, dans l'espace `botafogo-page`, remonte par `BotafogoBlockTops`.
    var tracked: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BotafogoBlockView(block: block, book: book, desk: desk, openWeb: openWeb, size: size)
                    .id(anchored ? "block-\(index)" : "")
                    .background {
                        if tracked.contains(index) {
                            GeometryReader { proxy in
                                Color.clear.preference(key: BotafogoBlockTops.self,
                                                       value: [index: proxy.frame(in: .named("botafogo-page")).minY])
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Le haut des blocs suivis, pendant qu'on défile (`-1` : la fin de la page).
struct BotafogoBlockTops: PreferenceKey {
    static let defaultValue: [Int: Double] = [:]
    static func reduce(value: inout [Int: Double], nextValue: () -> [Int: Double]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct BotafogoBlockView: View {
    let block: BotafogoBlock
    var book: BotafogoBook
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var size: CGFloat

    @Environment(\.botafogoTint) private var tint

    var body: some View {
        switch block {
        case .paragraph(let text):
            RichTextView.inline(text, size: size)
                .foregroundStyle(Carnet.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .tint(tint)
        case .heading(let text, let level):
            MacMathText(text, size: level <= 3 ? size * 1.35 : size * 1.15, design: .serif)
                .fontWeight(.semibold)
                .foregroundStyle(Carnet.ink)
                .padding(.top, 10)
        case .math(let tex):
            DisplayMathView(tex: tex, size: size)
                .foregroundStyle(Carnet.ink)
                .padding(.vertical, 2)
        case .list(let items, let ordered, let columns):
            BotafogoListView(items: items, ordered: ordered, columns: columns, book: book, desk: desk, openWeb: openWeb, size: size)
        case .image(let source, let width):
            BotafogoImage(url: book.assetURL(source), width: width)
        case .figure(let script, let width, let height):
            BotafogoLiveFigure(script: book.assetURL(script), image: book.assetURL(BotafogoFigure.imagePath(script: script)),
                               width: width, height: height)
        case .animation(let source, let title):
            BotafogoAnimation(url: book.assetURL(source), title: title)
        case .kaltura(let id, let title):
            NativeVideo(title: title, address: "https://\(Institution.current.videoHostName)/media/t/\(id)", desk: desk, openWeb: openWeb)
        case .video(let source, let poster, let title):
            BotafogoVideo(url: book.assetURL(source), poster: poster.flatMap(book.assetURL), title: title)
        case .theorem(let kind, let title, let content):
            BotafogoTheoremBox(kind: kind, title: title) {
                BotafogoBlocksView(blocks: content, book: book, desk: desk, openWeb: openWeb, size: size)
            }
        case .aside(let title, let content):
            VStack(alignment: .leading, spacing: 8) {
                Label(title.isEmpty ? String(localized: "À retenir") : title, systemImage: "lightbulb")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Carnet.inkSecondary)
                BotafogoBlocksView(blocks: content, book: book, desk: desk, openWeb: openWeb, size: size)
            }
            .padding(14)
            .background(Carnet.sheetRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .exercise(let label, let content):
            BotafogoExerciseCard(label: label, content: content, book: book, desk: desk, openWeb: openWeb, size: size)
        case .folded(let fold, let title, let content):
            BotafogoFoldCard(fold: fold, title: title) {
                BotafogoBlocksView(blocks: content, book: book, desk: desk, openWeb: openWeb, size: size)
            }
        case .quiz(let title, let prompt, let choices, let columns):
            BotafogoQuizCard(title: title, choices: choices, columns: columns, size: size) {
                BotafogoBlocksView(blocks: prompt, book: book, desk: desk, openWeb: openWeb, size: size)
            }
        }
    }
}

// MARK: - Les pièces

private struct BotafogoTintKey: EnvironmentKey {
    static let defaultValue: Color = Carnet.ink
}

extension EnvironmentValues {
    /// La couleur du cours, pour les liens et les encadrés d'un document.
    var botafogoTint: Color {
        get { self[BotafogoTintKey.self] }
        set { self[BotafogoTintKey.self] = newValue }
    }
}

/// Une liste ; en colonnes quand le site la pose ainsi (des sous-questions courtes).
private struct BotafogoListView: View {
    let items: [[BotafogoBlock]]
    let ordered: Bool
    let columns: Int
    var book: BotafogoBook
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var size: CGFloat

    var body: some View {
        if columns > 1 {
            // Autant de colonnes que la place en laisse (au plus celles du site) :
            // à côté du polycopié, trois colonnes de formules seraient coupées.
            ViewThatFits(in: .horizontal) {
                ForEach((1...columns).reversed(), id: \.self) { count in grid(count) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in row(index, item) }
            }
        }
    }

    private func grid(_ count: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 22, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: items.count, by: count)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + count, items.count), id: \.self) { index in
                        row(index, items[index]).fixedSize(horizontal: count > 1, vertical: false)
                    }
                }
            }
        }
    }

    private func row(_ index: Int, _ item: [BotafogoBlock]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ordered ? "\(index + 1)." : "•")
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(Carnet.inkSecondary)
                .frame(minWidth: ordered ? 20 : 10, alignment: .trailing)
            BotafogoBlocksView(blocks: item, book: book, desk: desk, openWeb: openWeb, size: size)
        }
    }
}

/// Un théorème, une définition… : un trait de la couleur du cours, le titre en serif.
private struct BotafogoTheoremBox<Content: View>: View {
    let kind: BotafogoTheoremKind
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.botafogoTint) private var tint

    private var accent: Color {
        switch kind {
        case .definition: return Carnet.ink
        case .remark, .example, .other: return Carnet.inkTertiary
        default: return tint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                MacMathText(title, size: 15, design: .serif)
                    .fontWeight(.semibold)
                    .foregroundStyle(Carnet.ink)
            }
            content
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(kind == .remark || kind == .example ? 0.05 : 0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                .fill(accent)
                .frame(width: 3)
        }
    }
}

/// Un exercice : son étiquette, son énoncé, et dessous l'indication et la solution repliées.
struct BotafogoExerciseCard: View {
    let label: String
    let content: [BotafogoBlock]
    var book: BotafogoBook
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var size: CGFloat = 15
    @Environment(\.botafogoTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !label.isEmpty {
                Text(Self.title(label))
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(tint)
            }
            BotafogoBlocksView(blocks: content, book: book, desk: desk, openWeb: openWeb, size: size)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous).strokeBorder(Carnet.rule))
    }

    /// « Ex-5-3 » → « EXERCICE 5.3 ».
    static func title(_ label: String) -> String {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return label.uppercased() }
        return String(localized: "EXERCICE \(numbers[0]).\(numbers[1])")
    }
}

/// Une indication, une solution, une preuve, une bulle « pourquoi ? » : repliée, un geste pour l'ouvrir.
private struct BotafogoFoldCard<Content: View>: View {
    let fold: BotafogoFold
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false
    @State private var hovering = false

    private var icon: String {
        switch fold {
        case .solution: return "checkmark.seal"
        case .hint: return "lightbulb"
        case .proof: return "text.alignleft"
        case .aside: return "questionmark.bubble"
        }
    }

    private var color: Color {
        switch fold {
        case .solution: return Carnet.correct
        case .hint: return Carnet.review
        case .proof, .aside: return Carnet.inkSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(color)
                    MacMathText(title, size: 13).fontWeight(.semibold).foregroundStyle(Carnet.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.inkTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if open {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(color.opacity(open ? 0.07 : (hovering ? 0.08 : 0.05)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Un quiz, comme sur le site : on choisit, il dit si c'est juste — et pourquoi.
struct BotafogoQuizCard<Prompt: View>: View {
    let title: String
    let choices: [BotafogoQuizChoice]
    let columns: Int
    var size: CGFloat
    /// Une réponse choisie : juste ou non (le quiz de la semaine compte les points).
    var onAnswer: ((Bool) -> Void)? = nil
    @ViewBuilder var prompt: Prompt
    @State private var picked: Int?
    @Environment(\.botafogoTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                if picked != nil {
                    Button("Réessayer") { withAnimation(.smooth(duration: 0.2)) { picked = nil } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Carnet.inkSecondary)
                }
            }
            prompt
            if !choices.isEmpty {
                let grid = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: max(1, min(columns, choices.count)))
                LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        choiceButton(index, choice)
                    }
                }
                if let picked, let explanation = choices[picked].explanation {
                    RichTextView.inline(explanation, size: size - 1)
                        .foregroundStyle(Carnet.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous).strokeBorder(Carnet.rule))
    }

    private func choiceButton(_ index: Int, _ choice: BotafogoQuizChoice) -> some View {
        let answered = picked != nil
        let isPicked = picked == index
        let color: Color = !answered ? Carnet.ink : (choice.correct ? Carnet.correct : (isPicked ? Carnet.wrong : Carnet.inkTertiary))
        return Button {
            let first = picked == nil
            withAnimation(.smooth(duration: 0.2)) { picked = index }
            if first { onAnswer?(choice.correct) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: !answered ? "circle" : (choice.correct ? "checkmark.circle.fill" : (isPicked ? "xmark.circle.fill" : "circle")))
                    .foregroundStyle(color)
                RichTextView.inline(choice.text, size: size)
                    .foregroundStyle(answered && !choice.correct && !isPicked ? Carnet.inkSecondary : Carnet.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((answered && (choice.correct || isPicked) ? color.opacity(0.1) : Carnet.sheetRaised.opacity(0.6)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(answered && (choice.correct || isPicked) ? color.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answered)
        .accessibilityLabel(MathMarkup.plain(choice.text))
        .accessibilityValue(answered ? (choice.correct ? String(localized: "Juste") : (isPicked ? String(localized: "Faux") : "")) : "")
    }
}

/// Une image du polycopié : dessinée sur fond blanc, posée sur une carte blanche.
private struct BotafogoImage: View {
    let url: URL?
    let width: Double?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
                    .padding(10)
                    .frame(maxWidth: width.map { CGFloat($0) + 20 } ?? 560)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .failure:
                Label("Image indisponible", systemImage: "photo").font(.caption).foregroundStyle(Carnet.inkTertiary)
            default:
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Carnet.sheetRaised).frame(height: 140)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Une vidéo du site (ou une animation) : l'affiche d'abord, le lecteur seulement
/// au premier geste — rien ne se charge ni ne tourne tant qu'on ne l'a pas demandé.
private struct BotafogoVideo: View {
    let url: URL?
    let poster: URL?
    let title: String
    @State private var player: AVPlayer?

    var body: some View {
        if player == nil, poster == nil {
            // Sans affiche (une animation) : une ligne, pas un grand cadre vide.
            Button { start() } label: {
                Label(title, systemImage: "play.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Carnet.sheetRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
        } else {
            framed
        }
    }

    private var framed: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Button { start() } label: {
                        ZStack {
                            if let poster {
                                AsyncImage(url: poster) { $0.resizable().scaledToFill() } placeholder: { Carnet.sheetRaised }
                            } else {
                                Carnet.sheetRaised
                            }
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.8))
                                .frame(width: 52, height: 52)
                                .background(.white.opacity(0.92), in: Circle())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 620)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .onDisappear { player?.pause() }
    }

    private func start() {
        guard let url else { return }
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }
}

// MARK: - Côte à côte : le polycopié à côté de la série

/// Le polycopié seul, à côté de la série : ouvert sur la matière de la série
/// en cours (`focus`, via la page de sa semaine), un menu pour une autre
/// section, précédente et suivante. Les renvois cliqués dans un exercice
/// arrivent ici (`SiteHub.request`).
struct BotafogoPairedPoly: View {
    var book: BotafogoBook
    let site: URL
    var focus: String?
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var ask: (String) -> Void
    var tint: Color

    @State private var path: String?
    /// Choisi à la main : la série suivante ne le déplace plus.
    @State private var chosen = false

    private var sections: [BotafogoSite.Chapter.Section] { book.chapters.flatMap(\.sections) }
    private var index: Int? { path.flatMap { current in sections.firstIndex { $0.path == current } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Array(book.chapters.enumerated()), id: \.offset) { _, chapter in
                        Menu(MathMarkup.plain(chapter.title)) {
                            ForEach(chapter.sections, id: \.path) { section in
                                Button(MathMarkup.plain(section.title)) { open(section.path) }
                            }
                        }
                    }
                } label: {
                    Label(path.flatMap(book.section).map { MathMarkup.plain($0.title) } ?? String(localized: "Polycopié"), systemImage: "text.book.closed")
                        .lineLimit(1)
                }
                .menuStyle(.button)
                .buttonStyle(.paper)
                .fixedSize()
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.paper)
                    .disabled((index ?? 0) == 0)
                    .help("Section précédente")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.paper)
                    .disabled(index.map { $0 >= sections.count - 1 } ?? true)
                    .help("Section suivante")
            }
            .padding(10)
            Rectangle().fill(Carnet.rule).frame(height: 1)
            if let path {
                BotafogoDocumentView(book: book, url: path, title: book.section(path)?.title ?? "",
                                     context: book.chapter(of: path).map { MathMarkup.plain($0.title) }, desk: desk,
                                     openPoly: open, openWeb: openWeb, ask: ask)
                    .environment(\.botafogoTint, tint)
                    .id(path)
            } else if case .failed(let message) = book.state {
                ContentUnavailableView(message, systemImage: "wifi.exclamationmark")
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Carnet.ground)
        .task(id: site) {
            await book.load(site)
            await settle()
        }
        .task(id: focus) { if !chosen { await settle(force: true) } }
        .onChange(of: desk.request) { _, request in
            guard let request, case .botafogo(_, let url)? = request.reading, BotafogoSite.isHandout(url) else { return }
            desk.request = nil
            open(url)
        }
    }

    private func open(_ section: String) {
        chosen = true
        path = section
    }

    private func step(_ delta: Int) {
        guard let index, sections.indices.contains(index + delta) else { return }
        open(sections[index + delta].path)
    }

    /// La section de départ : la première que la semaine de la série fait lire.
    private func settle(force: Bool = false) async {
        guard force || path == nil, book.ready else { return }
        // La semaine de la série ; sans série (ou hors programme), la semaine en cours.
        let week = focus.flatMap { book.week(containing: $0) }
            ?? BotafogoSite.currentWeek(book.weeks).flatMap { book.weeks.indices.contains($0) ? book.weeks[$0] : nil }
        if let week,
           let weekContent = (week.children ?? []).first(where: { $0.type == "weekContent" })?.url,
           let first = await book.readings(of: weekContent).first {
            path = first.path
        } else if path == nil {
            path = sections.first?.path
        }
    }
}

// MARK: - Série : un exercice lu sur le site

/// L'énoncé d'un exercice Botafogo tel que le site le montre : formules,
/// figures, sous-questions, indication et solution repliées, renvois au
/// polycopié cliquables.
struct BotafogoExerciseStatement: View {
    var book: BotafogoBook
    let site: URL
    /// La page de l'exercice (`exercices/…`), sinon celle de sa série.
    let exercisePath: String?
    let seriesPath: String?
    /// La place de l'exercice dans sa série (quand on n'a que la série).
    let position: Int
    /// « Exercice 6.2 » et son titre, au-dessus de la page.
    var heading: (number: String, title: String)?
    var desk: SiteHub
    var openPoly: (String) -> Void
    var openWeb: (URL, String) -> Void
    var tint: Color

    @State private var blocks: [BotafogoBlock]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let heading {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heading.number).font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
                        if !heading.title.isEmpty, heading.title != heading.number {
                            MacMathText(heading.title, size: 15).foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                    .padding(.bottom, 4)
                }
                if let blocks {
                    if blocks.isEmpty {
                        ContentUnavailableView("Énoncé introuvable", systemImage: "doc.questionmark")
                    } else {
                        BotafogoBlocksView(blocks: blocks, book: book, desk: desk, openWeb: openWeb)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.botafogoTint, tint)
        .botafogoLinks(openPoly: openPoly, openWeb: openWeb)
        .task(id: "\(exercisePath ?? "")|\(seriesPath ?? "")|\(position)") { await load() }
    }

    private func load() async {
        await book.load(site)
        if let exercisePath, let page = await book.page(exercisePath), !page.isEmpty {
            blocks = page
            return
        }
        if let seriesPath, let page = await book.page(seriesPath) {
            let exercises = BotafogoPage.exercises(page)
            if exercises.indices.contains(position) {
                blocks = [.exercise(label: exercises[position].label, exercises[position].blocks)]
                return
            }
        }
        blocks = []
    }
}

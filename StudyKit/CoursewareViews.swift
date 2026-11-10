import SwiftUI

/// Courseware dans le bureau, comme « Le cours » : à gauche les chapitres
/// (en têtes, comme les semaines), les séquences qui se déplient, les unités
/// cochées une fois faites ; « Reprendre » mène à la première non faite.
struct CoursewareList: View {
    let outline: EdXOutline
    let tint: Color
    var selected: String?
    var open: (EdXOutline.Unit) -> Void
    /// Les passages des vidéos qui disent ce qu'on cherche.
    var search: ((String) -> AnyView)? = nil
    /// Lire toutes les vidéos d'un chapitre à la suite.
    var playChapter: ((EdXOutline.Chapter) -> Void)? = nil

    @State private var expanded: Set<String> = []
    @State private var query = ""

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        VStack(spacing: 0) {
            if search != nil {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(Carnet.inkTertiary)
                    TextField("Chercher dans ce que disent les vidéos", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Carnet.inkTertiary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Carnet.sheetRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            if searching, let search {
                search(query.trimmingCharacters(in: .whitespaces))
            } else {
                outlineList
            }
        }
    }

    @ViewBuilder
    private var outlineList: some View {
        VStack(spacing: 0) {
            if let resume = outline.resumeUnit {
                Button { open(resume) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reprendre").font(.callout.weight(.semibold))
                            Text(resume.title).font(.caption).lineLimit(1).foregroundStyle(Carnet.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Carnet.ink)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(outline.chapters) { chapter in
                        Section {
                            ForEach(chapter.sequences) { sequence in
                                sequenceRow(sequence)
                                if expanded.contains(sequence.id) {
                                    ForEach(sequence.units) { unit in unitRow(unit).id(unit.id) }
                                }
                            }
                        } header: {
                            HStack {
                                Text(chapter.title).font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink).lineLimit(2)
                                Spacer()
                                if let playChapter, chapter.sequences.contains(where: { $0.units.contains { $0.blocks.contains { $0.kind == .video } } }) {
                                    Button { playChapter(chapter) } label: { Image(systemName: "play.circle") }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(tint)
                                        .help("Les vidéos du chapitre, à la suite")
                                }
                                let units = chapter.sequences.flatMap(\.units)
                                Text("\(units.filter(\.completed).count)/\(units.count)").font(.caption2.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear {
                    let target = selected ?? outline.resumeUnit?.id
                    if let target, let place = outline.place(of: target) {
                        expanded.insert(place.sequence.id)
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .onChange(of: selected) { _, id in
                    if let id, let place = outline.place(of: id) { expanded.insert(place.sequence.id) }
                }
            }
        }
    }

    private func sequenceRow(_ sequence: EdXOutline.Sequence) -> some View {
        Button {
            if expanded.contains(sequence.id) { expanded.remove(sequence.id) } else { expanded.insert(sequence.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded.contains(sequence.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(Carnet.inkTertiary).frame(width: 10)
                Text(sequence.title).font(.callout.weight(.medium)).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
                if sequence.units.allSatisfy(\.completed), !sequence.units.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Carnet.correct)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unitRow(_ unit: EdXOutline.Unit) -> some View {
        Button { open(unit) } label: {
            HStack(spacing: 8) {
                Image(systemName: unit.completed ? "checkmark.circle.fill" : CoursewareList.icon(unit))
                    .foregroundStyle(unit.completed ? Carnet.correct : tint)
                    .frame(width: 16)
                Text(unit.title).foregroundStyle(unit.completed ? Carnet.inkSecondary : Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected == unit.id ? tint.opacity(0.12) : Color.clear)
    }

    static func icon(_ unit: EdXOutline.Unit) -> String {
        if unit.blocks.contains(where: { $0.kind == .video }) { return "play.rectangle" }
        if unit.blocks.contains(where: { $0.kind == .problem }) { return "checklist" }
        return "doc.text"
    }
}

/// Une unité de Courseware : où l'on est (chapitre › séquence), ses vidéos,
/// ses textes, ses problèmes (auxquels on répond ici), et l'unité suivante.
struct CoursewareUnitPage: View {
    let outline: EdXOutline
    let unit: EdXOutline.Unit
    /// Le cours Courseware (pour noter une vidéo vue là-bas aussi).
    let key: String
    let tint: Color
    var desk: SiteHub
    /// Une vidéo à lancer à un instant (un passage trouvé).
    var start: (block: String, at: Double)? = nil
    var go: (EdXOutline.Unit) -> Void
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var texts: [String: [SiteBlock]] = [:]
    @Environment(\.markStudied) private var markStudied

    private var neighbours: (previous: EdXOutline.Unit?, next: EdXOutline.Unit?) {
        let units = outline.units
        guard let index = units.firstIndex(where: { $0.id == unit.id }) else { return (nil, nil) }
        return (index > 0 ? units[index - 1] : nil, index + 1 < units.count ? units[index + 1] : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let place = outline.place(of: unit.id) {
                    Kicker("\(place.chapter.title) › \(place.sequence.title)", color: tint)
                }
                Text(unit.title).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                ForEach(unit.blocks) { block in
                    switch block.kind {
                    case .video:
                        if let url = block.videoURL ?? block.youTubeID.map({ "https://www.youtube.com/watch?v=\($0)" }) {
                            NativeVideo(title: block.title.isEmpty ? String(localized: "Vidéo") : block.title, address: url, desk: desk, openWeb: openWeb,
                                        start: start?.block == block.id ? start?.at : nil, studiedKey: block.id,
                                        autoplay: start?.block == block.id)
                        }
                    case .problem:
                        if let address = block.viewURL { EdXProblemCard(address: address, desk: desk, open: open, openWeb: openWeb) }
                    case .html, .other:
                        Group {
                            if let blocks = texts[block.id] {
                                SiteBlocksView(blocks: blocks, desk: desk, open: open, openWeb: openWeb)
                            } else if block.viewURL != nil {
                                ProgressView()
                            }
                        }
                        .task(id: block.id) { await load(block) }
                    }
                }
                Rectangle().fill(Carnet.rule).frame(height: 1).padding(.top, 12)
                HStack {
                    if let previous = neighbours.previous {
                        Button { go(previous) } label: { Label(previous.title, systemImage: "chevron.left").lineLimit(1) }
                            .buttonStyle(.paper)
                    }
                    Spacer()
                    if let next = neighbours.next {
                        Button { go(next) } label: {
                            HStack { Text(next.title).lineLimit(1); Image(systemName: "chevron.right") }
                        }
                        .buttonStyle(.ink)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Vue ici : cochée dans le cours, et achevée sur Courseware.
        .environment(\.markStudied) { block in
            markStudied?(block)
            Task { await desk.courseware.complete(block: block, course: key) }
        }
    }

    private func load(_ block: EdXOutline.Block) async {
        guard texts[block.id] == nil, let address = block.viewURL else { return }
        let html = (try? await desk.courseware.blockHTML(address)) ?? ""
        texts[block.id] = SiteHTML.blocks(html, base: URL(string: address))
    }
}

/// Un problème de Courseware, en natif : l'énoncé, les choix, « Envoyer »,
/// et le verdict de Courseware.
struct EdXProblemCard: View {
    let address: String
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var problem: EdXProblem?
    @State private var answers: [String: [String]] = [:]
    @State private var result: EdXProblem.Result?
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem {
                HStack {
                    Kicker(problem.title.isEmpty ? String(localized: "Exercice") : problem.title)
                    Spacer()
                    if problem.total > 0 {
                        Text("\(Int(problem.score))/\(Int(problem.total))").font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                    }
                }
                SiteBlocksView(blocks: SiteHTML.blocks(problem.prompt, base: URL(string: address)), desk: desk, open: open, openWeb: openWeb)
                ForEach(problem.groups, id: \.name) { group in groupView(group) }
                HStack(spacing: 12) {
                    Button(sending ? "Envoi…" : "Envoyer") { Task { await submit(problem) } }
                        .buttonStyle(.ink)
                        .disabled(sending || answers.values.allSatisfy(\.isEmpty))
                    if let result {
                        Label(result.isCorrect ? "Juste" : (result.verdict == "partially-correct" ? String(localized: "En partie") : String(localized: "Faux")),
                              systemImage: result.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isCorrect ? Carnet.correct : Carnet.wrong)
                    }
                    Spacer()
                    if problem.attempts > 0 { Text(Plural.count(problem.attempts, "\(problem.attempts) essai", "\(problem.attempts) essais")).font(.caption).foregroundStyle(Carnet.inkTertiary) }
                }
            } else if failed {
                Text("Exercice illisible.").font(.caption).foregroundStyle(Carnet.inkSecondary)
            } else {
                ProgressView()
            }
        }
        .paperSheet(padding: 16)
        .task(id: address) {
            problem = try? await desk.courseware.problem(address)
            failed = problem == nil
            for group in problem?.groups ?? [] {
                answers[group.name] = group.options.filter { $0.checked == true }.map(\.value) + (group.value.map { $0.isEmpty ? [] : [$0] } ?? [])
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: EdXProblem.Group) -> some View {
        switch group.type {
        case "checkbox", "radio":
            ForEach(group.options, id: \.value) { option in
                let chosen = answers[group.name, default: []].contains(option.value)
                Button {
                    var current = answers[group.name, default: []]
                    if group.type == "radio" { current = [option.value] }
                    else if chosen { current.removeAll { $0 == option.value } } else { current.append(option.value) }
                    answers[group.name] = current
                    result = nil
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: chosen ? (group.type == "radio" ? "largecircle.fill.circle" : "checkmark.square.fill")
                                                 : (group.type == "radio" ? "circle" : "square"))
                            .foregroundStyle(Carnet.ink)
                        SiteBlocksView(blocks: SiteHTML.blocks(option.label), desk: desk, open: open, openWeb: openWeb)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case "select":
            Picker("Réponse", selection: Binding(get: { answers[group.name]?.first ?? "" }, set: { answers[group.name] = [$0]; result = nil })) {
                Text("—").tag("")
                ForEach(group.options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .frame(maxWidth: 320)
        default:
            TextField("Ta réponse", text: Binding(get: { answers[group.name]?.first ?? "" }, set: { answers[group.name] = [$0]; result = nil }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private func submit(_ problem: EdXProblem) async {
        sending = true
        defer { sending = false }
        result = try? await desk.courseware.check(problem, answers: answers)
        if result != nil { self.problem?.attempts += 1 }
    }
}

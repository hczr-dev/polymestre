import SwiftUI
import UniformTypeIdentifiers

/// NotebookLM, pour écouter son cours : Polymestre **prépare** les sources (la fiche, ses liens, ses
/// schémas, ses questions), tu les déposes dans un carnet NotebookLM, puis tu rapportes ici le
/// podcast (ou la vidéo, le quiz) pour l'écouter pendant que tu révises.
///
/// NotebookLM n'a pas d'interface pour une app tierce : son API officielle est réservée à l'offre
/// entreprise de Google Cloud, et lui parler autrement (cookies d'un navigateur) casserait à chaque
/// changement de Google. Ici, rien de tout cela — un export, un lien, un fichier.
/// Réglages › « NotebookLM » l'allume ou l'éteint.
struct NotebookLMPanel: View {
    @Bindable var course: Course
    /// Le chapitre dont on parle (`nil` : tout le cours). Chaque chapitre a son carnet et ses podcasts.
    var chapter: String?

    @Environment(\.openURL) private var openURL
    @State private var player = PodcastPlayer.shared
    @State private var notebook = ""
    @State private var prepared: [URL] = []
    @State private var importing = false
    @State private var addingLink = false
    @State private var linkTitle = ""
    @State private var linkAddress = ""
    @State private var linkKind: StudyMap.Resource.Kind = .video
    @State private var message: String?
    @State private var account = NotebookLMAccount.shared
    @State private var signingIn = false
    private var store: StudyMapStore { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }
    private var chapterTitle: String? { course.revisionSheet?.chapter(chapter)?.title }

    /// L'adresse du carnet de ce cours, ou de ce chapitre.
    private func address(_ map: StudyMap) -> String? {
        if let chapter { return map.chapterNotebooks?[chapter] }
        return map.notebookURL
    }

    var body: some View {
        let map = store.map(course)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                intro
                automatic
                Text("Ou à la main").font(.headline).foregroundStyle(Carnet.ink).padding(.top, 4)
                step(1, "Prépare les sources", detail: "La fiche, ses liens, ses schémas et ses questions, en Markdown : ce que NotebookLM lit le mieux.") { prepare }
                step(2, "Dépose-les dans NotebookLM", detail: "Nouveau carnet › Ajouter des sources. Puis « Résumé audio » pour le podcast.") { open(map) }
                step(3, "Rapporte le podcast ici", detail: "Télécharge-le depuis NotebookLM et glisse-le : il se lit ici, à ta vitesse, sans quitter le mode étude.") { resources(map) }
                if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(Carnet.inkSecondary) }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Carnet.ground)
        .onAppear { notebook = address(map) ?? "" }
        .task { if account.state == .unknown { await account.refresh() } }
        .sheet(isPresented: $signingIn) {
            NotebookLMLogin { signingIn = false; Task { await account.refresh() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav]) { result in
            guard case .success(let url) = result else { return }
            importPodcast(url)
        }
    }

    // MARK: Présentation

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("NotebookLM · \(course.displayCode)", color: tint)
            Text(chapterTitle.map { "Écouter : \($0)" } ?? String(localized: "Écouter ton cours")).font(Carnet.serif(26)).foregroundStyle(Carnet.ink)
            Text("Un podcast de ta fiche, par NotebookLM.")
                .font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(Carnet.ground)
                .frame(width: 26, height: 26).background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(Carnet.ink)
                Text(detail).font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    // MARK: Automatique (compte Google)

    /// Connecté à Google : Polymestre crée le carnet, y dépose la fiche, lance le podcast et le rapporte.
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Automatique", systemImage: "wand.and.stars").font(.headline).foregroundStyle(Carnet.ink)
            switch account.state {
            case .unknown, .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Je regarde si tu es connecté·e à Google…").font(.callout).foregroundStyle(Carnet.inkSecondary) }
            case .signedOut:
                Text("Polymestre crée le carnet, y dépose ta fiche et rapporte le podcast. Ton mot de passe reste chez Google.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
                Button { signingIn = true } label: { Label("Se connecter à Google", systemImage: "person.crop.circle.badge.checkmark") }.buttonStyle(.ink)
            case .ready:
                automaticReady
            }
            Text("Non officiel : si Google change NotebookLM, l'export manuel reste là.")
                .font(.caption).foregroundStyle(Carnet.inkTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var automaticReady: some View {
        let working = account.working(course, chapter: chapter)
        if let sheet = course.revisionSheet {
            HStack(spacing: 10) {
                Button { account.makePodcast(for: course, sheet: sheet, chapter: chapter) } label: { Label(chapter == nil ? "Créer le podcast" : "Créer le podcast de ce chapitre", systemImage: "waveform") }
                    .buttonStyle(.ink).disabled(working != nil)
                if address(store.map(course)) != nil {
                    Button { account.fetchLatest(for: course, chapter: chapter) } label: { Label("Récupérer", systemImage: "arrow.down.circle") }
                        .buttonStyle(.paper).disabled(working != nil)
                        .help("Retrouve le dernier podcast du carnet (si le lancement a été interrompu)")
                }
                Spacer(minLength: 4)
                Button("Se déconnecter") { Task { await account.signOut() } }.buttonStyle(.plain).font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
        } else {
            Label("Fais d'abord la fiche du cours.", systemImage: "doc.text").font(.callout).foregroundStyle(Carnet.inkSecondary)
        }
        if let working {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(working).font(.callout).foregroundStyle(Carnet.inkSecondary)
                Spacer(minLength: 4)
                Button("Arrêter") { account.cancel(course, chapter: chapter) }.buttonStyle(.plain).font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Text("Tu peux continuer à travailler : le podcast arrive dans « Rapporte le podcast » plus bas.").font(.caption).foregroundStyle(Carnet.inkTertiary)
        }
        if let failure = account.problem(course, chapter: chapter) {
            Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Carnet.wrong).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 1 · Préparer

    @ViewBuilder
    private var prepare: some View {
        if course.revisionSheet == nil {
            Label("Fais d'abord la fiche du cours.", systemImage: "doc.text").font(.callout).foregroundStyle(Carnet.inkSecondary)
        } else {
            HStack(spacing: 10) {
                Button { writeSources() } label: { Label(prepared.isEmpty ? "Préparer les sources" : "Refaire les sources", systemImage: "square.and.arrow.down.on.square") }
                    .buttonStyle(.ink)
                if !prepared.isEmpty {
                    #if os(macOS)
                    Button { NSWorkspace.shared.activateFileViewerSelecting(prepared) } label: { Label("Montrer dans le Finder", systemImage: "folder") }
                        .buttonStyle(.paper)
                    #else
                    ShareLink(items: prepared) { Label("Partager", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.paper)
                    #endif
                }
            }
            if !prepared.isEmpty {
                Text(prepared.map(\.lastPathComponent).joined(separator: "\n")).font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            if store.map(course).links.isEmpty && store.map(course).diagrams.isEmpty {
                Label("Sans les liens et les schémas de Claude, NotebookLM ne reçoit que la fiche. « Comprendre avec Claude » les ajoute.", systemImage: "lightbulb")
                    .font(.caption).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func writeSources() {
        guard let sheet = course.revisionSheet else { return }
        let files = NotebookExport.files(courseName: course.name, code: course.displayCode, sheet: sheet, map: store.map(course), chapter: chapter)
        let tag = chapterTitle.map { "\(course.displayCode) · \($0.prefix(24))" } ?? course.displayCode
        var urls = PodcastStore.writeSources(files, code: tag.replacingOccurrences(of: "/", with: "-"))
        #if os(macOS)
        // Sur le Mac, les fichiers vont dans Documents : on les retrouve, on les glisse dans le navigateur.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let folder = documents.appending(path: "Polymestre NotebookLM/\(tag.replacingOccurrences(of: "/", with: "-"))", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            urls = urls.compactMap { source in
                let target = folder.appending(path: source.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                return (try? FileManager.default.copyItem(at: source, to: target)) != nil ? target : nil
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        #endif
        prepared = urls
        message = urls.isEmpty ? String(localized: "Les sources n'ont pas pu être écrites.") : nil
    }

    // MARK: 2 · Ouvrir

    private func open(_ map: StudyMap) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openURL(URL(string: "https://notebooklm.google.com")!) } label: { Label("Ouvrir NotebookLM", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.paper)
            HStack(spacing: 8) {
                TextField("Adresse de ton carnet (à coller une fois)", text: $notebook)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveNotebook() }
                Button("Garder") { saveNotebook() }.buttonStyle(.paper).disabled(notebook == (address(map) ?? ""))
                if let address = address(map), let url = URL(string: address) {
                    Button { openURL(url) } label: { Label("Mon carnet", systemImage: "book") }.buttonStyle(.ink)
                }
            }
            Button { copyPrompt() } label: { Label("Copier la consigne du podcast", systemImage: "doc.on.doc") }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func saveNotebook() {
        let address = notebook.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(course) { map in
            if let chapter {
                var all = map.chapterNotebooks ?? [:]
                all[chapter] = address.isEmpty ? nil : address
                map.chapterNotebooks = all.isEmpty ? nil : all
            } else {
                map.notebookURL = address.isEmpty ? nil : address
            }
        }
    }

    private func copyPrompt() {
        let text = "Concentre-toi sur les liens entre les notions et sur ce qu'il faut comprendre avant chaque résultat. Explique d'abord l'intuition, puis l'énoncé ; signale les pièges."
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        message = String(localized: "Consigne copiée : colle-la dans « Personnaliser » du résumé audio.")
    }

    // MARK: 3 · Rapporter

    private func resources(_ map: StudyMap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { importing = true } label: { Label("Importer un podcast", systemImage: "waveform.badge.plus") }.buttonStyle(.ink)
                Button { addingLink = true } label: { Label("Ajouter un lien", systemImage: "link.badge.plus") }.buttonStyle(.paper)
                    .popover(isPresented: $addingLink) { linkForm }
            }
            if player.hasEpisode { nowPlaying }
            let shown = map.resources.filter { chapter == nil || $0.chapter == chapter }
            ForEach(shown) { resource in row(resource) }
            if shown.isEmpty {
                Text("Rien pour l'instant.").font(.callout).foregroundStyle(Carnet.inkTertiary)
            }
        }
    }

    private func importPodcast(_ url: URL) {
        guard let name = PodcastStore.importFile(url, for: course) else {
            message = String(localized: "Le fichier n'a pas pu être copié.")
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        store.update(course) { $0.resources.append(.init(id: UUID().uuidString, kind: .podcast, title: title, url: nil, fileName: name, addedAt: Date(), chapter: chapter)) }
        if let file = PodcastStore.url(for: store.map(course).resources.last!, in: course) { player.play(file, title: title) }
    }

    private func row(_ resource: StudyMap.Resource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: resource.kind.icon).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(resource.title).font(.callout.weight(.medium)).foregroundStyle(Carnet.ink).lineLimit(2)
                Text(resource.kind.label + (chapter == nil ? (course.revisionSheet?.chapter(resource.chapter)?.title).map { " · \($0)" } ?? "" : "") + (resource.fileName != nil ? " · sur cet appareil" : "")).font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer(minLength: 4)
            if let file = PodcastStore.url(for: resource, in: course) {
                Button { player.play(file, title: resource.title) } label: { Image(systemName: player.file == file && player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(tint)
            } else if resource.fileName != nil {
                Text("Importe-le sur cet appareil").font(.caption).foregroundStyle(Carnet.inkTertiary)
            } else if let address = resource.url, let url = URL(string: address) {
                Button { openURL(url) } label: { Image(systemName: "arrow.up.forward.circle") }.buttonStyle(.plain).foregroundStyle(tint)
            }
            Button {
                PodcastStore.remove(resource, from: course)
                if let file = PodcastStore.url(for: resource, in: course), player.file == file { player.stop() }
                store.update(course) { $0.resources.removeAll { $0.id == resource.id } }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(10)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Carnet.rule))
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Genre", selection: $linkKind) { ForEach(StudyMap.Resource.Kind.allCases, id: \.rawValue) { Text($0.label).tag($0) } }
            TextField("Titre", text: $linkTitle).textFieldStyle(.roundedBorder)
            TextField("Adresse", text: $linkAddress).textFieldStyle(.roundedBorder)
            Button("Ajouter") {
                let address = linkAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                guard URL(string: address)?.scheme?.hasPrefix("http") == true else { return }
                let title = linkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                store.update(course) { $0.resources.append(.init(id: UUID().uuidString, kind: linkKind, title: title.isEmpty ? address : title, url: address, fileName: nil, addedAt: Date(), chapter: chapter)) }
                linkTitle = ""; linkAddress = ""; addingLink = false
            }
            .buttonStyle(.ink)
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Lecteur

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }.buttonStyle(.plain)
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title) }.buttonStyle(.plain)
                Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }.buttonStyle(.plain)
                Text(player.title ?? "").font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 1.75, 2], id: \.self) { value in
                        Button("\(value == value.rounded() ? String(Int(value)) : String(value))×") { player.rate = value }
                    }
                } label: { Text("\(player.rate == player.rate.rounded() ? String(Int(player.rate)) : String(player.rate))×").font(.callout.monospacedDigit()) }
                    .menuStyle(.button).fixedSize()
                Button { player.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .foregroundStyle(Carnet.ink)
            ProgressView(value: min(player.elapsed, max(player.duration, 1)), total: max(player.duration, 1))
                .tint(tint)
            HStack {
                Text(Self.time(player.elapsed)); Spacer(); Text("−" + Self.time(max(0, player.duration - player.elapsed)))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

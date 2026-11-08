import SwiftUI
import SwiftData

/// Tes notes, dans le bureau : les cahiers du cours (GoodNotes → Google
/// Drive…) rangés par semaine, ta copie de la série en tête, et les notes du
/// cours en Markdown. Un outil à part entière, pour l'avoir à côté de
/// l'énoncé et de Claude plutôt que caché sous une source de l'onglet Cours.
struct NotesPane: View {
    let course: Course?
    /// Garder un cahier à côté (le volet de droite) : son chemin, son titre.
    var sendBeside: ((String, String) -> Void)? = nil

    @Environment(MacTimer.self) private var timer
    @Query private var allCourses: [Course]

    enum Selection: Hashable {
        case document(String)
        case courseNotes
    }

    @State private var selection: Selection?
    @AppStorage("notes.listHidden") private var listHidden = false

    private var store: NotesStore { .shared }

    private var documents: [NotesLibrary.Document] {
        guard let course else { return [] }
        return store.documents(for: course, among: allCourses)
    }

    /// La série du moment : celle de l'exercice suivi, sinon celle de la semaine.
    private var series: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    private var copy: NotesLibrary.Document? {
        guard let course, let series else { return nil }
        return store.copy(for: series, course: course, among: allCourses)
    }

    /// Ce qui s'ouvre d'abord : ta copie de la série, sinon le cahier le plus récent.
    private var initial: Selection? {
        if let copy { return .document(copy.path) }
        if let latest = documents.max(by: { $0.modified < $1.modified }) { return .document(latest.path) }
        return course.map { _ in .courseNotes }
    }

    var body: some View {
        if let course {
            HStack(spacing: 0) {
                if !listHidden || selection == nil {
                    list(course)
                        .frame(width: 280)
                    Rectangle().fill(Carnet.rule).frame(width: 1)
                }
                reader(course)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if selection != nil { listToggle }
                    }
            }
            .task { await store.refresh() }
            .task(id: course.id) { if selection == nil { selection = initial } }
            .onChange(of: copy?.path) { _, path in
                // Une autre série : sa copie, si on lisait celle d'avant.
                if let path, case .document(let current)? = selection, documents.first(where: { $0.path == current })?.seriesNumber != nil {
                    selection = .document(path)
                }
            }
        } else {
            ContentUnavailableView("Pas de cours", systemImage: "pencil.and.scribble",
                                   description: Text("Choisis-en un pour la session."))
        }
    }

    // MARK: Liste

    private func list(_ course: Course) -> some View {
        let tint = Carnet.tint(course.colorHex)
        let weeks = Array(Set(documents.map { $0.week ?? 0 })).sorted { ($0 == 0 ? -1 : $0) > ($1 == 0 ? -1 : $1) }
        return List(selection: $selection) {
            Section {
                if let copy {
                    row(copy, tint: tint, caption: series.map { String(localized: "Ta copie · Série \($0.seriesNumber)") })
                }
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notes du cours").foregroundStyle(Carnet.ink)
                        Text(course.notes.isEmpty ? "Barème, ce que le prof a dit…" : "Markdown")
                            .font(.caption2).foregroundStyle(Carnet.inkTertiary)
                    }
                } icon: {
                    Image(systemName: "text.alignleft").foregroundStyle(tint)
                }
                .tag(Selection.courseNotes)
            }
            ForEach(weeks, id: \.self) { week in
                Section {
                    ForEach(documents.filter { ($0.week ?? 0) == week && $0.path != copy?.path }.sorted { $0.modified > $1.modified }) { document in
                        row(document, tint: tint, caption: nil)
                    }
                } header: {
                    Text(week > 0 ? "Semaine \(week)" : "Autres").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                }
            }
            if documents.isEmpty {
                Section {
                    Text(store.root == nil
                         ? "Choisis le dossier où GoodNotes sauvegarde tes cahiers : Réglages › Personnaliser › Notes."
                         : "Aucun cahier de ce cours dans tes notes.")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Carnet.sheet.opacity(0.35))
    }

    private func row(_ document: NotesLibrary.Document, tint: Color, caption: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(document.title).foregroundStyle(Carnet.ink).lineLimit(2)
                Text(caption ?? document.modified.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(Carnet.inkTertiary)
            }
        } icon: {
            Image(systemName: document.isSolution ? "checkmark.seal" : (document.seriesNumber != nil ? "list.number" : "pencil.and.scribble"))
                .foregroundStyle(tint)
        }
        .tag(Selection.document(document.path))
    }

    // MARK: Lecture

    @ViewBuilder
    private func reader(_ course: Course) -> some View {
        switch selection {
        case .courseNotes?:
            ScrollView {
                CourseNotesView(course: course)
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            .background(Carnet.ground)
        case .document(let path)?:
            if let document = documents.first(where: { $0.path == path }), let url = store.url(document) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(document.title).font(.callout.weight(.medium)).foregroundStyle(Carnet.ink).lineLimit(1)
                        Spacer()
                        Text(document.modified.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(Carnet.inkTertiary)
                        Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Relire tes notes (GoodNotes sauvegarde de temps en temps)")
                        if let sendBeside {
                            Button { sendBeside(document.path, document.title) } label: { Label("À côté", systemImage: "sidebar.right") }
                                .buttonStyle(.paper)
                                .help("Garder ce cahier dans le volet d'à côté")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    PDFPane(url: url, memory: url.absoluteString)
                        // Le cahier a changé (GoodNotes l'a resauvegardé) : on le relit.
                        .id("\(path)#\(document.modified.timeIntervalSince1970)")
                }
                .background(Carnet.ground)
            } else {
                ContentUnavailableView("Cahier introuvable", systemImage: "questionmark.folder")
            }
        case nil:
            ContentUnavailableView("Tes notes", systemImage: "pencil.and.scribble",
                                   description: Text("Choisis un cahier à gauche."))
        }
    }

    private var listToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                listHidden.toggle()
            }
        } label: {
            Image(systemName: listHidden ? "sidebar.left" : "arrow.left.to.line")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Carnet.rule))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Carnet.ink)
        .padding(12)
        .help(listHidden ? "Montrer tes cahiers" : "Replier la liste pour lire en grand")
    }
}

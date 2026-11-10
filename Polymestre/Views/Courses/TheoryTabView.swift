import SwiftUI
import SwiftData

/// Théorie : la semaine en cours, puis chapitre par chapitre.
///
/// Tout support — vidéo, lecture, section de polycopié, diapos — est de la
/// théorie ; son type n'est plus qu'une icône. Un chapitre porte son **titre**
/// (« Suites réelles »), pas « Section 3 ».
struct TheoryTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @State private var selectedVideo: TheoryItem?
    /// L'élément ouvert dans l'app (section, vidéo, diapos).
    @State private var browsing: BrowsedLink?
    @State private var showingAdd = false
    @State private var showsDone = true

    private var week: Int { course.currentWeek }
    private var weekItems: [TheoryItem] {
        course.sortedTheoryItems.filter { $0.plannedWeek == week }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if course.theoryItems.isEmpty {
                EmptyCard(icon: TaskType.theory.icon,
                          title: String(localized: "Aucune théorie"),
                          message: String(localized: "Depuis Moodle, Courseware ou Botafogo."),
                          actionTitle: String(localized: "Importer la théorie")) {
                    app.router.openContentImport(courseID: course.id)
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Ajouter un élément à la main", systemImage: "plus")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                weekCard
                HStack {
                    SectionHeader(title: String(localized: "Tout le cours"), trailing: nil)
                    Button {
                        withAnimation(Motion.snappy) { showsDone.toggle() }
                    } label: {
                        Text(showsDone ? "Masquer le fait" : "Tout afficher")
                            .font(.caption.weight(.medium))
                    }
                }
                ForEach(course.theorySections, id: \.self) { section in
                    sectionCard(section)
                }
            }
        }
        .sheet(item: $selectedVideo) { video in
            VideoDetailSheet(video: video)
        }
        .sheet(isPresented: $showingAdd) {
            TheoryItemForm(course: course)
        }
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
    }

    // MARK: Semaine

    /// La semaine en cours : ce qu'il reste, cochable sur place.
    @ViewBuilder
    private var weekCard: some View {
        let done = weekItems.filter(\.isWatched).count
        let remainingSeconds = weekItems.filter { !$0.isWatched }.reduce(0) { $0 + $1.durationSeconds }
        let videos = weekItems.reduce(0) { $0 + $1.videoCount }
        Card(title: course.isTermRunning ? String(localized: "Semaine \(week)") : String(localized: "Hors semestre"),
             icon: "calendar",
             trailing: weekItems.isEmpty ? nil : "\(done)/\(weekItems.count)") {
            if weekItems.isEmpty {
                Text(course.isTermRunning
                     ? "Aucune théorie planifiée cette semaine."
                     : "Le semestre n'est pas en cours : le plan hebdomadaire est en pause.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Layout.control) {
                    ProgressBar(progress: CourseProgress.ratio(done, weekItems.count), color: TaskType.theory.tint)
                    if remainingSeconds > 0 || videos > 0 {
                        Text([videos > 0 ? Plural.count(videos, "\(videos) vidéo", "\(videos) vidéos") : nil,
                              remainingSeconds > 0 ? String(localized: "\(DateUtils.durationLabel(seconds: remainingSeconds)) à regarder") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(weekItems) { item in
                            VideoRow(video: item,
                                     isCurrentWeek: false,
                                     onToggleWatched: { toggleWatched(item) },
                                     onOpen: { selectedVideo = item },
                                     onOpenLink: { browsing = $0 })
                            if item.id != weekItems.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Chapitre

    @ViewBuilder
    private func sectionCard(_ section: Int) -> some View {
        let all = course.sortedTheoryItems.filter { $0.sectionNumber == section }
        let items = showsDone ? all : all.filter { !$0.isWatched }
        let watched = all.filter(\.isWatched).count
        let title = all.first(where: { !$0.sectionTitle.isEmpty })?.sectionTitle ?? String(localized: "Chapitre \(section)")
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                    MathText(title, font: .subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: Layout.inline)
                    Text("\(watched)/\(all.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(watched == all.count ? Color.green.accessibleInk : .secondary)
                }
                .padding(.bottom, Layout.inline)
                VStack(spacing: 0) {
                    ForEach(items) { video in
                        VideoRow(video: video,
                                 isCurrentWeek: video.plannedWeek == week && course.isTermRunning,
                                 onToggleWatched: { toggleWatched(video) },
                                 onOpen: { selectedVideo = video },
                                 onOpenLink: { browsing = $0 })
                        if video.id != items.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .padding(Layout.gutter)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    private func toggleWatched(_ video: TheoryItem) {
        if video.isWatched {
            video.watchedAt = nil
            video.summarizedAt = nil
        } else {
            video.watchedAt = Date()
        }
        // Pas de vibration ici : `CheckCircleButton` a déjà la sienne.
        try? context.save()
    }
}

/// Ligne de théorie : coche, numéro et titre, ce qu'elle contient.
struct VideoRow: View {
    let video: TheoryItem
    let isCurrentWeek: Bool
    var onToggleWatched: () -> Void
    var onOpen: () -> Void
    /// Ouvre l'élément lui-même — la section du polycopié, la vidéo, les
    /// diapos —, quand la source a donné son adresse.
    var onOpenLink: ((BrowsedLink) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            CheckCircleButton(isOn: video.isWatched,
                              tint: TaskType.theory.tint,
                              label: String(localized: "Marquer \(video.displayNumber) comme faite"),
                              action: onToggleWatched)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Layout.micro) {
                    HStack(spacing: Layout.snug) {
                        MathText(video.numberAndTitle, font: .subheadline)
                            .foregroundStyle(video.isWatched ? .secondary : .primary)
                            .lineLimit(2)
                        if isCurrentWeek {
                            Pill(text: "S\(video.plannedWeek)", color: TaskType.theory.tint)
                        }
                    }
                    if !meta.isEmpty {
                        HStack(spacing: Layout.snug) {
                            Image(systemName: video.kind.icon)
                            Text(meta)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Layout.snug)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onOpenLink, let url = ExerciseLinks.web(video.links.first { $0.kind == .video }?.url ?? video.urlString) {
                Button {
                    onOpenLink(BrowsedLink(title: "\(video.number) \(MathMarkup.plain(video.title))", url: url, icon: video.kind.icon))
                } label: {
                    Image(systemName: video.kind == .video ? "play.rectangle" : "arrow.up.right.square")
                        .font(.body)
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(video.kind == .video ? "Regarder" : "Ouvrir")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Layout.inline)
            }
        }
    }

    /// « 3 vidéos · 45 min · résumé », ce qui compte, sans « 0 min ».
    private var meta: String {
        var parts: [String] = []
        if video.videoCount > 1 { parts.append(String(localized: "\(video.videoCount) vidéos")) }
        else if video.videoCount == 1 || video.kind == .video { parts.append(String(localized: "Vidéo")) }
        else { parts.append(video.kind.label) }
        if video.hasDuration { parts.append(video.durationLabel) }
        if video.isSummarized { parts.append(String(localized: "résumé")) }
        if video.plannedWeek > 0 && !isCurrentWeek { parts.append("S\(video.plannedWeek)") }
        return parts.joined(separator: " · ")
    }
}

/// Détail d'une vidéo : dates, résumé, suppression.
struct VideoDetailSheet: View {
    @Bindable var video: TheoryItem
    /// Numéro, titre, support, lien : le formulaire commun (`TheoryItemForm`).
    @State private var editing = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var summary = ""
    @State private var browsing: BrowsedLink?
    @State private var plannedWeek = 1
    @State private var durationMinutes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Théorie") {
                    DetailRow(icon: "number", label: String(localized: "Numéro"), value: video.number, tint: video.kind.tint)
                    if !video.title.isEmpty {
                        DetailRow(icon: "text.alignleft", label: "Titre", value: video.title)
                    }
                    DetailRow(icon: video.kind.icon, label: "Support",
                              value: video.videoCount > 1 ? String(localized: "\(video.videoCount) vidéos") : video.kind.label)
                    if video.hasDuration {
                        DetailRow(icon: "clock", label: String(localized: "Durée"), value: video.durationLabel)
                    }
                    if let course = video.course {
                        DetailRow(icon: "books.vertical", label: String(localized: "Cours (au singulier)"), value: course.code)
                    }
                }

                Section("Suivi") {
                    DetailRow(icon: "checkmark.circle.fill",
                              label: String(localized: "Faite le"),
                              value: video.watchedAt.map { DateUtils.shortDay.string(from: $0) } ?? "—",
                              tint: .green)
                    DetailRow(icon: "doc.text.fill",
                              label: String(localized: "Résumé le"),
                              value: video.summarizedAt.map { DateUtils.shortDay.string(from: $0) } ?? "—",
                              tint: .teal)
                    Button {
                        if video.isWatched {
                            video.watchedAt = nil
                            video.summarizedAt = nil
                        } else {
                            video.watchedAt = Date()
                        }
                        Haptics.tap()
                        try? context.save()
                    } label: {
                        Label(video.isWatched ? "Marquer comme à faire" : "Marquer comme faite",
                              systemImage: video.isWatched ? "arrow.uturn.backward" : "checkmark.circle.fill")
                    }
                    .disabled(false)
                }

                Section {
                    // Enregistrée au changement : un bouton « Enregistrer la
                    // semaine » séparé se laissait oublier, et la valeur affichée
                    // n'était alors plus celle qui comptait.
                    Stepper("Semaine planifiée : \(plannedWeek)", value: $plannedWeek, in: 1...30)
                        .onChange(of: plannedWeek) { _, newValue in
                            guard video.plannedWeek != newValue else { return }
                            video.plannedWeek = newValue
                            try? context.save()
                        }
                    if video.kind.hasDuration {
                        Stepper("Durée : \(durationMinutes) min", value: $durationMinutes, in: 0...300, step: 5)
                            .onChange(of: durationMinutes) { _, newValue in
                                guard video.durationMinutes != newValue else { return }
                                video.durationSeconds = newValue * 60
                                try? context.save()
                            }
                    }
                    // Tous les supports de l'élément : l'enregistrement du cours,
                    // ses transparents, ses notes annotées.
                    if !video.links.isEmpty {
                        ForEach(video.links, id: \.url) { link in
                            if let url = ExerciseLinks.web(link.url) {
                                Button {
                                    browsing = BrowsedLink(title: link.title, url: url, icon: link.icon)
                                } label: {
                                    Label(link.title, systemImage: link.icon)
                                }
                            }
                        }
                    } else if let url = ExerciseLinks.web(video.urlString) {
                        Button {
                            browsing = BrowsedLink(title: video.numberAndTitle, url: url, icon: video.kind.icon)
                        } label: {
                            Label(video.kind == .video ? "Regarder la vidéo" : "Ouvrir le support", systemImage: video.kind == .video ? "play.rectangle" : "doc.text")
                        }
                    }
                } header: {
                    Text("Planification")
                }

                Section("Résumé") {
                    TextEditor(text: $summary)
                        .frame(minHeight: 140)
                }

                Section {
                    Button {
                        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        video.summaryText = trimmed
                        if !trimmed.isEmpty || video.isSummarized {
                            video.summarizedAt = Date()
                        }
                        if video.watchedAt == nil { video.watchedAt = Date() }
                        Haptics.success()
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Enregistrer le résumé", systemImage: "checkmark.circle.fill")
                    }

                    Button {
                        app.router.startFocus(courseID: video.course?.id,
                                              courseCode: video.course?.code ?? "",
                                              taskType: .theory,
                                              targetID: video.id,
                                              label: "\(video.course?.code ?? "") · \(video.displayNumber)")
                        dismiss()
                    } label: {
                        Label("Démarrer un chrono sur cet élément", systemImage: "timer")
                    }

                    Button(role: .destructive) {
                        context.delete(video)
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Supprimer cet élément", systemImage: "trash")
                    }
                }
            }
            .carnetBackground()
            .navigationTitle(video.displayNumber)
            .sheet(item: $browsing) { InAppBrowser(link: $0) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
                if video.course != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Modifier") { editing = true }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                if let course = video.course { TheoryItemForm(course: course, item: video) }
            }
            .onAppear {
                summary = video.summaryText ?? ""
                plannedWeek = video.plannedWeek
                durationMinutes = video.durationMinutes
            }
        }
    }
}

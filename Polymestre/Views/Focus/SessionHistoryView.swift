import SwiftUI
import SwiftData

/// Toutes les sessions enregistrées, jour par jour, modifiables.
///
/// Le journal ne montrait que la journée : une session saisie à la mauvaise date,
/// ou un chrono resté ouvert la veille, n'étaient plus atteignables — on ne pouvait
/// ni les corriger ni les supprimer. Or c'est ce temps qui nourrit la charge EPFL
/// et le temps partagé aux groupes : il doit rester **corrigeable**.
struct SessionHistoryView: View {
    /// Poussé dans une pile existante (profil) plutôt que présenté en feuille.
    var embedded: Bool = false

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var editing: StudySession?
    @State private var courseFilter: UUID?
    @State private var exportItem: ShareItem?

    private var filtered: [StudySession] {
        guard let courseFilter else { return sessions }
        return sessions.filter { $0.course?.id == courseFilter }
    }

    private var groups: [SessionStats.DayGroup] {
        SessionStats.groupedByDay(filtered)
    }

    private var totalSeconds: Int {
        filtered.reduce(0) { $0 + $1.durationSeconds }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView("Aucune session",
                                           systemImage: "clock",
                                           description: nil)
                } else {
                    Section {
                        LabeledContent("Total", value: DateUtils.hoursLabel(seconds: totalSeconds))
                        LabeledContent("Sessions", value: "\(filtered.count)")
                        LabeledContent("Jours actifs", value: "\(groups.count)")
                    }

                    ForEach(groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                row(session)
                            }
                            .onDelete { offsets in
                                delete(offsets, in: group.sessions)
                            }
                        } header: {
                            HStack {
                                Text(DateUtils.relativeLabel(group.day))
                                Spacer()
                                Text(DateUtils.hoursLabel(seconds: group.totalSeconds))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .adaptiveListColumn()
            .carnetBackground()
            .navigationTitle("Historique")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Cours (au singulier)", selection: $courseFilter) {
                            Text("Tous les cours").tag(UUID?.none)
                            ForEach(courses) { course in
                                Text(course.displayCode).tag(UUID?.some(course.id))
                            }
                        }
                        Divider()
                        Button {
                            exportItem = DataExporter.writeSessionsCSV(filtered).map(ShareItem.init)
                        } label: {
                            Label("Exporter en CSV", systemImage: "tablecells")
                        }
                    } label: {
                        Image(systemName: courseFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filtrer et exporter")
                }
            }
            .sheet(item: $editing) { session in
                SessionEditSheet(session: session)
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
    }

    private func row(_ session: StudySession) -> some View {
        Button {
            editing = session
        } label: {
            HStack(spacing: Layout.block) {
                Image(systemName: session.taskType.icon)
                    .foregroundStyle(session.taskType.tint.accessibleMark)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Layout.micro) {
                    HStack(spacing: Layout.snug) {
                        Text(session.course?.displayCode ?? String(localized: "Sans cours"))
                            .font(.subheadline.weight(.semibold))
                        Text(session.taskType.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle(session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.inline)
                Text(session.durationLabel)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Modifier la session")
    }

    private func subtitle(_ session: StudySession) -> String {
        var parts = [DateUtils.time.string(from: session.startedAt)]
        if let target = session.targetLabel { parts.append(target) }
        if session.isManual { parts.append(String(localized: "saisie manuelle")) }
        if !session.note.isEmpty { parts.append(session.note) }
        return parts.joined(separator: " · ")
    }

    private func delete(_ offsets: IndexSet, in items: [StudySession]) {
        for index in offsets where index < items.count {
            context.delete(items[index])
        }
        try? context.save()
        Haptics.tap()
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
    }
}

/// Un fichier à partager, adressable par `sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Modification d'une session : cours, type, cible, début, durée, note.
struct SessionEditSheet: View {
    @Bindable var session: StudySession

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var courseID: UUID?
    @State private var taskType: TaskType = .other
    @State private var startedAt = Date()
    @State private var minutes = 30
    /// La durée se saisit en deux roues : heures et minutes.
    @State private var hours = 0
    @State private var minutesPart = 30
    @State private var note = ""
    @State private var targetID: UUID?
    @State private var showingDelete = false

    private var course: Course? { courses.first { $0.id == courseID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Picker("Cours (au singulier)", selection: $courseID) {
                        Text("Aucun cours").tag(UUID?.none)
                        ForEach(courses) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                    Picker("Catégorie", selection: $taskType) {
                        // Une session Anki garde son étiquette ; on ne la choisit pas.
                        ForEach(taskType == .flashcards ? TaskType.choices + [.flashcards] : TaskType.choices) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                    if let course, !targetOptions(for: course).isEmpty {
                        Picker("Sur quoi ?", selection: $targetID) {
                            Text("Tout le cours").tag(UUID?.none)
                            ForEach(targetOptions(for: course), id: \.id) { option in
                                Text(option.label).tag(UUID?.some(option.id))
                            }
                        }
                    }
                }

                Section {
                    // La **roue** plutôt qu'un sélecteur compact : corriger « 1 h 05
                    // au lieu de 40 min » demandait treize taps sur un pas-à-pas.
                    DatePicker("Début", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.wheel)
                        .frame(maxHeight: 170)
                        .clipped()
                } header: {
                    Text("Début")
                }

                Section {
                    HStack(spacing: 0) {
                        Picker("Heures", selection: $hours) {
                            ForEach(0...12, id: \.self) { value in
                                Text("\(value) h").tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        Picker("Minutes", selection: $minutesPart) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                    .frame(height: 130)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Durée : \(DateUtils.durationLabel(seconds: minutes * 60))")
                } header: {
                    Text("Durée")
                } footer: {
                    Text("Total : \(DateUtils.durationLabel(seconds: minutes * 60)) — fin à \(DateUtils.time.string(from: startedAt.addingTimeInterval(TimeInterval(minutes * 60)))).")
                }

                Section("Note") {
                    TextField("Note (optionnel)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Button(role: .destructive) {
                        showingDelete = true
                    } label: {
                        Label("Supprimer la session", systemImage: "trash")
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Modifier la session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                }
            }
            .confirmationDialog("Supprimer cette session ?",
                                isPresented: $showingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    context.delete(session)
                    try? context.save()
                    Haptics.removed()
                    WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
                    dismiss()
                }
                Button("Annuler", role: .cancel) {}
            }
            .onAppear(perform: load)
            .onChange(of: hours) { _, _ in minutes = max(1, hours * 60 + minutesPart) }
            .onChange(of: minutesPart) { _, _ in minutes = max(1, hours * 60 + minutesPart) }
            .onChange(of: courseID) { _, _ in targetID = nil }
            .onChange(of: taskType) { _, _ in targetID = nil }
        }
    }

    private struct TargetOption { let id: UUID; let label: String }

    private func targetOptions(for course: Course) -> [TargetOption] {
        switch taskType {
        case .exercise, .correction:
            return course.allExercises
                .sorted { $0.displayNumber.localizedStandardCompare($1.displayNumber) == .orderedAscending }
                .map { TargetOption(id: $0.id, label: $0.displayNumber) }
        case .video, .theory, .summary:
            return course.sortedTheoryItems.map { TargetOption(id: $0.id, label: $0.displayNumber) }
        default:
            return []
        }
    }

    private func load() {
        courseID = session.course?.id
        // Une ancienne session « Vidéo » s'édite comme de la théorie.
        taskType = session.taskType.canonical
        startedAt = session.startedAt
        minutes = max(1, Int(session.durationSeconds / 60))
        hours = minutes / 60
        // La roue des minutes va de 5 en 5 : on arrondit la valeur existante pour
        // qu'elle soit atteignable, plutôt que d'afficher une position impossible.
        minutesPart = min(55, (minutes % 60) / 5 * 5)
        note = session.note
        let target = session.exercise?.id ?? session.theoryItem?.id
        Task { @MainActor in targetID = target }
    }

    private func save() {
        session.course = course
        session.taskType = taskType
        session.startedAt = startedAt
        session.durationSeconds = minutes * 60
        session.note = note
        session.exercise = course?.allExercises.first { $0.id == targetID }
        session.theoryItem = course?.theoryItems.first { $0.id == targetID }
        try? context.save()
        Haptics.success()
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
        dismiss()
    }
}

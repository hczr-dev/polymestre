import SwiftUI
import SwiftData

/// Création ou modification d'une évaluation (midterm, examen, quiz…).
///
/// Il n'existait **aucun** écran pour saisir une évaluation : l'onglet Agenda du
/// cours renvoyait vers « Modifier le cours », qui n'en parlait pas. L'agenda des
/// midterms et examens — une exigence du produit — n'était accessible que par
/// import JSON/CSV.
struct ExamFormSheet: View {
    let course: Course
    /// `nil` = création.
    var exam: Exam?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings

    @State private var kind: ExamKind = .midterm
    @State private var title = ""
    @State private var date = DateUtils.addDays(7, to: Date())
    @State private var hasWeight = true
    @State private var weight = 30.0
    @State private var location = ""
    @State private var notes = ""
    @State private var showingDelete = false

    private var isEditing: Bool { exam != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Évaluation") {
                    Picker("Type", selection: $kind) {
                        ForEach(ExamKind.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                    TextField("Titre (ex : Midterm)", text: $title)
                    DatePicker("Date et heure", selection: $date,
                               displayedComponents: [.date, .hourAndMinute])
                    TextField("Lieu (ex : Polydôme)", text: $location)
                }

                Section {
                    Toggle("Pondération connue", isOn: $hasWeight)
                    if hasWeight {
                        Stepper("Poids : \(Int(weight)) % de la note",
                                value: $weight, in: 0...100, step: 5)
                    }
                } header: {
                    Text("Pondération")
                }

                Section("Notes") {
                    TextField("Matière couverte, consignes…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Label(reminderLabel, systemImage: "bell")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDelete = true
                        } label: {
                            Label("Supprimer cette évaluation", systemImage: "trash")
                        }
                    }
                }
            }
            .carnetBackground()
            .navigationTitle(isEditing ? "Modifier l'évaluation" : "Nouvelle évaluation")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Enregistrer" : "Ajouter") { save() }
                }
            }
            .confirmationDialog("Supprimer « \(title.isEmpty ? kind.label : title) » ?",
                                isPresented: $showingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { delete() }
                Button("Annuler", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private var reminderLabel: String {
        date > Date()
            ? String(localized: "Rappel 3 jours et 1 jour avant.")
            : String(localized: "Évaluation passée : aucun rappel.")
    }

    private func load() {
        guard let exam else { return }
        kind = exam.kind
        title = exam.title
        date = exam.date
        hasWeight = exam.weightPercent != nil
        weight = exam.weightPercent ?? 30
        location = exam.location
        notes = exam.notes
    }

    private func save() {
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces)
        if let exam {
            exam.kind = kind
            exam.title = resolvedTitle.isEmpty ? kind.label : resolvedTitle
            exam.date = date
            exam.weightPercent = hasWeight ? weight : nil
            exam.location = location.trimmingCharacters(in: .whitespaces)
            exam.notes = notes
            NotificationScheduler.shared.cancelExam(id: exam.id)
            scheduleReminder(for: exam)
        } else {
            let created = Exam(course: course,
                               kind: kind,
                               title: resolvedTitle,
                               date: date,
                               weightPercent: hasWeight ? weight : nil,
                               location: location.trimmingCharacters(in: .whitespaces),
                               notes: notes)
            context.insert(created)
            scheduleReminder(for: created)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func scheduleReminder(for exam: Exam) {
        NotificationScheduler.shared.scheduleExamReminders(id: exam.id,
                                                title: "\(course.displayCode) · \(exam.title)",
                                                examDate: exam.date)
    }

    private func delete() {
        guard let exam else { return }
        NotificationScheduler.shared.cancelExam(id: exam.id)
        context.delete(exam)
        try? context.save()
        Haptics.removed()
        dismiss()
    }
}

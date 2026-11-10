import SwiftUI
import SwiftData

/// Une note rapide, rangée dans les notes d'un cours, datée.
///
/// Ce qu'on veut retenir arrive n'importe quand — en amphi, dans le métro,
/// devant une autre fenêtre : « le midterm couvre jusqu'au chapitre 5 »,
/// « demander la 3.4 à l'assistant ». Une ligne, un cours, et c'est rangé.
struct QuickNoteSheet: View {
    /// Le cours proposé d'abord (celui du chrono, celui qu'on regarde).
    var preferredCourseID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var courseID: UUID?
    @State private var text = ""
    @FocusState private var focused: Bool

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cours (au singulier)", selection: $courseID) {
                        ForEach(tracked) { course in
                            Text("\(course.displayCode) · \(course.name)").tag(Optional(course.id))
                        }
                    }
                    TextField("Ce que tu veux retenir", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                }
            }
            .formStyle(.grouped)
            .carnetBackground()
            .navigationTitle("Note rapide")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ranger") { save() }
                        .disabled(courseID == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                courseID = preferredCourseID.flatMap { id in tracked.first { $0.id == id }?.id } ?? tracked.first?.id
                focused = true
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 260)
        #endif
    }

    private func save() {
        guard let course = tracked.first(where: { $0.id == courseID }) else { return }
        QuickNote.append(text, to: course)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

/// L'ajout d'une ligne datée aux notes d'un cours (l'écran, Siri, le Mac).
enum QuickNote {
    static func append(_ text: String, to course: Course, at date: Date = Date()) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let stamp = date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let entry = "- **\(stamp)** — \(line)"
        let current = course.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        course.notes = current.isEmpty ? entry : current + "\n" + entry
    }
}

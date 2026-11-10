import SwiftUI
import SwiftData

/// Composition des raccourcis du chrono.
///
/// La grille était fixe : tous les cours suivis croisés avec trois types de
/// travail, soit douze tuiles dont on n'utilisait jamais les mêmes. On choisit
/// désormais sa liste, dans l'ordre où on la veut.
struct FocusShortcutsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var shortcuts: [FocusShortcut] = []
    @State private var newCourseCode = ""
    @State private var newType: TaskType = .exercise

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }

    private var availableCourses: [Course] {
        // On propose d'abord les cours suivis ; un cours déjà utilisé partout reste
        // proposé, sinon on ne pourrait plus le rajouter après l'avoir retiré.
        trackedCourses
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if shortcuts.isEmpty {
                        Text("Aucun raccourci.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shortcuts) { shortcut in
                            HStack(spacing: Layout.control) {
                                Image(systemName: shortcut.icon)
                                    .foregroundStyle(Theme.accent.accessibleMark)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(shortcut.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(shortcut.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Layout.inline)
                            }
                        }
                        .onDelete { offsets in
                            shortcuts.remove(atOffsets: offsets)
                            save()
                        }
                        .onMove { source, destination in
                            shortcuts.move(fromOffsets: source, toOffset: destination)
                            save()
                        }
                    }
                } header: {
                    Text("Mes raccourcis")
                }

                Section {
                    Picker("Cours (au singulier)", selection: $newCourseCode) {
                        Text("Choisir…").tag("")
                        ForEach(availableCourses) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(course.displayCode)
                        }
                    }
                    Picker("Travail", selection: $newType) {
                        ForEach(TaskType.choices) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                    Button {
                        add()
                    } label: {
                        Label("Ajouter ce raccourci", systemImage: "plus.circle.fill")
                    }
                    .disabled(newCourseCode.isEmpty || shortcuts.contains(FocusShortcut(courseCode: newCourseCode, taskType: newType)))
                } header: {
                    Text("Ajouter")
                }

                Section {
                    Button {
                        shortcuts = FocusShortcutDefaults.make(
                            from: trackedCourses.map(\.displayCode))
                        save()
                        Haptics.tap()
                    } label: {
                        Label("Repartir des valeurs proposées", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(trackedCourses.isEmpty)
                }
            }
            .carnetBackground()
            .navigationTitle("Raccourcis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminer") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        shortcuts = app.settings.focusShortcuts
        if shortcuts.isEmpty {
            shortcuts = FocusShortcutDefaults.make(from: trackedCourses.map(\.displayCode))
        }
        if newCourseCode.isEmpty, let first = availableCourses.first {
            newCourseCode = first.displayCode
        }
    }

    private func add() {
        let shortcut = FocusShortcut(courseCode: newCourseCode, taskType: newType)
        guard !shortcuts.contains(shortcut) else { return }
        shortcuts.append(shortcut)
        save()
        Haptics.tap()
    }

    /// Enregistre en nettoyant : un cours supprimé depuis ne doit pas laisser une
    /// tuile qui ne mène nulle part.
    private func save() {
        let known = Set(courses.map(\.displayCode))
        app.settings.focusShortcuts = FocusShortcutDefaults.sanitize(shortcuts, knownCourses: known)
        shortcuts = app.settings.focusShortcuts
    }
}

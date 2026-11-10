import SwiftUI
import SwiftData

/// Ajouter une session faite sans le chrono.
///
/// C'était un segment de Focus, au même rang que le chrono. C'est un geste rare
/// — on a oublié de lancer le chrono, on a travaillé à la bibliothèque — et il a
/// sa place dans une feuille, avec les durées usuelles à un toucher.
struct ManualSessionSheet: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var courseID: UUID?
    @State private var taskType: TaskType = .exercise
    @State private var minutes = 45
    @State private var date = Date().addingTimeInterval(-45 * 60)
    @State private var note = ""

    private static let presets = [25, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cours (au singulier)", selection: $courseID) {
                        Text("Sans cours").tag(UUID?.none)
                        ForEach(courses.filter(\.isTracked)) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                    Picker("Type", selection: $taskType) {
                        ForEach(TaskType.choices) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: Layout.block) {
                        HStack {
                            Text("Durée")
                            Spacer()
                            Text(DateUtils.durationLabel(seconds: minutes * 60))
                                .font(.body.weight(.semibold).monospacedDigit())
                                .contentTransition(.numericText(value: Double(minutes)))
                        }
                        HStack(spacing: Layout.inline) {
                            ForEach(Self.presets, id: \.self) { preset in
                                Button {
                                    withAnimation(Motion.snappy) { minutes = preset }
                                    Haptics.tap()
                                } label: {
                                    Text(preset < 60 ? "\(preset)" : DateUtils.durationLabel(seconds: preset * 60))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(minutes == preset ? Theme.accent.badgeFill : Color(.tertiarySystemFill),
                                                    in: Capsule())
                                        .foregroundStyle(minutes == preset ? Theme.accent.badgeInk : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Stepper("Ajuster de 5 min", value: $minutes, in: 5...600, step: 5)
                    DatePicker("Commencée", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    TextField("Note (optionnel)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .carnetBackground()
            .navigationTitle("Session passée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let session = StudySession(course: courses.first { $0.id == courseID },
                                   taskType: taskType,
                                   startedAt: date,
                                   durationSeconds: minutes * 60,
                                   isManual: true,
                                   note: note)
        context.insert(session)
        try? context.save()
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
        Haptics.success()
        dismiss()
    }
}

/// Les durées du cycle Pomodoro.
///
/// Un seul formulaire, présenté depuis le chrono et repris dans les réglages :
/// deux copies finiraient par diverger.
struct PomodoroSettingsForm: View {
    @Bindable var settings: SettingsStore
    @Environment(AppContainer.self) private var app

    var body: some View {
        Group {
            sections
        }
        // Les nouvelles durées valent pour la session ouverte (et l'autre
        // appareil) : fin de bloc et notification recalculées, d'où qu'on les
        // change — la feuille du chrono ou les réglages.
        .onChange(of: settings.pomodoro) { _, _ in app.focus.settingsDidChange() }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Stepper(value: $settings.pomodoroFocusMinutes, in: 5...120, step: 5) {
                LabeledContent("Bloc de travail", value: "\(settings.pomodoroFocusMinutes) min")
            }
            Stepper(value: $settings.pomodoroBreakMinutes, in: 1...30) {
                LabeledContent("Pause courte", value: "\(settings.pomodoroBreakMinutes) min")
            }
            Stepper(value: $settings.pomodoroLongBreakMinutes, in: 5...60, step: 5) {
                LabeledContent("Pause longue", value: "\(settings.pomodoroLongBreakMinutes) min")
            }
            Stepper(value: $settings.pomodoroLongBreakEvery, in: 2...8) {
                LabeledContent("Pause longue tous les", value: "\(settings.pomodoroLongBreakEvery) blocs")
            }
        } header: {
            Text("Cycle")
        }

        Section {
            Toggle("Relancer le bloc après la pause", isOn: $settings.pomodoroAutoStartFocus)
            Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
        }
    }
}

struct PomodoroSettingsSheet: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PomodoroSettingsForm(settings: app.settings)
            }
            .carnetBackground()
            .navigationTitle("Pomodoro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

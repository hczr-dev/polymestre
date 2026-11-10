import SwiftUI
import SwiftData

/// Boîte de réception unifiée des tâches (Rappels, Todoist, Things, Notion, webhook).
struct TasksView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var showingAdd = false

    private var openTasks: [LinkedTask] { tasks.filter { !$0.isDone } }
    private var overdue: [LinkedTask] { openTasks.filter { $0.isOverdue } }
    private var today: [LinkedTask] { openTasks.filter { $0.isDueToday && !$0.isOverdue } }
    private var upcoming: [LinkedTask] {
        openTasks.filter {
            guard let due = $0.dueDate else { return false }
            return due > Date() && !Calendar.current.isDateInToday(due)
        }
    }
    private var someday: [LinkedTask] { openTasks.filter { $0.dueDate == nil } }
    private var completed: [LinkedTask] { Array(tasks.filter(\.isDone).suffix(15).reversed()) }

    private var activeProviders: [TaskService] {
        TaskServiceFactory.shared.configuredServices(settings: app.settings)
    }

    var body: some View {
        NavigationStack {
            List {
                if !activeProviders.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(activeProviders, id: \.provider) { service in
                                    Pill(text: service.provider.label,
                                         color: service.provider.supportsReading ? .green : .orange,
                                         icon: service.provider.icon)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } header: {
                        Text("Fournisseurs actifs")
                    }
                }

                if tasks.isEmpty {
                    Section {
                        EmptyCard(icon: "checklist",
                                  title: String(localized: "Aucune tâche"),
                                  message: String(localized: "Relie une app de tâches dans les réglages, ou ajoutes-en une."),
                                  actionTitle: String(localized: "Ajouter une tâche")) {
                            showingAdd = true
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                } else {
                    section(String(localized: "En retard"), overdue, tint: .red)
                    section(String(localized: "Aujourd'hui"), today, tint: .orange)
                    section(String(localized: "À venir"), upcoming, tint: .blue)
                    section(String(localized: "Sans échéance"), someday, tint: .secondary)
                    section(String(localized: "Terminées récemment"), completed, tint: .green)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Tâches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await sync() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isSyncing)
                    .accessibilityLabel("Synchroniser")
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ajouter une tâche")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddTaskView()
            }
            .refreshable {
                await sync()
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LinkedTask], tint: Color) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { task in
                    taskRow(task, tint: tint)
                }
                .onDelete { offsets in
                    delete(offsets, in: items)
                }
            } header: {
                Text(ui: title)
            }
        }
    }

    private func taskRow(_ task: LinkedTask, tint: Color) -> some View {
        HStack(spacing: 10) {
            CheckCircleButton(isOn: task.isDone,
                              tint: tint,
                              label: "Terminer \(task.title)") {
                Task { await toggle(task) }
            }

            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(task.title)
                    .font(.subheadline)
                    .strikethrough(task.isDone)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: task.provider.icon).font(.caption2)
                    Text(task.provider.label)
                    if let due = task.dueDate {
                        Text("· \(DateUtils.shortDay.string(from: due))")
                    }
                    if let link = task.linkLabel {
                        Text("· \(link)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if task.course == nil, !task.isDone {
                Menu {
                    ForEach(courses) { course in
                        Button(course.code) {
                            task.course = course
                            try? context.save()
                        }
                    }
                } label: {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Lier la tâche « \(task.title) » à un cours")
            }
        }
    }

    // MARK: Actions

    private func delete(_ offsets: IndexSet, in items: [LinkedTask]) {
        for index in offsets where index < items.count {
            let task = items[index]
            if let externalID = task.externalID,
               let service = TaskServiceFactory.shared.service(for: task.provider, settings: app.settings) {
                Task { _ = await service.deleteTask(identifier: externalID) }
            }
            context.delete(task)
        }
        try? context.save()
    }

    private func toggle(_ task: LinkedTask) async {
        await TaskSync.setDone(task, !task.isDone, context: context, settings: app.settings)
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }

        let reminders = TaskServiceFactory.shared.service(for: .reminders, settings: app.settings)
        if let reminders {
            _ = await reminders.requestAccess()
        }

        let result = await TaskSync.sync(context: context, settings: app.settings)
        TaskSync.autoLink(tasks: (try? context.fetch(FetchDescriptor<LinkedTask>())) ?? [], courses: courses)
        try? context.save()

        if activeProviders.isEmpty {
            statusMessage = String(localized: "Aucune app de tâches reliée (Réglages › Tâches).")
        } else if result.fetched == 0 {
            statusMessage = String(localized: "Aucune tâche récupérée.")
        } else {
            statusMessage = String(localized: "\(result.fetched) tâche(s) · \(result.created) nouvelle(s) · \(result.updated) mise(s) à jour.")
        }
    }
}

/// Ajout d'une tâche, dans le fournisseur de son choix.
struct AddTaskView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = true
    @State private var dueDate = Date()
    @State private var provider: TaskProvider = .reminders
    @State private var courseID: UUID?
    @State private var isSaving = false

    private var availableProviders: [TaskProvider] {
        let configured = TaskServiceFactory.shared.configuredServices(settings: app.settings)
            .map(\.provider)
        return configured.isEmpty ? [.reminders] : configured
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tâche") {
                    TextField("Titre", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                Section("Échéance") {
                    Toggle("Définir une échéance", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Date", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Créer dans") {
                    Picker("Fournisseur", selection: $provider) {
                        ForEach(availableProviders) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                    if !provider.supportsReading {
                        Text("\(provider.label) est en écriture seule : la tâche sera créée, mais son état restera local.")
                            .font(.footnote)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                }
                Section("Cours lié") {
                    Picker("Cours (au singulier)", selection: $courseID) {
                        Text("Aucun").tag(UUID?.none)
                        ForEach(courses) { course in
                            Text(course.displayCode).tag(UUID?.some(course.id))
                        }
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Nouvelle tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear {
                if let first = availableProviders.first { provider = first }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let due = hasDueDate ? dueDate : nil
        let service = TaskServiceFactory.shared.service(for: provider, settings: app.settings)

        if provider == .reminders {
            _ = await service?.requestAccess()
        }

        var externalID: String?
        if let service,
           let external = await service.createTask(title: title,
                                                   notes: notes,
                                                   dueDate: due,
                                                   priority: 1) {
            externalID = external.identifier
        }

        let task = LinkedTask(provider: provider,
                              externalID: externalID,
                              title: title,
                              note: notes,
                              dueDate: due)
        task.course = courses.first { $0.id == courseID }
        context.insert(task)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

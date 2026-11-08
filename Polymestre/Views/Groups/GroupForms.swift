import SwiftUI
import SwiftData

/// Création d'un groupe : un nom, et **plusieurs** matières.
///
/// Un groupe d'entraide porte presque toujours sur plusieurs cours — c'est la même
/// promo, pas la même matière. Demander un seul code obligeait à créer trois
/// groupes pour trois cours suivis avec les mêmes personnes.
struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var name = ""
    @State private var details = ""
    @State private var selected: [String] = []
    @State private var typedCode = ""
    @State private var isWorking = false
    @State private var message: String?

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }

    private var offered: [(code: String, name: String)] {
        var seen = Set<String>()
        var result: [(code: String, name: String)] = []
        for course in trackedCourses {
            let code = course.code.uppercased()
            guard seen.insert(code).inserted else { continue }
            result.append((code, course.name))
        }
        for code in selected where seen.insert(code).inserted {
            result.append((code, String(localized: "Hors de tes cours")))
        }
        return result.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Groupe") {
                    TextField("Nom du groupe", text: $name)
                    TextField("Description (optionnel)", text: $details, axis: .vertical)
                }

                Section {
                    ForEach(offered, id: \.code) { entry in
                        Button {
                            toggle(entry.code)
                        } label: {
                            HStack(spacing: Layout.control) {
                                Image(systemName: selected.contains(entry.code) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(entry.code) ? Theme.accent.accessibleMark : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.code)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(entry.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: Layout.inline)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if trackedCourses.isEmpty {
                        Text("Aucun cours suivi : ajoute un code ci-dessous.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Layout.control) {
                        TextField("Ajouter un code (ex : CS-250)", text: $typedCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                        Button("Ajouter") { addTyped() }
                            .disabled(StudyGroup.normalize([typedCode]).isEmpty)
                    }
                } header: {
                    Text("Matières du groupe")
                }

                Section {
                    if isWorking {
                        HStack(spacing: Layout.inline) {
                            ProgressView()
                            Text("Envoi au serveur…").font(.caption)
                        }
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Nouveau groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
        }
    }

    private func toggle(_ code: String) {
        Haptics.tap()
        if let index = selected.firstIndex(of: code) {
            selected.remove(at: index)
        } else {
            selected.append(code)
        }
    }

    private func addTyped() {
        guard let code = StudyGroup.normalize([typedCode]).first else { return }
        if !selected.contains(code) { selected.append(code) }
        typedCode = ""
        Haptics.tap()
    }

    /// Crée le groupe **localement d'abord**, puis le pousse au serveur.
    ///
    /// L'ordre compte : hors ligne, le groupe reste utilisable immédiatement. Mais
    /// sans l'appel distant il n'existe que sur cet appareil — c'est pourquoi aucun
    /// groupe n'apparaissait jamais dans Supabase, et pourquoi personne ne pouvait
    /// le rejoindre avec son code.
    private func create() {
        let subjects = StudyGroup.normalize(selected)
        let group = StudyGroup(name: name,
                               details: details,
                               courseCodes: subjects)
        context.insert(group)
        let me = GroupMember(group: group,
                             userID: app.social.userID ?? "me",
                             displayName: displayName,
                             isMe: true,
                             role: .admin,
                             courseCodes: subjects)
        context.insert(me)
        try? context.save()

        guard app.social.isSignedIn else {
            dismiss()
            return
        }

        isWorking = true
        Task {
            do {
                let remote = try await app.social.createGroup(name: group.name,
                                                              description: group.details,
                                                              courseCode: "",
                                                              courseCodes: subjects,
                                                              displayName: displayName)
                group.remoteID = remote.id
                if !remote.inviteCode.isEmpty { group.inviteCode = remote.inviteCode }
                try? context.save()
                await MainActor.run {
                    isWorking = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    message = String(localized: "Groupe créé sur cet appareil, mais l'envoi au serveur a échoué — \(GroupSync.explain(error))")
                }
            }
        }
    }

    private var displayName: String {
        let configured = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? "Moi" : configured
    }
}

/// Rejoindre un groupe via un code d'invitation.
struct JoinGroupView: View {
    /// Code déjà connu : lien profond, ou feuille rouverte depuis la liste.
    var prefilledCode: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var code = ""
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Code d'invitation") {
                    TextField("EPFL-XXXX", text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Rejoindre un groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rejoindre") { join() }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
            .onAppear {
                let normalized = StudyGroup.normalizeInviteCode(prefilledCode)
                if !normalized.isEmpty { code = normalized }
            }
        }
    }

    /// Cherche d'abord sur l'appareil, puis **sur le serveur**.
    ///
    /// Le second chemin est le seul qui permette de rejoindre un groupe créé par un
    /// camarade : il n'existe évidemment pas dans la base locale.
    private func join() {
        let normalized = StudyGroup.normalizeInviteCode(code)
        let existing = try? context.fetch(FetchDescriptor<StudyGroup>())

        if let match = existing?.first(where: { $0.inviteCode.uppercased() == normalized }) {
            if !match.members.contains(where: \.isMe) {
                context.insert(GroupMember(group: match,
                                           userID: app.social.userID ?? "me",
                                           displayName: displayName,
                                           isMe: true,
                                           role: .member,
                                           courseCodes: match.subjectCodes))
                try? context.save()
            }
            // Le groupe est connu ici mais pas forcément mon adhésion **là-bas** :
            // sans elle, la présence et l'avancement sont refusés par RLS.
            if let remoteID = match.remoteID, app.social.isSignedIn {
                Task { try? await app.social.ensureMembership(groupID: remoteID, role: .member) }
            }
            dismiss()
            return
        }

        guard app.social.isSignedIn else {
            message = String(localized: "Aucun groupe sur cet appareil avec ce code. Connecte-toi pour chercher un groupe distant.")
            return
        }

        isWorking = true
        Task {
            do {
                let remote = try await app.social.joinGroup(inviteCode: normalized,
                                                            displayName: displayName)
                await MainActor.run {
                    let joined = StudyGroup(name: remote.name,
                                            details: remote.description ?? "",
                                            courseCode: remote.courseCode ?? "",
                                            courseCodes: remote.subjectCodes,
                                            isAdmin: false)
                    joined.remoteID = remote.id
                    if !remote.inviteCode.isEmpty { joined.inviteCode = remote.inviteCode }
                    context.insert(joined)
                    context.insert(GroupMember(group: joined,
                                               userID: app.social.userID ?? "me",
                                               displayName: displayName,
                                               isMe: true,
                                               role: .member,
                                               courseCodes: joined.subjectCodes))
                    try? context.save()
                    isWorking = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    message = String(localized: "Impossible de rejoindre ce groupe — \(GroupSync.explain(error))")
                }
            }
        }
    }

    private var displayName: String {
        let configured = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? "Moi" : configured
    }
}

/// Planification d'une session d'étude (personnelle ou de groupe).
struct PlanSessionView: View {
    var group: StudyGroup?
    /// Début proposé (l'agenda passe le jour choisi).
    var defaultStart: Date? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var title = ""
    @State private var selectedCourseID: UUID?
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var durationMinutes = 90
    @State private var location = ""
    @State private var shareWithGroup = true
    @State private var addToCalendar = false
    @State private var calendarMessage: String?

    /// Les cours proposés : ceux du groupe quand il y en a un, tous les miens sinon.
    private var selectableCourses: [Course] {
        guard let group, !group.subjectCodes.isEmpty else { return courses }
        return courses.filter { group.tracks($0.code) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Titre", text: $title)
                    Picker("Cours", selection: $selectedCourseID) {
                        Text("Aucun").tag(UUID?.none)
                        ForEach(selectableCourses) { course in
                            Text("\(course.code) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                    DatePicker("Début", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    Stepper("Durée : \(durationMinutes) min", value: $durationMinutes, in: 15...480, step: 15)
                    TextField("Lieu", text: $location)
                }

                if let group {
                    Section("Partage") {
                        Toggle("Partager avec \(group.name)", isOn: $shareWithGroup)
                    }
                }

                Section("Calendrier") {
                    Toggle("Ajouter à mon calendrier", isOn: $addToCalendar)
                    if let calendarMessage {
                        Text(calendarMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Planifier une session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Planifier") { Task { await save() } }
                }
            }
            .onAppear {
                if let defaultStart { startsAt = defaultStart }
                if selectedCourseID == nil, selectableCourses.count == 1 {
                    selectedCourseID = selectableCourses.first?.id
                }
            }
        }
    }

    private func save() async {
        let course = selectableCourses.first { $0.id == selectedCourseID }
        var calendarEventID = ""
        var message: String?

        if addToCalendar {
            if !app.calendar.hasAccess {
                _ = await app.calendar.requestAccess()
            }
            let spec = CalendarEventSpec(
                title: title.isEmpty ? String(localized: "Session d'étude") : title,
                startsAt: startsAt,
                endsAt: startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                location: location,
                notes: course.map { "\($0.code) — \($0.name)" } ?? ""
            )
            if let identifier = app.calendar.createEvent(spec) {
                calendarEventID = identifier
            } else {
                message = String(localized: "Ajout au calendrier impossible (accès refusé).")
            }
        }

        let session = PlannedSession(course: course,
                                     groupRemoteID: (group != nil && shareWithGroup) ? (group?.remoteID ?? group?.inviteCode) : nil,
                                     groupName: (group != nil && shareWithGroup) ? (group?.name ?? "") : "",
                                     title: title.isEmpty ? String(localized: "Session d'étude") : title,
                                     startsAt: startsAt,
                                     durationMinutes: durationMinutes,
                                     location: location,
                                     createdByUserID: "me",
                                     goingCount: 1)
        session.externalCalendarEventID = calendarEventID
        context.insert(session)

        // Rappel local avant la session.
        app.notifications.scheduleSessionReminder(id: session.id,
                                                  title: session.title,
                                                  date: session.startsAt,
                                                  location: session.location)

        // Publication dans le groupe distant si connecté.
        if let group, shareWithGroup, app.social.isSignedIn, let remoteID = group.remoteID {
            _ = try? await app.social.createPlannedSession(groupID: remoteID,
                                                           courseCode: course?.code ?? "",
                                                           title: session.title,
                                                           startsAt: startsAt,
                                                           durationMinutes: durationMinutes,
                                                           location: location)
        }

        try? context.save()

        if let message {
            calendarMessage = message
            return
        }
        dismiss()
    }
}

/// Ce qu'une session planifiée entraîne ailleurs — calendrier système et rappel —
/// et qu'il faut défaire avec elle. Partagé par l'agenda et le planning de groupe.
enum PlannedSessionActions {
    @MainActor
    static func delete(_ session: PlannedSession, context: ModelContext, app: AppContainer) {
        if !session.externalCalendarEventID.isEmpty {
            app.calendar.deleteEvent(identifier: session.externalCalendarEventID)
        }
        app.notifications.cancelSession(id: session.id)
        context.delete(session)
        try? context.save()
        Haptics.tap()
    }
}

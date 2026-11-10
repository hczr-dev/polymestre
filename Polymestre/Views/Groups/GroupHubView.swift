import SwiftUI
import SwiftData

/// Un groupe, sur une seule page : qui travaille maintenant, le classement de
/// la semaine, qui en est où dans la série, l'entraide, les sessions.
///
/// Les groupes étaient une liste, puis une fiche, puis quatre sous-pages : il
/// fallait trois touchers pour savoir si quelqu'un travaillait, et rien ne
/// donnait envie d'y revenir. Ici, l'onglet **est** le groupe. Ce qui change
/// souvent (le direct, les questions) est en haut ; ce qui se règle rarement
/// (membres, matières, invitation, quitter) est dans le menu « ⋯ ».
struct GroupHubView: View {
    @Bindable var group: StudyGroup

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var myCourses: [Course]
    @Query(sort: \PlannedSession.startsAt) private var allPlanned: [PlannedSession]

    @State private var presence: [PresenceEntry] = []
    @State private var presenceError: String?
    @State private var posts: [RemotePost] = []
    @State private var postsError: String?
    @State private var now = Date()
    @State private var composing = false
    @State private var openedThread: RemotePost?
    @State private var showingPlan = false
    /// Où en est le chiffrement de l'entraide sur ce téléphone.
    @State private var encryption: GroupEncryption.State?

    // MARK: Dérivés

    private var isOnline: Bool { group.remoteID != nil && app.social.isSignedIn }
    private var liveEntries: [PresenceEntry] { PresenceBoard.live(presence, at: now) }
    private var trackedCodes: Set<String> { Set(myCourses.filter(\.isTracked).map { $0.code.uppercased() }) }
    private var mySubjects: [String] {
        let shared = group.mySubjectCodes(myTrackedCourses: trackedCodes)
        return shared.isEmpty && trackedCodes.isEmpty ? group.subjectCodes : shared
    }
    private var sessions: [PlannedSession] {
        allPlanned.filter { $0.groupName == group.name && !$0.isPast }.sorted { $0.startsAt < $1.startsAt }
    }
    private var questions: [RemotePost] { posts.filter { $0.parentId == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if isOnline { GroupSessionCard(group: group) }
            liveCard
            ranking
            whoIsWhere
            helpSection
            sessionsSection
        }
        .task(id: group.remoteID) { await watch() }
        .sheet(isPresented: $composing) {
            HelpComposer(group: group, subjects: mySubjects) { post in
                posts.insert(post, at: 0)
            }
        }
        .sheet(item: $openedThread) { post in
            HelpThread(group: group, question: post, replies: posts.filter { $0.parentId == post.id }) { changed in
                Task { await reloadPosts() }
                _ = changed
            }
        }
        .sheet(isPresented: $showingPlan) { PlanSessionView(group: group) }
    }

    // MARK: En direct

    private var liveCard: some View {
        let live = liveEntries
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(live.isEmpty ? Carnet.inkTertiary : Carnet.correct)
                    .frame(width: 8, height: 8)
                CarnetKicker(live.isEmpty ? String(localized: "En direct") : PresenceBoard.summary(live),
                             color: live.isEmpty ? Carnet.inkSecondary : Carnet.correct)
            }
            if !isOnline {
                Text(group.remoteID == nil
                     ? "Groupe pas encore partagé."
                     : "Connecte-toi (Réglages › Compte et groupes) pour voir qui travaille.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            } else if let presenceError {
                Text(presenceError).font(.footnote).foregroundStyle(Carnet.wrong)
            } else if live.isEmpty {
                Text(app.presence.isSharing ? "Personne d'autre pour l'instant." : "Personne ne travaille en ce moment.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(live) { entry in
                    liveRow(entry)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carnetGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func liveRow(_ entry: PresenceEntry) -> some View {
        HStack(spacing: 12) {
            GroupAvatar(name: entry.isMe ? "Toi" : entry.displayName, highlighted: entry.isMe)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isMe ? "Toi" : entry.displayName).font(.body.weight(.medium)).foregroundStyle(Carnet.ink)
                Text("\(entry.activityLabel) · \(entry.elapsedLabel(at: now))")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !entry.isMe, !entry.courseCode.isEmpty {
                Button("Rejoindre") { join(entry) }
                    .buttonStyle(.carnetPrimary)
                    .controlSize(.small)
                    .accessibilityLabel("Travailler sur \(entry.courseCode) avec \(entry.displayName)")
            }
        }
    }

    /// Lance mon chrono sur le même travail que ce membre.
    private func join(_ entry: PresenceEntry) {
        let type = TaskType.allCases.first { $0.label == entry.taskLabel } ?? .exercise
        let course = myCourses.first { $0.code.uppercased() == entry.courseCode.uppercased() }
        app.router.startFocus(courseID: course?.id, courseCode: entry.courseCode, taskType: type,
                              label: String(localized: "\(entry.courseCode) · \(type.label) · avec \(entry.displayName)"))
        Haptics.success()
    }

    // MARK: Classement

    private var ranking: some View {
        let members = group.members.sorted {
            $0.weeklySeconds != $1.weeklySeconds ? $0.weeklySeconds > $1.weeklySeconds : $0.isMe
        }
        let peak = max(members.first?.weeklySeconds ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(String(localized: "Classement")) {
                NavigationLink("7 derniers jours", value: GroupPageRoute(groupID: group.id, page: .time))
            }
            CarnetSheet {
                if members.isEmpty {
                    CarnetRow(title: String(localized: "Aucun membre"))
                }
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(Carnet.serif(.title3))
                            .foregroundStyle(index == 0 && member.weeklySeconds > 0 ? Carnet.review : Carnet.inkSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(member.isMe ? "Toi" : member.shownName)
                                    .font(.body.weight(member.isMe ? .semibold : .regular))
                                    .foregroundStyle(Carnet.ink)
                                Spacer()
                                Text(member.weeklyLabel)
                                    .font(Carnet.mono(.footnote, weight: .medium))
                                    .foregroundStyle(Carnet.ink)
                            }
                            CarnetBar(value: Double(member.weeklySeconds) / Double(peak),
                                      tint: member.isMe ? Carnet.ink : Carnet.inkTertiary, height: 4)
                            if member.completedSeriesCount > 0 {
                                Text(Plural.count(member.completedSeriesCount, "\(member.completedSeriesCount) série terminée", "\(member.completedSeriesCount) séries terminées"))
                                    .font(.caption)
                                    .foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, Carnet.rowInset)
                    .padding(.vertical, 10)
                    .background(member.isMe ? Carnet.marker.opacity(0.5) : .clear)
                    .accessibilityElement(children: .combine)
                    if index < members.count - 1 { CarnetRule(inset: 48) }
                }
            }
        }
    }

    // MARK: Qui en est où

    @ViewBuilder
    private var whoIsWhere: some View {
        let boards = currentBoards
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle(String(localized: "Qui en est où")) {
                    NavigationLink("Toutes les séries", value: GroupPageRoute(groupID: group.id, page: .series))
                }
                ForEach(boards, id: \.code) { entry in
                    boardCard(code: entry.code, board: entry.board)
                }
            }
        }
    }

    /// Pour chaque matière partagée, la série de la semaine (sinon la dernière
    /// commencée).
    private var currentBoards: [(code: String, board: SeriesBoard)] {
        mySubjects.compactMap { code in
            let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
            let boards = GroupProgressBuilder.seriesBoards(subject: code, group: group, course: course, meID: app.social.userID)
            guard !boards.isEmpty else { return nil }
            let week = course?.currentWeek ?? 0
            let board = boards.first { $0.plannedWeek == week }
                ?? boards.last { $0.startedCount > 0 }
                ?? boards.first
            return board.map { (code, $0) }
        }
    }

    private func boardCard(code: String, board: SeriesBoard) -> some View {
        let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
        let tint = course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(code) · \(board.displayName)").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(board.summary).font(.footnote).foregroundStyle(Carnet.inkSecondary)
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 56, alignment: .leading)
                    ForEach(board.exerciseNumbers, id: \.self) { number in
                        Text(number.split(separator: ".").last.map(String.init) ?? number)
                            .font(.caption2)
                            .foregroundStyle(Carnet.inkTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(board.rows.prefix(8)) { row in
                    GridRow {
                        Text(row.isMe ? "Toi" : row.displayName)
                            .font(.caption.weight(row.isMe ? .semibold : .regular))
                            .foregroundStyle(Carnet.ink)
                            .lineLimit(1)
                            .frame(width: 56, alignment: .leading)
                        ForEach(board.exerciseNumbers, id: \.self) { number in
                            let done = row.declaredComplete || row.doneNumbers.contains(number)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(done ? tint : Carnet.rule)
                                .frame(height: 12)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(row.isMe ? "Toi" : row.displayName) : \(row.doneCount) exercices sur \(board.total)")
                }
            }
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    // MARK: Entraide

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(String(localized: "Entraide")) {
                if isOnline {
                    Button {
                        composing = true
                    } label: {
                        Label("Demander", systemImage: "plus.bubble")
                    }
                }
            }
            if isOnline, let encryption {
                encryptionNote(encryption)
            }
            CarnetSheet {
                if !isOnline {
                    CarnetRow(icon: "bubble.left.and.bubble.right", tint: Carnet.inkSecondary,
                              title: String(localized: "Entraide disponible une fois le groupe partagé"))
                } else if let postsError {
                    CarnetRow(icon: "exclamationmark.triangle", tint: Carnet.wrong, title: String(localized: "Entraide indisponible"),
                              subtitle: postsError)
                } else if questions.isEmpty {
                    Button { composing = true } label: {
                        CarnetRow(icon: "bubble.left.and.bubble.right", tint: Carnet.inkSecondary,
                                  title: String(localized: "Poser une question au groupe"))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(questions.prefix(8).enumerated()), id: \.element.id) { index, post in
                    Button { openedThread = post } label: {
                        questionRow(post)
                    }
                    .buttonStyle(.plain)
                    if index < min(questions.count, 8) - 1 { CarnetRule(inset: 56) }
                }
            }
        }
    }

    /// Une ligne discrète sous le titre : chiffré, ou en attente de la clé.
    @ViewBuilder
    private func encryptionNote(_ state: GroupEncryption.State) -> some View {
        switch state {
        case .ready:
            EmptyView()
        case .waitingForKey:
            // Seul cas qui demande quelque chose : écrire attend la clé.
            Label("En attente de la clé du groupe : elle arrive dès qu'un membre ouvre l'app.",
                  systemImage: "lock.badge.clock")
                .font(.caption)
                .foregroundStyle(Carnet.review.accessibleInk)
                .padding(.horizontal, 6)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            EmptyView()
        }
    }

    private func questionRow(_ post: RemotePost) -> some View {
        let replies = posts.filter { $0.parentId == post.id }.count
        let mine = post.authorId == app.social.userID
        return HStack(alignment: .top, spacing: 12) {
            GroupAvatar(name: mine ? "Toi" : post.authorName, highlighted: mine)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mine ? "Toi" : post.authorName).font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    if !post.target.isEmpty {
                        Text(post.target).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(DateUtils.relativeLabel(post.createdAt)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                }
                Text(post.body).font(.body).foregroundStyle(Carnet.ink).lineLimit(3)
                HStack(spacing: 10) {
                    Label(replies == 0 ? String(localized: "Répondre") : Plural.count(replies, "\(replies) réponse", "\(replies) réponses"),
                          systemImage: "arrowshape.turn.up.left")
                    if post.resolved {
                        Label("Résolu", systemImage: "checkmark.circle.fill").foregroundStyle(Carnet.correct)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Sessions") {
                Button {
                    showingPlan = true
                } label: {
                    Label("Planifier", systemImage: "calendar.badge.plus")
                }
            }
            CarnetSheet {
                if sessions.isEmpty {
                    CarnetRow(icon: "calendar", tint: Carnet.inkSecondary, title: String(localized: "Aucune session prévue"))
                }
                ForEach(Array(sessions.prefix(4).enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: GroupPageRoute(groupID: group.id, page: .planning)) {
                        CarnetRow(icon: "person.2.wave.2", tint: session.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary,
                                  title: session.title,
                                  subtitle: [DateUtils.relativeLabel(session.startsAt) + " " + DateUtils.time.string(from: session.startsAt),
                                             session.location.isEmpty ? nil : session.location]
                                    .compactMap { $0 }.joined(separator: " · ")) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if index < min(sessions.count, 4) - 1 { CarnetRule() }
                }
            }
        }
    }

    // MARK: Réseau

    /// Le direct et l'entraide, **en temps réel** tant que la page est ouverte.
    ///
    /// Ils étaient relus toutes les 30 s : un message ou un chrono lancé mettait
    /// jusque-là à apparaître. Realtime prévient maintenant à l'instant ; la
    /// relecture complète toutes les deux minutes ne sert plus que de filet
    /// (socket coupée sans qu'on le sache, événement perdu).
    private func watch() async {
        guard isOnline, let remoteID = group.remoteID else { return }
        encryption = await app.social.prepareEncryption(groupID: remoteID)
        await refreshPresence()
        await reloadPosts()

        let subscription = app.social.realtime?.subscribe(groupID: remoteID) { table in
            Task { @MainActor in await changed(table, groupID: remoteID) }
        }
        defer { if let subscription { app.social.realtime?.unsubscribe(subscription) } }

        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { break }
            now = Date()
            ticks += 1
            if ticks % 4 == 0 {
                await refreshPresence()
                await reloadPosts()
            }
        }
    }

    /// Un changement annoncé par le serveur : relire ce qu'il touche.
    private func changed(_ table: RealtimeClient.Table, groupID: String) async {
        switch table {
        case .posts:
            await reloadPosts()
        case .presence:
            await refreshPresence()
            now = Date()
        case .members:
            // Quelqu'un vient d'arriver : lui sceller la clé tout de suite,
            // pour qu'il lise l'entraide sans attendre.
            encryption = await app.social.prepareEncryption(groupID: groupID, forceDistribution: true)
        case .keyShares:
            // Une clé m'a peut-être été transmise : la prendre, et relire en clair.
            encryption = await app.social.prepareEncryption(groupID: groupID)
            await reloadPosts()
        case .sessions, .sessionMembers:
            // Sur leur propre canal (`GroupSessionService`).
            break
        }
    }

    private func refreshPresence() async {
        guard let remoteID = group.remoteID else { return }
        do {
            presence = try await app.social.fetchPresence(groupID: remoteID)
            presenceError = nil
        } catch {
            presenceError = GroupSync.explain(error)
        }
    }

    func reloadPosts() async {
        guard let remoteID = group.remoteID else { return }
        do {
            posts = try await app.social.fetchPosts(groupID: remoteID)
            postsError = nil
        } catch {
            postsError = GroupSync.explain(error)
        }
    }
}

/// Les initiales d'un membre, dans un rond.
struct GroupAvatar: View {
    let name: String
    var highlighted = false

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(highlighted ? Carnet.ground : Carnet.ink)
            .frame(width: 34, height: 34)
            .background(highlighted ? Carnet.ink : Carnet.sheetRaised, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Entraide : poser une question

/// « Je bloque sur 4.3 (b) » : la question porte le cours et l'exercice.
struct HelpComposer: View {
    let group: StudyGroup
    let subjects: [String]
    var onPosted: (RemotePost) -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var courseCode = ""
    @State private var exerciseID: UUID?
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    private var course: Course? { courses.first { $0.code.uppercased() == courseCode.uppercased() } }

    /// Les exercices proposés : ceux de la semaine d'abord, puis le reste.
    private var exercises: [Exercise] {
        guard let course else { return [] }
        let week = course.currentWeek
        return course.sortedSeries
            .sorted { lhs, rhs in
                let l = lhs.plannedWeek == week ? 0 : (lhs.plannedWeek < week ? 1 : 2)
                let r = rhs.plannedWeek == week ? 0 : (rhs.plannedWeek < week ? 1 : 2)
                return l != r ? l < r : lhs.seriesNumber > rhs.seriesNumber
            }
            .flatMap(\.sortedExercises)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sur quoi") {
                    Picker("Cours (au singulier)", selection: $courseCode) {
                        Text("Général").tag("")
                        ForEach(subjects, id: \.self) { Text($0).tag($0) }
                    }
                    if !exercises.isEmpty {
                        Picker("Exercice", selection: $exerciseID) {
                            Text("Aucun en particulier").tag(UUID?.none)
                            ForEach(exercises) { exercise in
                                Text("\(exercise.exerciseNumber) · \(MathMarkup.plain(exercise.title))").tag(UUID?.some(exercise.id))
                            }
                        }
                    }
                }
                Section {
                    TextField("Où bloques-tu ? Ce que tu as essayé…", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } footer: {
                    if let error { Text(error).foregroundStyle(Carnet.wrong) }
                }
            }
            .carnetBackground()
            .navigationTitle("Demander de l'aide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") { Task { await send() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if courseCode.isEmpty, let first = subjects.first { courseCode = first }
            }
        }
    }

    private func send() async {
        guard let remoteID = group.remoteID else { return }
        sending = true
        defer { sending = false }
        let exercise = exercises.first { $0.id == exerciseID }
        do {
            let post = try await app.social.createPost(groupID: remoteID,
                                                       authorName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
                                                       courseCode: courseCode,
                                                       seriesNumber: exercise?.series?.seriesNumber,
                                                       exerciseNumber: exercise?.exerciseNumber ?? "",
                                                       body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            onPosted(post)
            Haptics.success()
            dismiss()
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}

// MARK: - Entraide : un fil

struct HelpThread: View {
    let group: StudyGroup
    let question: RemotePost
    @State var replies: [RemotePost]
    var onChange: (Bool) -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var resolved: Bool
    @State private var error: String?

    init(group: StudyGroup, question: RemotePost, replies: [RemotePost], onChange: @escaping (Bool) -> Void) {
        self.group = group
        self.question = question
        _replies = State(initialValue: replies.sorted { $0.createdAt < $1.createdAt })
        self.onChange = onChange
        _resolved = State(initialValue: question.resolved)
    }

    private var isMine: Bool { question.authorId == app.social.userID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    message(question, isQuestion: true)
                    ForEach(replies) { reply in
                        message(reply, isQuestion: false)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Carnet.wrong)
                    }
                }
                .padding(16)
            }
            .background(Carnet.ground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("Répondre…", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Carnet.ground)
                            .frame(width: 40, height: 40)
                            .background(Carnet.ink, in: Circle())
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Envoyer la réponse")
                }
                .padding(10)
                .carnetGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .task { await watchReplies() }
            .navigationTitle(question.target.isEmpty ? String(localized: "Question") : question.target)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                if isMine {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(resolved ? "Rouvrir" : "Résolu") { Task { await toggleResolved() } }
                    }
                }
            }
        }
    }

    private func message(_ post: RemotePost, isQuestion: Bool) -> some View {
        let mine = post.authorId == app.social.userID
        return HStack(alignment: .top, spacing: 10) {
            GroupAvatar(name: mine ? "Toi" : post.authorName, highlighted: mine)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mine ? "Toi" : post.authorName).font(.subheadline.weight(.semibold))
                    Text(DateUtils.relativeLabel(post.createdAt)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                    if isQuestion, resolved {
                        Label("Résolu", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Carnet.correct)
                    }
                }
                Text(post.body)
                    .font(isQuestion ? Carnet.serif(.body) : .body)
                    .foregroundStyle(Carnet.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isQuestion ? Carnet.sheet : Carnet.sheet.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func send() async {
        guard let remoteID = group.remoteID else { return }
        sending = true
        defer { sending = false }
        do {
            let reply = try await app.social.createPost(groupID: remoteID,
                                                        authorName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
                                                        parentID: question.id,
                                                        courseCode: question.courseCode,
                                                        body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            replies.append(reply)
            text = ""
            error = nil
            onChange(true)
            Haptics.success()
        } catch {
            self.error = GroupSync.explain(error)
        }
    }

    /// Les réponses arrivent pendant qu'on lit le fil, sans le rouvrir.
    private func watchReplies() async {
        guard let remoteID = group.remoteID,
              let realtime = app.social.realtime else { return }
        let subscription = realtime.subscribe(groupID: remoteID) { table in
            guard table == .posts || table == .keyShares else { return }
            Task { @MainActor in
                guard let all = try? await app.social.fetchPosts(groupID: remoteID) else { return }
                withAnimation(Motion.snappy) {
                    replies = all.filter { $0.parentId == question.id }.sorted { $0.createdAt < $1.createdAt }
                    if let fresh = all.first(where: { $0.id == question.id }) { resolved = fresh.resolved }
                }
            }
        }
        defer { realtime.unsubscribe(subscription) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func toggleResolved() async {
        do {
            try await app.social.setPostResolved(postID: question.id, resolved: !resolved)
            resolved.toggle()
            onChange(true)
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}


/// « Session ensemble » : un chrono commun aux membres du groupe.
///
/// Lancer, rejoindre, et voir qui y est. Chacun garde son cours et son exercice
/// (choisis dans le chrono) ; la marche, les pauses et les blocs sont communs.
struct GroupSessionCard: View {
    let group: StudyGroup
    @Environment(AppContainer.self) private var app

    private var service: GroupSessionService { app.groupSessions }
    private var session: RemoteGroupSession? { group.remoteID.flatMap { service.live[$0] } }
    private var isMine: Bool {
        guard let link = app.focus.state?.groupSession else { return false }
        return link.groupID == group.remoteID && link.sessionID == session?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Session ensemble")
            CarnetSheet {
                VStack(alignment: .leading, spacing: 12) {
                    if let session {
                        HStack(spacing: 12) {
                            Image(systemName: session.clock.runningSince != nil ? "timer" : "pause.circle")
                                .font(.title3)
                                .foregroundStyle(Carnet.ink)
                            VStack(alignment: .leading, spacing: 2) {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(TimerText.clock(session.clock.elapsed(at: context.date)))
                                        .font(Carnet.mono(.title3, weight: .medium))
                                        .foregroundStyle(Carnet.ink)
                                }
                                Text(participants(session))
                                    .font(.footnote)
                                    .foregroundStyle(Carnet.inkSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if isMine {
                                Label("Tu y es", systemImage: "checkmark.circle.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Carnet.correct)
                            } else {
                                Button("Rejoindre") { Task { await service.join(session, group: group) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(service.isWorking)
                            }
                        }
                        if isMine {
                            HStack {
                                Button("Ouvrir le chrono") { app.router.openFocus() }
                                Spacer()
                                if session.host_id == app.social.userID {
                                    Button("Terminer pour tous", role: .destructive) {
                                        Task { await service.endForEveryone(groupID: session.group_id) }
                                    }
                                }
                            }
                            .font(.footnote.weight(.medium))
                        }
                    } else {
                        Text("Un chrono commun : les pauses et les blocs tombent au même moment pour tout le monde, chacun sur son propre travail.")
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                        Button {
                            Task { await service.start(group: group) }
                        } label: {
                            Label(app.focus.hasSession ? "Partager mon chrono avec le groupe" : "Lancer une session ensemble",
                                  systemImage: "person.2.wave.2")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.isWorking)
                    }
                    if let error = service.lastError {
                        Text(error).font(.caption).foregroundStyle(Carnet.wrong)
                    }
                }
                .padding(Carnet.rowInset)
            }
        }
        .task(id: group.remoteID) {
            guard let id = group.remoteID else { return }
            service.watch(groupID: id)
        }
        .onDisappear {
            if let id = group.remoteID { service.unwatch(groupID: id) }
        }
    }

    private func participants(_ session: RemoteGroupSession) -> String {
        let names = session.present.map { member in
            member.user_id == app.social.userID ? "toi" : (member.profiles?.display_name ?? String(localized: "un membre"))
        }
        return names.isEmpty ? String(localized: "personne pour l'instant") : names.joined(separator: ", ")
    }
}

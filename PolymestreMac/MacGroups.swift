import AppKit
import SwiftData
import SwiftUI

// Les groupes sur le Mac, comme sur l'iPhone : mes groupes, en créer un ou en rejoindre un ; dans
// un groupe, qui travaille en ce moment (et le rejoindre), la session ensemble (un chrono commun),
// le classement de la semaine, qui en est où série par série et par matière, l'entraide chiffrée,
// les sessions prévues, les membres, le code à partager, quitter. Les mêmes services que
// l'iPhone (`SocialService`, `GroupSync`, `GroupSessionService`, `PresenceService`).

/// Déconnecté : ce que les groupes donnent, et la connexion sur place, comme
/// sur l'iPhone et sur Windows. Renvoyer aux réglages faisait chercher un
/// formulaire sous un autre nom, puis revenir ici.
private struct MacGroupsSignIn: View {
    let social: SocialService
    var signedIn: () async -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Travailler ensemble").font(Carnet.serif(18)).foregroundStyle(Carnet.ink)
            Text("Qui travaille en ce moment, qui en est où série par série, l'entraide sur un exercice et les sessions ensemble — avec ton compte Polymestre, le même que sur l'iPhone.")
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Adresse e-mail", text: $email)
                    .textContentType(.username)
                SecureField("Mot de passe", text: $password)
                    .onSubmit { Task { await authenticate(signUp: false) } }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 520)
            HStack(spacing: 8) {
                Button("Se connecter") { Task { await authenticate(signUp: false) } }
                    .buttonStyle(.ink)
                    .disabled(working || email.isEmpty || password.count < 6)
                Button("Créer un compte") { Task { await authenticate(signUp: true) } }
                    .disabled(working || email.isEmpty || password.count < 6)
                Button {
                    Task {
                        working = true
                        if await social.signInWithGoogle() { await signedIn() }
                        working = false
                    }
                } label: {
                    Label("Continuer avec Google", systemImage: "g.circle.fill")
                }
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.paper)
            if let error = social.lastError, !working {
                Text(ui: error).font(.caption).foregroundStyle(Carnet.wrong)
            }
        }
        .macCard()
    }

    private func authenticate(signUp: Bool) async {
        working = true
        defer { working = false }
        let ok = signUp ? await social.signUp(email: email, password: password)
                        : await social.signIn(email: email, password: password)
        if ok {
            password = ""
            await signedIn()
        }
    }
}

/// Le compte Polymestre, la session de groupe et la présence, pour le Mac.
@MainActor
@Observable
final class MacGroups: GroupSessionHost {
    static let shared = MacGroups()

    let social = SocialService(urlString: SupabaseConfig.urlString, anonKey: SupabaseConfig.anonKey)
    let sessions = GroupSessionService()
    let presence = PresenceService()
    private(set) var syncMessage: String?
    private(set) var isSyncing = false

    @ObservationIgnored weak var timer: MacTimer?
    @ObservationIgnored weak var settings: MacSettings?
    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored private var announced: String?

    private init() {
        sessions.app = self
    }

    // MARK: GroupSessionHost

    var groupTimerEngine: TimerEngine { timer?.engine ?? TimerEngine() }
    var groupTimerLocked: Bool { timer?.isLocked ?? false }
    var groupPomodoroDefault: Bool { settings?.pomodoroDefault ?? false }
    var groupPomodoroCycle: PomodoroSettings { settings?.pomodoro ?? PomodoroSettings() }
    func groupFinishTimer() { _ = timer?.finish() }

    var displayName: String {
        let name = settings?.shared.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Moi" : name
    }

    /// Relit mes groupes (membres, classement, séries, sessions prévues).
    func refresh() async {
        guard let container, let shared = settings?.shared, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = await GroupSync.refresh(context: container.mainContext, social: social, settings: shared)
    }

    /// Le chrono a changé : la session de groupe suit, et les groupes voient que je travaille.
    func timerDidChange(_ change: TimerEngine.Change) {
        sessions.timerDidChange(change)
        guard social.isSignedIn, let container, let state = timer?.state else {
            if announced != nil, let container {
                announced = nil
                presence.stop(context: container.mainContext, social: social)
            }
            return
        }
        let context = container.mainContext
        let key = "\(state.isRunning)|\(state.courseID?.uuidString ?? "")|\(state.taskType.rawValue)|\(state.targetID?.uuidString ?? "")"
        guard key != announced else { return }
        announced = key
        guard state.isRunning else {
            presence.stop(context: context, social: social)
            return
        }
        let course = TimerEngine.course(state.courseID, in: context)
        let target = TimerEngine.target(of: state.targetID, in: course)
        presence.announce(PresenceEntry(userID: social.userID ?? "me", displayName: displayName,
                                        courseCode: course?.code ?? "", taskLabel: state.taskType.label,
                                        target: target.exercise?.displayNumber ?? target.theoryItem?.displayNumber ?? "",
                                        startedAt: state.runningSince ?? Date(), updatedAt: Date(), isMe: true),
                          context: context, social: social)
    }
}

// MARK: - La page

struct MacGroupsView: View {
    @Query(sort: \StudyGroup.name) private var groups: [StudyGroup]
    @State private var groupsService = MacGroups.shared
    @State private var selected: UUID?
    @State private var form: GroupFormKind?
    @Environment(\.openSettings) private var openSettings

    enum GroupFormKind: Identifiable { case create, join; var id: Int { self == .create ? 0 : 1 } }

    var body: some View {
        let social = groupsService.social
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Groupes").font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                    Spacer()
                    if groupsService.isSyncing { ProgressView().controlSize(.small) }
                    if social.isSignedIn {
                        Button { Task { await groupsService.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Actualiser")
                        Button("Rejoindre") { form = .join }
                        Button("Créer") { form = .create }.buttonStyle(.ink)
                    }
                }
                .buttonStyle(.paper)
                if !social.isSignedIn {
                    MacGroupsSignIn(social: social) { await groupsService.refresh() }
                } else if groups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pas encore de groupe").font(Carnet.serif(18)).foregroundStyle(Carnet.ink)
                        Text("Crée-en un et partage son code, ou rejoins celui d'un·e camarade.").foregroundStyle(Carnet.inkSecondary)
                    }
                    .macCard()
                }
                if let message = groupsService.syncMessage, social.isSignedIn, groups.isEmpty {
                    Text(message).font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                if let group = groups.first(where: { $0.id == selected }) ?? groups.first, social.isSignedIn {
                    if groups.count > 1 {
                        Picker("Groupe", selection: Binding(get: { group.id }, set: { selected = $0 })) {
                            ForEach(groups) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    MacGroupHub(group: group)
                        .id(group.id)
                }
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Groupes")
        .task { if social.isSignedIn { await groupsService.refresh() } }
        .sheet(item: $form) { kind in
            MacGroupForm(kind: kind) { form = nil }
        }
    }
}

// MARK: - Créer, rejoindre

private struct MacGroupForm: View {
    let kind: MacGroupsView.GroupFormKind
    var done: () -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var name = ""
    @State private var code = ""
    @State private var subjects: Set<String> = []
    @State private var working = false
    @State private var error: String?

    private var social: SocialService { MacGroups.shared.social }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .create ? "Nouveau groupe" : "Rejoindre un groupe").font(Carnet.serif(22)).foregroundStyle(Carnet.ink)
            if kind == .create {
                TextField("Nom du groupe", text: $name).textFieldStyle(.roundedBorder)
                Text("Matières").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                FlowChips(items: courses.filter(\.isTracked).map(\.code), selected: $subjects)
            } else {
                TextField("Code reçu (EPFL-7K2Q)", text: $code).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
            HStack {
                Spacer()
                Button("Annuler", action: done).keyboardShortcut(.cancelAction)
                Button(working ? "…" : (kind == .create ? "Créer" : "Rejoindre")) { Task { await submit() } }
                    .buttonStyle(.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (kind == .create ? name.trimmingCharacters(in: .whitespaces).isEmpty : code.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .buttonStyle(.paper)
        }
        .padding(24)
        .frame(width: 440)
        .background(Carnet.ground)
    }

    private func submit() async {
        working = true
        defer { working = false }
        let me = MacGroups.shared.displayName
        do {
            if kind == .create {
                let codes = StudyGroup.normalize(Array(subjects))
                let remote = try await social.createGroup(name: name, description: "", courseCode: "", courseCodes: codes, displayName: me)
                let group = StudyGroup(name: remote.name, details: "", courseCodes: codes)
                group.remoteID = remote.id
                group.inviteCode = remote.inviteCode
                group.isAdmin = true
                context.insert(group)
                context.insert(GroupMember(group: group, userID: social.userID ?? "me", displayName: me, isMe: true, role: .admin, courseCodes: codes))
            } else {
                let remote = try await social.joinGroup(inviteCode: StudyGroup.normalizeInviteCode(code), displayName: me)
                let group = StudyGroup(name: remote.name, details: remote.description ?? "", courseCode: remote.courseCode ?? "",
                                       courseCodes: remote.subjectCodes, isAdmin: false)
                group.remoteID = remote.id
                if !remote.inviteCode.isEmpty { group.inviteCode = remote.inviteCode }
                context.insert(group)
                context.insert(GroupMember(group: group, userID: social.userID ?? "me", displayName: me, isMe: true, role: .member, courseCodes: group.subjectCodes))
            }
            try? context.save()
            await MacGroups.shared.refresh()
            done()
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}

/// Des puces à cocher (les matières d'un groupe).
private struct FlowChips: View {
    let items: [String]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = selected.contains(item)
                Button {
                    if on { selected.remove(item) } else { selected.insert(item) }
                } label: {
                    Text(item).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(on ? Carnet.ink : Carnet.sheet, in: Capsule())
                        .foregroundStyle(on ? Carnet.ground : Carnet.ink)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Un groupe

private struct MacGroupHub: View {
    @Bindable var group: StudyGroup
    @Environment(\.modelContext) private var context
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var myCourses: [Course]
    @Query(sort: \PlannedSession.startsAt) private var allPlanned: [PlannedSession]
    @State private var groupsService = MacGroups.shared
    @State private var presence: [PresenceEntry] = []
    @State private var posts: [RemotePost] = []
    @State private var postsError: String?
    @State private var encryption: GroupEncryption.State?
    @State private var now = Date()
    @State private var composing = false
    @State private var thread: RemotePost?
    @State private var planning = false
    @State private var copied = false

    private var social: SocialService { groupsService.social }
    private var trackedCodes: Set<String> { Set(myCourses.filter(\.isTracked).map { $0.code.uppercased() }) }
    private var mySubjects: [String] {
        let shared = group.mySubjectCodes(myTrackedCourses: trackedCodes)
        return shared.isEmpty && trackedCodes.isEmpty ? group.subjectCodes : shared
    }
    private var questions: [RemotePost] { posts.filter { $0.parentId == nil } }
    private var planned: [PlannedSession] {
        allPlanned.filter { $0.groupName == group.name && !$0.isPast }.sorted { $0.startsAt < $1.startsAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 22) {
                    live
                    sessionTogether
                    ranking
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 22) {
                    help
                    sessionsPlanned
                    membersList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            progress
        }
        .task(id: group.remoteID) { await watch() }
        .sheet(isPresented: $composing) {
            MacHelpComposer(group: group, subjects: mySubjects) { post in posts.insert(post, at: 0); composing = false }
        }
        .sheet(item: $thread) { question in
            MacHelpThread(group: group, question: question, replies: posts.filter { $0.parentId == question.id }) {
                thread = nil
                Task { await reloadPosts() }
            }
        }
        .sheet(isPresented: $planning) { MacPlanSession(group: group) { planning = false } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(Carnet.serif(24)).foregroundStyle(Carnet.ink)
                Text(group.subjectCodes.joined(separator: " · ").isEmpty ? String(localized: "Toutes matières") : group.subjectCodes.joined(separator: " · "))
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer()
            Button(copied ? "Copié" : "Code \(group.inviteCode)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(group.inviteMessage, forType: .string)
                copied = true
            }
            .help("Copier l'invitation")
            Menu {
                Button("Quitter le groupe", role: .destructive) { Task { await leave() } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.paper)
    }

    // MARK: En direct

    private var live: some View {
        let entries = PresenceBoard.live(presence, at: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(entries.isEmpty ? Carnet.inkTertiary : Carnet.correct).frame(width: 8, height: 8)
                Kicker(entries.isEmpty ? String(localized: "En direct") : PresenceBoard.summary(entries), color: entries.isEmpty ? Carnet.inkSecondary : Carnet.correct)
            }
            if entries.isEmpty {
                Text("Personne ne travaille en ce moment.").foregroundStyle(Carnet.inkSecondary)
            }
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Avatar(name: entry.isMe ? "Toi" : entry.displayName, highlighted: entry.isMe)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.isMe ? "Toi" : entry.displayName).fontWeight(.medium)
                        Text("\(entry.activityLabel) · \(entry.elapsedLabel(at: now))").font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                    Spacer()
                    if !entry.isMe, !entry.courseCode.isEmpty {
                        Button("Rejoindre") { join(entry) }.buttonStyle(.paper)
                            .help("Lancer ton chrono sur le même travail")
                    }
                }
            }
        }
        .macCard()
    }

    private func join(_ entry: PresenceEntry) {
        let type = TaskType.allCases.first { $0.label == entry.taskLabel } ?? .exercise
        let course = myCourses.first { $0.code.uppercased() == entry.courseCode.uppercased() }
        timer.start(courseID: course?.id, taskType: type, label: String(localized: "\(entry.courseCode) · \(type.label) · avec \(entry.displayName)"))
    }

    // MARK: Session ensemble

    @ViewBuilder
    private var sessionTogether: some View {
        let sessions = groupsService.sessions
        let session = group.remoteID.flatMap { sessions.live[$0] }.flatMap { $0?.isLive == true ? $0 : nil }
        let linked = timer.state?.groupSession?.groupID == group.remoteID && group.remoteID != nil
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Session ensemble")
            Text("Un chrono commun : les pauses tombent au même moment pour tout le monde, chacun sur son travail.")
                .font(.caption).foregroundStyle(Carnet.inkSecondary)
            if let session {
                let names = session.present.map { $0.user_id == social.userID ? String(localized: "toi") : ($0.profiles?.display_name ?? String(localized: "un membre")) }
                Text(names.isEmpty ? String(localized: "En cours") : names.joined(separator: ", ")).fontWeight(.medium)
                HStack {
                    if linked {
                        Label("Ton chrono suit le groupe", systemImage: "link").foregroundStyle(Carnet.correct)
                    } else {
                        Button("Rejoindre la session") { Task { await sessions.join(session, group: group) } }.buttonStyle(.ink)
                    }
                    if session.host_id == social.userID {
                        Button("Terminer pour tous") { Task { if let id = group.remoteID { await sessions.endForEveryone(groupID: id) } } }
                    }
                }
                .buttonStyle(.paper)
            } else {
                Button(timer.engine.hasSession ? "Partager mon chrono avec le groupe" : "Lancer une session ensemble") {
                    Task { await sessions.start(group: group) }
                }
                .buttonStyle(.ink)
                .disabled(group.remoteID == nil || sessions.isWorking)
            }
            if let error = sessions.lastError { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
        }
        .macCard()
    }

    // MARK: Classement

    private var ranking: some View {
        let members = group.members.sorted { $0.weeklySeconds != $1.weeklySeconds ? $0.weeklySeconds > $1.weeklySeconds : $0.isMe }
        let peak = max(members.first?.weeklySeconds ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Classement"), trailing: String(localized: "7 derniers jours"))
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(Carnet.serif(.title3))
                            .foregroundStyle(index == 0 && member.weeklySeconds > 0 ? Carnet.review : Carnet.inkSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(member.isMe ? "Toi" : member.shownName).fontWeight(member.isMe ? .semibold : .regular)
                                Spacer()
                                Text(member.weeklyLabel).font(.callout.monospacedDigit())
                            }
                            GeometryReader { proxy in
                                Capsule().fill(Carnet.rule)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(member.isMe ? Carnet.ink : Carnet.inkTertiary)
                                            .frame(width: proxy.size.width * Double(member.weeklySeconds) / Double(peak))
                                    }
                            }
                            .frame(height: 4)
                            if member.completedSeriesCount > 0 {
                                Text("\(member.completedSeriesCount) séries terminées").font(.caption).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    if index < members.count - 1 { PaperRule(inset: 34) }
                }
            }
            .macCard(padding: 12)
        }
    }

    // MARK: Avancement

    @ViewBuilder
    private var progress: some View {
        let subjects = mySubjects
        if !subjects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: String(localized: "Qui en est où"))
                ForEach(subjects, id: \.self) { code in
                    let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
                    let comparison = GroupProgressBuilder.comparison(subject: code, group: group, course: course, meID: social.userID)
                    let boards = GroupProgressBuilder.seriesBoards(subject: code, group: group, course: course, meID: social.userID)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(code).font(.headline).foregroundStyle(course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink)
                            Spacer()
                            if let me = comparison.me {
                                Text("Toi : \(me.seriesDone) séries · \(me.exercisesDone) exercices · \(me.theoryDone) théorie")
                                    .font(.caption).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                        ForEach(comparison.rows.filter { !$0.isMe }.prefix(6)) { row in
                            HStack {
                                Text(row.displayName).font(.callout)
                                Spacer()
                                Text(row.gapExercises == 0 ? String(localized: "au même point") : row.gapExercises > 0 ? "+\(row.gapExercises) ex." : "\(row.gapExercises) ex.")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(row.gapExercises > 0 ? Carnet.review : Carnet.inkSecondary)
                            }
                        }
                        if !boards.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(boards) { board in seriesBoard(board, tint: course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink) }
                                }
                            }
                        }
                    }
                    .macCard()
                }
            }
        }
    }

    private func seriesBoard(_ board: SeriesBoard, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(board.displayName).font(.caption.weight(.semibold))
            Text(board.summary).font(.caption2).foregroundStyle(Carnet.inkSecondary)
            Grid(horizontalSpacing: 3, verticalSpacing: 4) {
                ForEach(board.rows.prefix(8)) { row in
                    GridRow {
                        Text(row.isMe ? "Toi" : row.displayName).font(.caption2).lineLimit(1).frame(width: 54, alignment: .leading)
                        ForEach(board.exerciseNumbers, id: \.self) { number in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(row.declaredComplete || row.doneNumbers.contains(number) ? tint : Carnet.rule)
                                .frame(width: 10, height: 10)
                                .help(number)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Carnet.ground, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Entraide

    private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: String(localized: "Entraide"))
                Button { composing = true } label: { Label("Demander", systemImage: "plus.bubble") }
                    .buttonStyle(.paper)
                    .disabled(group.remoteID == nil || encryption == .waitingForKey)
            }
            if encryption == .waitingForKey {
                Label("En attente de la clé du groupe : elle arrive dès qu'un membre ouvre l'app.", systemImage: "lock.badge.clock")
                    .font(.caption).foregroundStyle(Carnet.review)
            }
            VStack(spacing: 0) {
                if let postsError {
                    Text(postsError).font(.caption).foregroundStyle(Carnet.wrong).padding(8)
                } else if questions.isEmpty {
                    Text("Pas encore de question.").foregroundStyle(Carnet.inkSecondary).padding(8)
                }
                ForEach(Array(questions.prefix(8).enumerated()), id: \.element.id) { index, post in
                    Button { thread = post } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(name: post.authorId == social.userID ? "Toi" : post.authorName, highlighted: post.authorId == social.userID)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(post.authorId == social.userID ? "Toi" : post.authorName).fontWeight(.semibold)
                                    if !post.target.isEmpty { Text(post.target).font(.caption).foregroundStyle(Carnet.inkSecondary) }
                                    Spacer()
                                    if post.resolved { Image(systemName: "checkmark.circle.fill").foregroundStyle(Carnet.correct) }
                                    Text(DateUtils.relativeLabel(post.createdAt)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                                }
                                Text(post.body).lineLimit(2).foregroundStyle(Carnet.ink)
                                let count = posts.filter { $0.parentId == post.id }.count
                                Text(count == 0 ? String(localized: "Répondre") : "\(count) réponses").font(.caption).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverRow()
                    if index < min(questions.count, 8) - 1 { PaperRule(inset: 44) }
                }
            }
            .macCard(padding: 6)
        }
    }

    // MARK: Sessions prévues

    private var sessionsPlanned: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Sessions")
                Button { planning = true } label: { Label("Planifier", systemImage: "calendar.badge.plus") }.buttonStyle(.paper)
            }
            VStack(alignment: .leading, spacing: 8) {
                if planned.isEmpty { Text("Aucune session prévue.").foregroundStyle(Carnet.inkSecondary) }
                ForEach(planned.prefix(5)) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).fontWeight(.medium)
                        Text([DateUtils.relativeLabel(session.startsAt) + " " + DateUtils.time.string(from: session.startsAt),
                              session.location.isEmpty ? nil : session.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .macCard()
        }
    }

    private var membersList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Membres"), trailing: "\(group.members.count)")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.members.sorted { $0.displayName < $1.displayName }) { member in
                    HStack {
                        Avatar(name: member.isMe ? "Toi" : member.shownName, highlighted: member.isMe)
                        Text(member.isMe ? "Toi" : member.shownName)
                        Spacer()
                        if member.role == .admin { Text("admin").font(.caption).foregroundStyle(Carnet.inkSecondary) }
                    }
                }
            }
            .macCard()
        }
    }

    // MARK: Réseau

    private func watch() async {
        guard social.isSignedIn, let remoteID = group.remoteID else { return }
        groupsService.sessions.watch(groupID: remoteID)
        defer { groupsService.sessions.unwatch(groupID: remoteID) }
        encryption = await social.prepareEncryption(groupID: remoteID)
        await refreshPresence()
        await reloadPosts()
        let subscription = social.realtime?.subscribe(groupID: remoteID) { table in
            Task { @MainActor in
                switch table {
                case .posts: await reloadPosts()
                case .presence: await refreshPresence()
                case .members: encryption = await social.prepareEncryption(groupID: remoteID, forceDistribution: true)
                case .keyShares:
                    encryption = await social.prepareEncryption(groupID: remoteID)
                    await reloadPosts()
                case .sessions, .sessionMembers: break
                }
            }
        }
        defer { if let subscription { social.realtime?.unsubscribe(subscription) } }
        // Le temps réel prévient ; une relecture toutes les deux minutes sert de filet.
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            now = Date()
            ticks += 1
            if ticks % 4 == 0 { await refreshPresence(); await reloadPosts() }
        }
    }

    private func refreshPresence() async {
        guard let id = group.remoteID else { return }
        presence = (try? await social.fetchPresence(groupID: id)) ?? presence
    }

    private func reloadPosts() async {
        guard let id = group.remoteID else { return }
        do { posts = try await social.fetchPosts(groupID: id); postsError = nil } catch { postsError = GroupSync.explain(error) }
    }

    private func leave() async {
        if let id = group.remoteID { try? await social.leaveGroup(groupID: id) }
        context.delete(group)
        try? context.save()
    }
}

private struct Avatar: View {
    let name: String
    var highlighted = false
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.caption.weight(.semibold))
            .frame(width: 24, height: 24)
            .background(highlighted ? Carnet.ink : Carnet.rule, in: Circle())
            .foregroundStyle(highlighted ? Carnet.ground : Carnet.ink)
    }
}

// MARK: - Entraide : écrire, lire

private struct MacHelpComposer: View {
    let group: StudyGroup
    let subjects: [String]
    var sent: (RemotePost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var series = ""
    @State private var exercise = ""
    @State private var text = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Demander au groupe").font(Carnet.serif(22))
            HStack {
                Picker("Matière", selection: $subject) {
                    Text("—").tag("")
                    ForEach(subjects, id: \.self) { Text($0).tag($0) }
                }
                TextField("Série", text: $series).frame(width: 60)
                TextField("Exercice", text: $exercise).frame(width: 80)
            }
            .textFieldStyle(.roundedBorder)
            TextEditor(text: $text).frame(height: 120).font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Carnet.rule))
            Label("Chiffré : seuls les membres du groupe peuvent lire.", systemImage: "lock").font(.caption).foregroundStyle(Carnet.inkSecondary)
            if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "…" : "Envoyer") { Task { await send() } }
                    .buttonStyle(.ink).keyboardShortcut(.defaultAction)
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.paper)
        }
        .padding(24).frame(width: 480).background(Carnet.ground)
        .onAppear { subject = subjects.first ?? "" }
    }

    private func send() async {
        guard let id = group.remoteID else { return }
        working = true
        defer { working = false }
        do {
            let post = try await MacGroups.shared.social.createPost(groupID: id, authorName: MacGroups.shared.displayName,
                                                                     courseCode: subject, seriesNumber: Int(series),
                                                                     exerciseNumber: exercise, body: text)
            sent(post)
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}

private struct MacHelpThread: View {
    let group: StudyGroup
    let question: RemotePost
    @State var replies: [RemotePost]
    var close: () -> Void
    @State private var text = ""
    @State private var resolved = false
    @State private var error: String?

    private var social: SocialService { MacGroups.shared.social }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(question.target.isEmpty ? String(localized: "Question") : question.target).font(Carnet.serif(20))
                Spacer()
                if question.authorId == social.userID {
                    Button(resolved ? "Rouvrir" : "Résolu") { Task { await toggle() } }.buttonStyle(.paper)
                }
                Button("Fermer", action: close).buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    message(question)
                    ForEach(replies) { message($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                TextField("Répondre…", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit { Task { await reply() } }
                Button("Envoyer") { Task { await reply() } }.buttonStyle(.ink)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
        }
        .padding(24).frame(width: 520).background(Carnet.ground)
        .onAppear { resolved = question.resolved }
    }

    private func message(_ post: RemotePost) -> some View {
        let mine = post.authorId == social.userID
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(mine ? String(localized: "Toi") : post.authorName) · \(DateUtils.relativeLabel(post.createdAt))").font(.caption).foregroundStyle(Carnet.inkSecondary)
            Text(post.body).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mine ? Carnet.marker.opacity(0.5) : Carnet.sheet, in: RoundedRectangle(cornerRadius: 8))
    }

    private func reply() async {
        guard let id = group.remoteID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let post = try await social.createPost(groupID: id, authorName: MacGroups.shared.displayName, parentID: question.id, body: text)
            replies.append(post)
            text = ""
        } catch {
            self.error = GroupSync.explain(error)
        }
    }

    private func toggle() async {
        do { try await social.setPostResolved(postID: question.id, resolved: !resolved); resolved.toggle() } catch { self.error = GroupSync.explain(error) }
    }
}

// MARK: - Planifier

private struct MacPlanSession: View {
    let group: StudyGroup
    var done: () -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var title = ""
    @State private var courseID: UUID?
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var minutes = 90
    @State private var location = ""

    var body: some View {
        Form {
            TextField("Titre", text: $title, prompt: Text("Session d'étude"))
            Picker("Cours (au singulier)", selection: $courseID) {
                Text("Aucun").tag(UUID?.none)
                ForEach(courses.filter(\.isTracked)) { Text($0.code).tag(Optional($0.id)) }
            }
            DatePicker("Quand", selection: $startsAt)
            Stepper("Durée : \(minutes) min", value: $minutes, in: 15...480, step: 15)
            TextField("Lieu", text: $location)
            HStack {
                Spacer()
                Button("Annuler", action: done).keyboardShortcut(.cancelAction)
                Button("Planifier") { Task { await save() } }.buttonStyle(.ink).keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.paper)
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private func save() async {
        let course = courses.first { $0.id == courseID }
        let name = title.isEmpty ? String(localized: "Session d'étude") : title
        let session = PlannedSession(course: course, groupRemoteID: group.remoteID, groupName: group.name, title: name,
                                     startsAt: startsAt, durationMinutes: minutes, location: location,
                                     createdByUserID: "me", goingCount: 1)
        context.insert(session)
        try? context.save()
        if let id = group.remoteID {
            _ = try? await MacGroups.shared.social.createPlannedSession(groupID: id, courseCode: course?.code ?? "", title: name,
                                                                         startsAt: startsAt, durationMinutes: minutes, location: location)
        }
        done()
    }
}

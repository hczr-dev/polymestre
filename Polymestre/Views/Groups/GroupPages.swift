import SwiftUI
import SwiftData

/// Une sous-page de la fiche de groupe, adressable par valeur (navigation et
/// capture d'écran en Debug).
struct GroupPageRoute: Hashable {
    enum Page: String, CaseIterable {
        case members, time, series, planning

        var title: String {
            switch self {
            case .members: return String(localized: "Membres")
            case .time: return String(localized: "Temps d'étude")
            case .series: return String(localized: "Avancement des séries")
            case .planning: return String(localized: "Sessions planifiées")
            }
        }

        var icon: String {
            switch self {
            case .members: return "person.3.fill"
            case .time: return "clock.fill"
            case .series: return "checkmark.seal.fill"
            case .planning: return "calendar"
            }
        }
    }

    let groupID: UUID
    let page: Page
}

// MARK: - Membres

/// Les membres, leur rôle, leurs matières, et les actions d'administration.
struct GroupMembersView: View {
    let group: StudyGroup

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var memberError: String?
    @State private var memberToRemove: GroupMember?
    @State private var showingInvite = false

    private var me: GroupMember? { group.members.first(where: \.isMe) }
    private var iAmAdmin: Bool { me?.isAdmin ?? group.isAdmin }

    private var sorted: [GroupMember] {
        group.members.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return lhs.isMe }
            if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(sorted) { member in
                    row(member)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if iAmAdmin, !member.isMe {
                                Button(role: .destructive) {
                                    memberToRemove = member
                                } label: {
                                    Label("Retirer", systemImage: "person.badge.minus")
                                }
                                Button {
                                    setRole(member, to: member.isAdmin ? .member : .admin)
                                } label: {
                                    Label(member.isAdmin ? "Rétrograder" : "Nommer admin",
                                          systemImage: member.isAdmin ? "crown" : "crown.fill")
                                }
                                .tint(.orange)
                            }
                        }
                }
            } header: {
                Text("\(Plural.count(group.members.count, "\(group.members.count) membre", "\(group.members.count) membres")) · \(group.members.filter(\.isAdmin).count) admin")
            } footer: {
                if iAmAdmin {
                    Text("Glisse une ligne vers la gauche pour gérer un membre.")
                }
            }

            if let memberError {
                Section {
                    Label(memberError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange.accessibleInk)
                }
            }

            Section {
                Button {
                    showingInvite = true
                } label: {
                    Label("Inviter quelqu'un", systemImage: "person.badge.plus")
                }
            }
        }
        .adaptiveListColumn()
        .carnetBackground()
        .navigationTitle("Membres")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingInvite) { GroupInviteView(group: group) }
        .confirmationDialog("Retirer \(memberToRemove?.displayName ?? "") du groupe ?",
                            isPresented: Binding(get: { memberToRemove != nil },
                                                 set: { if !$0 { memberToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Retirer", role: .destructive) {
                if let member = memberToRemove { remove(member) }
                memberToRemove = nil
            }
            Button("Annuler", role: .cancel) { memberToRemove = nil }
        }
    }

    private func row(_ member: GroupMember) -> some View {
        HStack(spacing: Layout.block) {
            ZStack {
                Circle()
                    .fill((member.isMe ? Theme.accent : Color.teal).badgeFill)
                    .frame(width: 40, height: 40)
                Text(member.initials.isEmpty ? "?" : member.initials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle((member.isMe ? Theme.accent : Color.teal).badgeInk)
            }
            VStack(alignment: .leading, spacing: Layout.micro) {
                HStack(spacing: Layout.snug) {
                    Text(member.isMe ? "Toi" : member.shownName)
                        .font(.subheadline.weight(.semibold))
                    if member.isAdmin {
                        Pill(text: String(localized: "Admin"), color: .orange, icon: "crown.fill")
                    }
                }
                Text(subjectsLabel(member))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(member.weeklyLabel) cette semaine · \(member.totalLabel) au total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Layout.inline)
        }
        .padding(.vertical, Layout.micro)
        .accessibilityElement(children: .combine)
    }

    private func subjectsLabel(_ member: GroupMember) -> String {
        let all = group.subjectCodes
        guard !all.isEmpty else { return String(localized: "Toutes les matières") }
        let mine = member.courseCodes.isEmpty ? all : all.filter { member.follows($0) }
        if mine.count == all.count { return String(localized: "Toutes les matières du groupe") }
        if mine.isEmpty { return String(localized: "Aucune matière du groupe") }
        return mine.joined(separator: " · ")
    }

    private func setRole(_ member: GroupMember, to role: GroupRole) {
        guard let remoteID = group.remoteID, app.social.isSignedIn else {
            member.role = role
            try? context.save()
            Haptics.tap()
            return
        }
        Task {
            do {
                try await app.social.setMemberRole(groupID: remoteID, userID: member.userID, role: role.rawValue)
                member.role = role
                try? context.save()
                memberError = nil
                Haptics.success()
            } catch {
                memberError = String(localized: "Changement de rôle impossible — \(GroupSync.explain(error))")
            }
        }
    }

    private func remove(_ member: GroupMember) {
        guard let remoteID = group.remoteID, app.social.isSignedIn else {
            context.delete(member)
            try? context.save()
            return
        }
        Task {
            do {
                try await app.social.removeMember(groupID: remoteID, userID: member.userID)
                context.delete(member)
                try? context.save()
                memberError = nil
                Haptics.removed()
            } catch {
                memberError = String(localized: "Retrait impossible — \(GroupSync.explain(error))")
            }
        }
    }
}

// MARK: - Temps d'étude

/// Le temps d'étude de chacun, semaine et total.
///
/// Ce n'est **pas** un classement : pas de rang, pas de place, pas de podium.
/// Travailler ensemble, c'est savoir qui avance, pas qui gagne — la
/// gamification a été retirée de l'app. Toi d'abord, puis les autres par nom.
struct GroupStudyTimeView: View {
    let group: StudyGroup

    @State private var scope: Scope = .week

    enum Scope: String, CaseIterable, Identifiable {
        case week, total
        var id: String { rawValue }
        var label: String { self == .week ? String(localized: "7 derniers jours") : String(localized: "Depuis le début") }
    }

    private var members: [GroupMember] {
        group.members.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return lhs.isMe }
            return lhs.shownName.localizedStandardCompare(rhs.shownName) == .orderedAscending
        }
    }

    private func seconds(_ member: GroupMember) -> Int {
        scope == .week ? member.weeklySeconds : member.totalSeconds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Picker("Période", selection: $scope) {
                    ForEach(Scope.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                summary
                membersCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Temps d'étude")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: some View {
        let total = members.reduce(0) { $0 + seconds($1) }
        let average = members.isEmpty ? 0 : total / members.count
        return HStack(spacing: Layout.block) {
            StatCard(icon: "clock.fill",
                     value: DateUtils.hoursLabel(seconds: total),
                     title: String(localized: "groupe entier"))
            StatCard(icon: "person.fill",
                     value: DateUtils.hoursLabel(seconds: average),
                     title: String(localized: "par membre"))
        }
    }

    private var membersCard: some View {
        let top = max(members.map(seconds).max() ?? 1, 1)
        return Card(title: String(localized: "Membres"), icon: "person.3.fill") {
            VStack(alignment: .leading, spacing: Layout.block) {
                if members.isEmpty {
                    Text("Aucun membre.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(members) { member in
                    HStack(spacing: Layout.control) {
                        VStack(alignment: .leading, spacing: Layout.tight) {
                            HStack(spacing: Layout.snug) {
                                Text(member.isMe ? "Toi" : member.shownName)
                                    .font(.subheadline.weight(member.isMe ? .bold : .regular))
                                    .lineLimit(1)
                                if member.completedSeriesCount > 0 {
                                    Pill(text: Plural.count(member.completedSeriesCount, "\(member.completedSeriesCount) série", "\(member.completedSeriesCount) séries"),
                                         color: .green)
                                }
                            }
                            ProgressBar(progress: Double(seconds(member)) / Double(top),
                                        color: member.isMe ? Theme.accent : .teal,
                                        height: 6)
                        }
                        Text(DateUtils.hoursLabel(seconds: seconds(member)))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(member.isMe ? "Toi" : member.shownName), \(DateUtils.hoursLabel(seconds: seconds(member)))")
                }
                if group.members.contains(where: \.isAnonymous) {
                    Text("Certains membres apparaissent anonymement.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Sessions planifiées

/// Les sessions du groupe, à venir puis passées, avec le RSVP.
struct GroupPlanningView: View {
    let group: StudyGroup

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \PlannedSession.startsAt) private var allPlanned: [PlannedSession]

    @State private var showingPlan = false
    @State private var sessionToDelete: PlannedSession?

    private var mine: [PlannedSession] {
        allPlanned.filter { $0.groupName == group.name || ($0.groupRemoteID != nil && $0.groupRemoteID == group.remoteID) }
    }
    private var upcoming: [PlannedSession] { mine.filter { !$0.isPast } }
    private var past: [PlannedSession] { mine.filter(\.isPast).reversed() }

    var body: some View {
        List {
            if upcoming.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Rien de planifié", systemImage: "calendar.badge.plus")
                    } actions: {
                        Button("Planifier une session") { showingPlan = true }
                            .buttonStyle(.carnetPrimary)
                    }
                }
            } else {
                Section("À venir") {
                    ForEach(upcoming) { session in
                        sessionRow(session)
                            .swipeActions(edge: .trailing) {
                                if session.createdByUserID == "me" || session.createdByUserID == app.social.userID {
                                    Button(role: .destructive) {
                                        sessionToDelete = session
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
            if !past.isEmpty {
                Section("Passées") {
                    ForEach(past.prefix(10)) { session in
                        HStack(spacing: Layout.control) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.subheadline)
                                Text("\(DateUtils.shortDay.string(from: session.startsAt)) · \(session.durationLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .adaptiveListColumn()
        .carnetBackground()
        .navigationTitle("Sessions planifiées")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPlan = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Planifier une session")
            }
        }
        .sheet(isPresented: $showingPlan) { PlanSessionView(group: group) }
        .confirmationDialog("Supprimer cette session ?",
                            isPresented: Binding(get: { sessionToDelete != nil },
                                                 set: { if !$0 { sessionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let session = sessionToDelete {
                    PlannedSessionActions.delete(session, context: context, app: app)
                }
                sessionToDelete = nil
            }
            Button("Annuler", role: .cancel) { sessionToDelete = nil }
        }
    }

    private func sessionRow(_ session: PlannedSession) -> some View {
        VStack(alignment: .leading, spacing: Layout.inline) {
            HStack(spacing: Layout.control) {
                Image(systemName: "timer")
                    .foregroundStyle(Color.indigo.accessibleMark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.subheadline.weight(.semibold))
                    Text("\(DateUtils.relativeLabel(session.startsAt)) · \(DateUtils.time.string(from: session.startsAt)) · \(session.durationLabel)\(session.location.isEmpty ? "" : " · \(session.location)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let course = session.course {
                        Text(course.displayCode)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Carnet.tint(course.colorHex).accessibleInk)
                    }
                }
                Spacer()
            }
            HStack(spacing: Layout.inline) {
                ForEach(RSVPStatus.allCases) { status in
                    Button {
                        session.rsvp = status
                        try? context.save()
                        Haptics.soft()
                    } label: {
                        HStack(spacing: Layout.tight) {
                            Image(systemName: status.icon)
                            Text(status.label).font(.caption2)
                        }
                        .padding(.horizontal, Layout.inline)
                        .padding(.vertical, 5)
                        .background(session.rsvp == status ? Theme.accent.badgeFill : Color.secondary.badgeFill,
                                    in: Capsule())
                        .foregroundStyle(session.rsvp == status ? Theme.accent.badgeInk : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(status.label) pour \(session.title)")
                    .accessibilityAddTraits(session.rsvp == status ? [.isSelected] : [])
                }
                Spacer()
                if session.goingCount > 0 || session.maybeCount > 0 {
                    Text("\(session.goingCount) présents · \(session.maybeCount) peut-être")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Layout.tight)
    }
}

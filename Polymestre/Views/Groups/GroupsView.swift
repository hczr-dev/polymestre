import SwiftUI
import SwiftData

/// Destination « avancement d'une matière », adressable par valeur.
///
/// Une valeur plutôt qu'une destination en ligne : c'est ce qui permet d'y arriver
/// depuis la fiche du groupe **et** de l'ouvrir directement au lancement en Debug,
/// pour la capture d'écran.
struct GroupSubjectRoute: Hashable {
    let groupID: UUID
    let subject: String
}

/// Onglet Groupes : mes groupes, leur avancement, la présence et le planning partagé.
struct GroupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \StudyGroup.name) private var groups: [StudyGroup]

    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var joinCode = ""
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var path = NavigationPath()
    /// Qui travaille en ce moment, par groupe — lu toutes les minutes tant que
    /// la liste est affichée.
    @State private var live: [UUID: [PresenceEntry]] = [:]

    /// Le groupe affiché, retenu d'une ouverture à l'autre.
    @AppStorage("groups.selected") private var selectedRaw = ""
    @State private var showingSubjects = false
    @State private var showingInvite = false

    private var selected: StudyGroup? {
        groups.first { $0.id.uuidString == selectedRaw } ?? groups.first
    }

    /// Captures (Debug) : `-seedSampleData -group 0` montre les groupes d'exemple sans compte.
    private var previewingGroups: Bool {
        #if DEBUG
        PreviewLaunch.isSet(PreviewLaunch.seedFlag) && PreviewLaunch.int(PreviewLaunch.groupFlag) != nil
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            if !app.social.isSignedIn && !previewingGroups {
                // Un compte d'abord : sans lui, un groupe ne se partage pas.
                GroupsSignInView()
            } else {
            CarnetScroll {
                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                        .padding(.horizontal, 6)
                }
                if groups.isEmpty {
                    emptyState
                } else {
                    if groups.count > 1 { switcher }
                    if let selected {
                        GroupHubView(group: selected)
                            .id(selected.id)
                    }
                }
            }
            .navigationTitle(groups.isEmpty ? "Groupes" : (selected?.name ?? String(localized: "Groupes")))
            .carnetSubtitle(subtitle)
            .sheet(isPresented: $showingSubjects) {
                if let selected { GroupSubjectsView(group: selected) }
            }
            .sheet(isPresented: $showingInvite) {
                if let selected { GroupInviteView(group: selected) }
            }
            .navigationDestination(for: StudyGroup.self) { group in
                GroupSettingsView(group: group)
            }
            .navigationDestination(for: GroupSubjectRoute.self) { route in
                if let group = groups.first(where: { $0.id == route.groupID }) {
                    GroupSubjectProgressView(group: group, subject: route.subject)
                }
            }
            .navigationDestination(for: GroupPageRoute.self) { route in
                if let group = groups.first(where: { $0.id == route.groupID }) {
                    switch route.page {
                    case .members: GroupMembersView(group: group)
                    case .time: GroupStudyTimeView(group: group)
                    case .series: GroupSeriesProgressView(group: group)
                    case .planning: GroupPlanningView(group: group)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let selected {
                        Button {
                            showingInvite = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("Inviter dans \(selected.name)")
                    }
                    Menu {
                        if let selected {
                            Section(selected.name) {
                                NavigationLink(value: GroupPageRoute(groupID: selected.id, page: .members)) {
                                    Label("Membres", systemImage: "person.3")
                                }
                                Button { showingSubjects = true } label: {
                                    Label("Matières du groupe", systemImage: "books.vertical")
                                }
                                NavigationLink(value: selected) {
                                    Label("Réglages du groupe", systemImage: "gearshape")
                                }
                            }
                        }
                        Section {
                            Button {
                                showingCreate = true
                            } label: {
                                Label("Créer un groupe", systemImage: "plus")
                            }
                            Button {
                                joinCode = ""
                                showingJoin = true
                            } label: {
                                Label("Rejoindre avec un code", systemImage: "number")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Groupes")
                }
            }
            .refreshable { await syncNow() }
            // Le point vert du sélecteur : qui travaille, dans chaque groupe.
            // La fonction existait mais n'était appelée nulle part — le direct
            // ne s'allumait jamais hors du groupe ouvert.
            .task(id: groups.compactMap(\.remoteID)) { await watchPresence() }
            .sheet(isPresented: $showingCreate) { CreateGroupView() }
            .sheet(isPresented: $showingJoin) { JoinGroupView(prefilledCode: joinCode) }
            .task {
                // Les données de démonstration ne se créent que sur demande explicite
                // en Debug. Elles ont déjà été injectées chez de vrais utilisateurs
                // quand cet appel était inconditionnel.
                #if DEBUG
                if PreviewLaunch.isSet(PreviewLaunch.seedFlag) {
                    GroupDemoData.seedIfNeeded(context)
                }
                // `-group 0` ouvre directement la fiche d'un groupe : `simctl` ne
                // sait pas taper, et ces écrans ne sont atteignables qu'après deux
                // navigations.
                if let index = PreviewLaunch.int(PreviewLaunch.groupFlag),
                   groups.indices.contains(index) {
                    path.append(groups[index])
                    if let code = PreviewLaunch.string(PreviewLaunch.groupSubjectFlag) {
                        path.append(GroupSubjectRoute(groupID: groups[index].id, subject: code))
                    }
                    if let raw = PreviewLaunch.string(PreviewLaunch.groupPageFlag),
                       let page = GroupPageRoute.Page(rawValue: raw) {
                        path.append(GroupPageRoute(groupID: groups[index].id, page: page))
                    }
                }
                #endif
                if app.social.isSignedIn {
                    await syncNow()
                }
            }
            // Un lien d'invitation ouvert pendant que l'app tourne.
            .onChange(of: app.router.pendingJoinCode) { _, newValue in
                guard let code = newValue else { return }
                joinCode = code
                showingJoin = true
                _ = app.router.consumeJoinCode()
            }
            .onAppear {
                // …et un lien qui a lancé l'app, avant que cet écran n'existe.
                if let code = app.router.consumeJoinCode() {
                    joinCode = code
                    showingJoin = true
                }
            }
            }
        }
        .onChange(of: app.social.isSignedIn) { _, signedIn in
            if signedIn { Task { await syncNow() } }
        }
    }

    private var subtitle: String {
        guard let selected else { return String(localized: "Travailler ensemble") }
        var parts = [Plural.count(selected.members.count, "\(selected.members.count) membre", "\(selected.members.count) membres")]
        if !selected.subjectCodes.isEmpty { parts.append(selected.subjectCodes.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var switcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { group in
                    Button {
                        withAnimation(Motion.snappy) { selectedRaw = group.id.uuidString }
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.name)
                            if !(live[group.id] ?? []).isEmpty {
                                Circle().fill(Carnet.correct).frame(width: 6, height: 6)
                            }
                        }
                        .font(.subheadline.weight(selected?.id == group.id ? .semibold : .regular))
                        .foregroundStyle(selected?.id == group.id ? Carnet.ground : Carnet.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(selected?.id == group.id ? Carnet.ink : Carnet.sheet, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            CarnetEmpty(icon: "person.2",
                        title: String(localized: "Travailler à plusieurs"),
                        message: String(localized: "Qui travaille, qui en est où, entraide et sessions."),
                        actionTitle: String(localized: "Créer un groupe")) {
                showingCreate = true
            }
            Button("Rejoindre avec un code") {
                joinCode = ""
                showingJoin = true
            }
            .buttonStyle(.carnetSecondaryWide)
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = await GroupSync.refresh(context: context,
                                              social: app.social,
                                              settings: app.settings)
    }

    /// Le direct de chaque groupe synchronisé : relu à chaque changement de
    /// présence annoncé en temps réel, et toutes les deux minutes par sécurité
    /// (une présence s'éteint aussi d'elle-même, sans événement, en vieillissant).
    private func watchPresence() async {
        guard app.social.isSignedIn else { return }
        let remote = groups.compactMap { group in group.remoteID.map { (group.id, $0) } }
        let subscriptions = remote.compactMap { local, remoteID in
            app.social.realtime?.subscribe(groupID: remoteID) { table in
                guard table == .presence else { return }
                Task { @MainActor in
                    guard let entries = try? await app.social.fetchPresence(groupID: remoteID) else { return }
                    live[local] = PresenceBoard.live(entries)
                }
            }
        }
        defer { subscriptions.forEach { app.social.realtime?.unsubscribe($0) } }
        while !Task.isCancelled {
            var next: [UUID: [PresenceEntry]] = [:]
            for (local, remoteID) in remote {
                guard let entries = try? await app.social.fetchPresence(groupID: remoteID) else { continue }
                next[local] = PresenceBoard.live(entries)
            }
            live = next
            // Le temps réel prévient des changements ; ceci n'est qu'un filet,
            // au rythme où une présence se renouvelle (5 min).
            try? await Task.sleep(for: .seconds(PresenceEntry.heartbeat))
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where index < groups.count {
            context.delete(groups[index])
        }
        try? context.save()
    }
}


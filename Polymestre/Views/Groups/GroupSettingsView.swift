import SwiftUI
import SwiftData

/// Les réglages d'un groupe, sur papier : nom et description, invitation,
/// matières, membres, ce que je partage, et quitter ou supprimer.
///
/// Remplace l'ancienne fiche du groupe (`GroupDetailView`), qui mêlait le
/// tableau de bord et l'administration dans l'ancien style : le tableau de bord
/// vit dans l'onglet (`GroupHubView`), l'administration ici.
struct GroupSettingsView: View {
    let group: StudyGroup

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var myCourses: [Course]

    @State private var name = ""
    @State private var details = ""
    @State private var showingSubjects = false
    @State private var showingInvite = false
    @State private var showingLeave = false
    @State private var showingDelete = false
    @State private var isBusy = false
    @State private var message: String?

    private var me: GroupMember? { group.members.first(where: \.isMe) }
    private var iAmAdmin: Bool { me?.isAdmin ?? group.isAdmin }
    private var canEdit: Bool { group.remoteID == nil || iAmAdmin }
    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespaces) != group.name || details != group.details
    }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                Section {
                    TextField("Nom du groupe", text: $name)
                        .font(Carnet.serif(.title3))
                        .disabled(!canEdit)
                    TextField("Description (facultatif)", text: $details, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(!canEdit)
                    if isDirty {
                        Button {
                            Task { await saveIdentity() }
                        } label: {
                            Label("Enregistrer", systemImage: "checkmark")
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Groupe"))
                } footer: {
                    if !canEdit { Text("Réservé aux administrateurs.") }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Code").font(.caption).foregroundStyle(Carnet.inkSecondary)
                            Text(group.inviteCode)
                                .font(Carnet.mono(.title3, weight: .semibold))
                                .foregroundStyle(Carnet.ink)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            showingInvite = true
                        } label: {
                            Label("Inviter", systemImage: "qrcode")
                        }
                        .buttonStyle(.carnetPrimary)
                        .disabled(group.remoteID == nil)
                    }
                    syncStatus
                    if group.remoteID == nil, app.social.isSignedIn {
                        Button {
                            Task { await publish() }
                        } label: {
                            Label("Publier ce groupe pour pouvoir inviter", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(isBusy)
                    }
                } header: {
                    CarnetFormHeader("Invitation")
                }

                Section {
                    if group.subjectCodes.isEmpty {
                        Text("Aucune matière.")
                            .foregroundStyle(Carnet.inkSecondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(group.subjectCodes, id: \.self) { code in
                                let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
                                HStack(spacing: 5) {
                                    if let course {
                                        Circle().fill(Carnet.tint(course.colorHex)).frame(width: 7, height: 7)
                                    }
                                    Text(code).font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(course == nil ? Carnet.inkTertiary : Carnet.ink)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 28)
                                .background(Carnet.sheetRaised, in: Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        showingSubjects = true
                    } label: {
                        Label(group.subjectCodes.isEmpty ? "Choisir les matières" : "Modifier les matières",
                              systemImage: "books.vertical")
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Matières"))
                }

                Section {
                    NavigationLink(value: GroupPageRoute(groupID: group.id, page: .members)) {
                        HStack {
                            Label("Membres", systemImage: "person.3")
                            Spacer()
                            Text("\(group.members.count) · \(group.members.filter(\.isAdmin).count) admin")
                                .font(.subheadline)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                    NavigationLink(value: GroupPageRoute(groupID: group.id, page: .planning)) {
                        Label("Sessions planifiées", systemImage: "calendar")
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Membres"))
                }

                Section {
                    Toggle(isOn: $settings.shareProgressWithGroups) {
                        Label("Partager mon avancement", systemImage: "chart.bar")
                    }
                    Toggle(isOn: $settings.anonymousInLeaderboards) {
                        Label("Apparaître anonymement", systemImage: "eye.slash")
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Ce que je partage"))
                }

                Section {
                    Button(role: .destructive) {
                        showingLeave = true
                    } label: {
                        Label("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    if canEdit {
                        Button(role: .destructive) {
                            showingDelete = true
                        } label: {
                            Label("Supprimer le groupe", systemImage: "trash")
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
            .listRowBackground(Carnet.sheet)
        }
        .carnetForm()
        .navigationTitle("Réglages du groupe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = group.name
            details = group.details
        }
        .sheet(isPresented: $showingSubjects) { GroupSubjectsView(group: group) }
        .sheet(isPresented: $showingInvite) { GroupInviteView(group: group) }
        .confirmationDialog("Quitter « \(group.name) » ?", isPresented: $showingLeave, titleVisibility: .visible) {
            Button("Quitter", role: .destructive) { Task { await leave() } }
        } message: {
            Text(leaveWarning)
        }
        .confirmationDialog("Supprimer « \(group.name) » pour tout le monde ?", isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { Task { await deleteGroup() } }
        } message: {
            Text("Les membres, le planning et l'entraide du groupe sont effacés.")
        }
    }

    private var syncStatus: some View {
        let synced = group.remoteID != nil
        return Label(synced ? "Synchronisé avec les membres"
                            : (app.social.isSignedIn ? String(localized: "Seulement sur cet appareil") : String(localized: "Connecte-toi pour inviter")),
                     systemImage: synced ? "checkmark.icloud" : "icloud.slash")
            .font(.footnote)
            .foregroundStyle(synced ? Carnet.correct : Carnet.inkSecondary)
    }

    private var leaveWarning: String {
        let admins = group.members.filter(\.isAdmin)
        if iAmAdmin, admins.count <= 1, group.members.count > 1 {
            return String(localized: "Tu es le seul administrateur : plus personne ne pourra gérer les membres après ton départ.")
        }
        return String(localized: "Tu n'apparaîtras plus dans ce groupe. Ton historique de temps reste sur ton appareil.")
    }

    // MARK: Actions

    private func saveIdentity() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        isBusy = true
        defer { isBusy = false }
        if let remoteID = group.remoteID, app.social.isSignedIn {
            do {
                try await app.social.updateGroup(id: remoteID, name: trimmed, description: details)
            } catch {
                message = String(localized: "Enregistrement impossible — \(GroupSync.explain(error))")
                return
            }
        }
        group.name = trimmed
        group.details = details
        try? context.save()
        Haptics.success()
        message = nil
    }

    /// Crée le groupe côté serveur ; n'arrive que si `remoteID` est vide.
    private func publish() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let remote = try await app.social.createGroup(
                name: group.name,
                description: group.details,
                courseCode: "",
                courseCodes: group.subjectCodes,
                displayName: me?.displayName ?? "Moi")
            group.remoteID = remote.id
            if !remote.inviteCode.isEmpty { group.inviteCode = remote.inviteCode }
            me?.role = .admin
            group.isAdmin = true
            try? context.save()
            Haptics.success()
        } catch {
            message = String(localized: "Publication impossible — \(GroupSync.explain(error))")
        }
    }

    /// Le distant d'abord : effacé localement en premier, on resterait membre
    /// côté serveur sans plus jamais pouvoir le voir.
    private func leave() async {
        isBusy = true
        defer { isBusy = false }
        if let remoteID = group.remoteID, app.social.isSignedIn {
            do {
                try await app.social.leaveGroup(groupID: remoteID)
            } catch {
                message = String(localized: "Sortie impossible — \(GroupSync.explain(error))")
                return
            }
        }
        context.delete(group)
        try? context.save()
        Haptics.removed()
        dismiss()
    }

    private func deleteGroup() async {
        if let remoteID = group.remoteID, app.social.isSignedIn {
            do {
                try await app.social.deleteGroup(id: remoteID)
            } catch {
                message = String(localized: "Suppression impossible — \(GroupSync.explain(error))")
                return
            }
        }
        context.delete(group)
        try? context.save()
        Haptics.removed()
        dismiss()
    }
}

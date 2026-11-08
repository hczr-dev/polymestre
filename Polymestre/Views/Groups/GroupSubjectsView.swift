import SwiftUI
import SwiftData

/// Définition des matières d'un groupe, et de celles que je suis.
///
/// Deux listes, deux droits : le groupe décide de ce qu'il **travaille** (les
/// administrateurs), et chacun décide de ce qu'il **suit** parmi ces matières.
/// Sans la seconde, un membre inscrit à deux cours sur cinq apparaîtrait partout
/// avec un avancement à zéro sur les trois autres.
struct GroupSubjectsView: View {
    let group: StudyGroup

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var groupSelection: [String] = []
    @State private var mySelection: [String] = []
    @State private var newCode = ""
    @State private var isSaving = false
    @State private var message: String?

    private var me: GroupMember? { group.members.first(where: \.isMe) }
    private var iAmAdmin: Bool { me?.isAdmin ?? group.isAdmin }

    private var myCourses: [Course] { courses.filter(\.isTracked) }

    /// Les codes proposés : mes cours d'abord, puis ceux déjà retenus qui n'y sont
    /// pas (un camarade a pu ajouter une matière que je ne suis pas).
    private var offered: [(code: String, name: String)] {
        var seen = Set<String>()
        var result: [(code: String, name: String)] = []
        for course in myCourses {
            let code = course.code.uppercased()
            guard seen.insert(code).inserted else { continue }
            result.append((code, course.name))
        }
        for code in groupSelection + group.subjectCodes where seen.insert(code.uppercased()).inserted {
            result.append((code.uppercased(), String(localized: "Hors de tes cours")))
        }
        return result.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                groupSection
                mineSection
                if let message {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Matières")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Le bouton n'apparaît que s'il y a quelque chose à enregistrer :
                    // l'enregistrer à chaque bascule enverrait une requête par clic.
                    if iAmAdmin, groupSelection != group.subjectCodes {
                        Button("Enregistrer") { saveGroup() }
                            .disabled(isSaving)
                    }
                }
            }
            .onAppear {
                groupSelection = group.subjectCodes
                let mine = me?.courseCodes ?? []
                mySelection = mine.isEmpty ? group.subjectCodes : mine
            }
        }
    }

    // MARK: Matières du groupe

    private var groupSection: some View {
        Section {
            ForEach(offered, id: \.code) { entry in
                Button {
                    toggle(entry.code, in: &groupSelection)
                } label: {
                    HStack(spacing: Layout.control) {
                        Image(systemName: groupSelection.contains(entry.code) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(groupSelection.contains(entry.code) ? Theme.accent.accessibleMark : Color.secondary)
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
                .disabled(!iAmAdmin)
                .accessibilityLabel("\(entry.code), \(groupSelection.contains(entry.code) ? "retenue" : "non retenue")")
            }

            if iAmAdmin {
                HStack(spacing: Layout.control) {
                    TextField("Ajouter un code (ex : CS-250)", text: $newCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button("Ajouter") { addTypedCode() }
                        .disabled(StudyGroup.normalize([newCode]).isEmpty)
                }
            }
        } header: {
            Text("Matières du groupe")
        }
    }

    // MARK: Mes matières

    private var mineSection: some View {
        Section {
            if groupSelection.isEmpty {
                Text("Aucune matière définie pour l'instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupSelection, id: \.self) { code in
                    Button {
                        toggle(code, in: &mySelection)
                        saveMine()
                    } label: {
                        HStack(spacing: Layout.control) {
                            Image(systemName: mySelection.contains(code) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(mySelection.contains(code) ? Color.green.accessibleMark : Color.secondary)
                            Text(code)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer(minLength: Layout.inline)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(code), \(mySelection.contains(code) ? "suivie" : "non suivie")")
                }
            }
        } header: {
            Text("Mes matières dans ce groupe")
        }
    }

    // MARK: Actions

    private func toggle(_ code: String, in selection: inout [String]) {
        Haptics.tap()
        if let index = selection.firstIndex(of: code) {
            selection.remove(at: index)
        } else {
            selection.append(code)
        }
    }

    private func addTypedCode() {
        let codes = StudyGroup.normalize([newCode])
        guard let code = codes.first else { return }
        if !groupSelection.contains(code) { groupSelection.append(code) }
        if !mySelection.contains(code) { mySelection.append(code) }
        newCode = ""
        Haptics.tap()
    }

    /// Enregistre les matières du groupe.
    ///
    /// Le local d'abord — l'écran reste juste même hors ligne — puis le serveur,
    /// dont le refus est affiché plutôt que masqué.
    private func saveGroup() {
        group.subjectCodes = groupSelection
        try? context.save()
        guard let remoteID = group.remoteID, app.social.isSignedIn else {
            message = String(localized: "Matières enregistrées sur cet appareil. Connecte-toi pour les partager.")
            return
        }
        isSaving = true
        Task {
            do {
                try await app.social.setGroupCourses(groupID: remoteID, codes: groupSelection)
                await MainActor.run {
                    isSaving = false
                    message = String(localized: "Matières partagées avec le groupe.")
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    message = String(localized: "Enregistré localement, mais le partage a échoué — \(GroupSync.explain(error))")
                }
            }
        }
    }

    private func saveMine() {
        if let me {
            me.courseCodes = mySelection
            try? context.save()
        }
        guard let remoteID = group.remoteID, app.social.isSignedIn else { return }
        Task {
            try? await app.social.setMyCourses(groupID: remoteID, codes: mySelection)
        }
    }
}

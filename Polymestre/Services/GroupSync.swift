import Foundation
import SwiftData

/// Synchronisation des groupes avec Supabase (pull des groupes/membres/classements,
/// push de mon temps de travail et de mes séries terminées).
///
/// Toutes les opérations sont « best effort » : sans Supabase configuré,
/// les groupes restent utilisables localement.
///
/// `@MainActor` : chaque fonction modifie des modèles du contexte **principal**
/// (`StudyGroup`, `GroupMember`…) après un `await`. Non isolées, elles reprenaient
/// sur un fil quelconque et écrivaient dans SwiftData pendant que l'écran Groupes
/// ou Aujourd'hui lisait les mêmes objets : `EXC_BAD_ACCESS` dans SwiftData
/// (`GroupsView.subtitle`, `pushMyProgress`, `Course.theoryItems`) — les trois
/// crashs relevés sur l'iPhone le 2 octobre.
@MainActor
enum GroupSync {

    struct PushResult {
        var logs = 0
        var completions = 0
    }

    // MARK: - Point d'entrée

    /// Traduit une erreur du serveur en quelque chose d'actionnable.
    ///
    /// La logique vit dans `GroupErrorExplainer`, qui est **pure** et donc testée
    /// sur les réponses réelles de PostgREST.
    static func explain(_ error: Error) -> String {
        GroupErrorExplainer.explain(raw: error.localizedDescription)
    }

    static func refresh(context: ModelContext,
                        social: SocialService,
                        settings: SettingsStore) async -> String {
        guard social.isConfigured else {
            return "Groupes indisponibles dans cette version."
        }
        guard social.isSignedIn, social.userID != nil else {
            return "Connecte-toi (Réglages › Compte et groupes) pour synchroniser tes groupes."
        }

        var summary: [String] = []
        var repairedMemberships = 0

        do {
            let memberships = try await social.fetchMyGroups()
            for membership in memberships {
                guard let remote = membership.group else { continue }
                let group = upsertGroup(remote, context: context)

                // Mon rôle vient du serveur : c'est lui qui décide des politiques
                // RLS, donc c'est lui qui doit décider de ce que l'app affiche.
                if let raw = membership.role, let role = GroupRole(rawValue: raw) {
                    group.isAdmin = role == .admin
                    if let me = group.members.first(where: \.isMe) {
                        me.role = role
                    }
                }

                // Les six lectures d'un groupe partent **ensemble**.
                //
                // Elles étaient enchaînées : six allers-retours par groupe, soit
                // vingt-quatre pour quatre groupes, avant que le premier pixel de
                // la liste ne bouge. Elles ne dépendent pas l'une de l'autre —
                // seul le rangement en base l'est, et il reste séquentiel.
                let payload = await fetchPayload(groupID: remote.id, social: social)

                if let members = payload.members {
                    applyMembers(members, to: group, social: social, settings: settings, context: context)
                }
                if let courses = payload.memberCourses {
                    applyMemberCourses(courses, to: group)
                }
                if let leaderboard = payload.leaderboard {
                    applyLeaderboard(leaderboard, to: group)
                }
                if let completions = payload.seriesCompletions {
                    applyCompletions(completions, to: group, context: context)
                }
                if let items = payload.itemCompletions {
                    applyItemCompletions(items, to: group, context: context)
                }
                if let sessions = payload.plannedSessions {
                    applyPlannedSessions(sessions, group: group, context: context)
                }
                group.lastSyncedAt = Date()
            }
            summary.append("\(memberships.count) groupe(s)")
        } catch {
            let explained = GroupSync.explain(error)
            AppLog.record(.error, AppLog.Category.sync,
                          "Synchronisation des groupes impossible",
                          detail: explained)
            return "Erreur de synchronisation : \(explained)"
        }

        repairedMemberships = await repairOwnedMemberships(context: context, social: social)

        if repairedMemberships > 0 {
            summary.append("adhésion rétablie dans \(Plural.count(repairedMemberships, "\(repairedMemberships) groupe", "\(repairedMemberships) groupes"))")
        }

        let pushed = await pushMyProgress(context: context, social: social, settings: settings)
        if pushed.logs > 0 { summary.append("\(pushed.logs) entrée(s) de temps envoyée(s)") }
        if pushed.completions > 0 { summary.append("\(pushed.completions) série(s) partagée(s)") }

        try? context.save()
        return "Synchronisé : " + summary.joined(separator: " · ")
    }

    /// Tout ce qu'un groupe demande au serveur, ramené en **un seul aller-retour**.
    ///
    /// Les six appels ne dépendent pas l'un de l'autre : les lancer ensemble divise
    /// la latence par six. `async let` garde le contexte de l'appelant, donc rien
    /// ici n'a besoin d'être `Sendable` — ce qui compte, parce que `SocialService`
    /// ne l'est pas.
    private struct GroupPayload {
        var members: [RemoteMember]?
        var memberCourses: [RemoteMemberCourse]?
        var leaderboard: [LeaderboardRow]?
        var seriesCompletions: [RemoteSeriesCompletion]?
        var itemCompletions: [RemoteItemCompletion]?
        var plannedSessions: [RemotePlannedSession]?
    }

    private static func fetchPayload(groupID: String,
                                     social: SocialService) async -> GroupPayload {
        async let members = try? social.fetchMembers(groupID: groupID)
        async let memberCourses = try? social.fetchMemberCourses(groupID: groupID)
        async let leaderboard = try? social.fetchLeaderboard(groupID: groupID)
        async let completions = try? social.fetchSeriesCompletions(groupID: groupID)
        async let items = try? social.fetchItemCompletions(groupID: groupID)
        async let sessions = try? social.fetchPlannedSessions(groupID: groupID)

        return await GroupPayload(members: members,
                                  memberCourses: memberCourses,
                                  leaderboard: leaderboard,
                                  seriesCompletions: completions,
                                  itemCompletions: items,
                                  plannedSessions: sessions)
    }

    // MARK: - Réparation de l'adhésion

    /// Rétablit mon adhésion aux groupes **que j'ai créés**.
    ///
    /// Pourquoi ici et pas dans la boucle de synchronisation : un groupe dont
    /// l'adhésion serveur manque **n'apparaît pas** dans `fetchMyGroups` — cette
    /// requête part de `group_members`. La boucle principale ne le verrait donc
    /// jamais, et la réparation ne servait à rien. On part des groupes **locaux**.
    ///
    /// Pourquoi seulement ceux que j'ai créés : si un administrateur m'a retiré
    /// d'un groupe que j'avais rejoint, me réinscrire tout seul annulerait sa
    /// décision. Pour un groupe dont je suis le créateur, il n'y a pas d'ambiguïté.
    private static func repairOwnedMemberships(context: ModelContext,
                                               social: SocialService) async -> Int {
        guard social.isSignedIn, let meID = social.userID else { return 0 }
        let locals = ((try? context.fetch(FetchDescriptor<StudyGroup>())) ?? [])
            .filter { $0.remoteID != nil }
        var repaired = 0
        for group in locals {
            guard let remoteID = group.remoteID else { continue }
            guard let remote = try? await social.fetchGroup(id: remoteID),
                  remote.createdBy == meID else { continue }
            // Sans adhésion, `members_read` cache la liste : elle revient vide.
            let members = (try? await social.fetchMembers(groupID: remoteID)) ?? []
            guard !members.contains(where: { $0.userId == meID }) else { continue }
            do {
                try await social.ensureMembership(groupID: remoteID, role: .admin)
                group.isAdmin = true
                repaired += 1
            } catch {
                // Réparation impossible : on le dit, sans bloquer le reste.
                group.lastSyncedAt = nil
            }
        }
        return repaired
    }

    // MARK: - Pull

    private static func upsertGroup(_ remote: RemoteGroup, context: ModelContext) -> StudyGroup {
        let existing = (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? []
        if let match = existing.first(where: { $0.remoteID == remote.id || $0.inviteCode == remote.inviteCode }) {
            match.name = remote.name
            match.details = remote.description ?? match.details
            match.courseCode = remote.courseCode ?? match.courseCode
            // Les matières viennent du serveur : c'est le groupe qui les définit,
            // pas cet appareil. On ne les touche pas si le serveur n'en renvoie
            // aucune (ancienne base, ou requête imbriquée refusée).
            let codes = remote.subjectCodes
            if !codes.isEmpty { match.subjectCodes = codes }
            match.remoteID = remote.id
            return match
        }
        let group = StudyGroup(remoteID: remote.id,
                               name: remote.name,
                               details: remote.description ?? "",
                               courseCode: remote.courseCode ?? "",
                               courseCodes: remote.subjectCodes,
                               inviteCode: remote.inviteCode,
                               // Découvert par synchronisation, donc rejoint et non
                               // créé : `true` par défaut donnait les droits
                               // d'administration à quiconque synchronisait.
                               isAdmin: false)
        context.insert(group)
        return group
    }

    private static func applyMembers(_ members: [RemoteMember],
                                     to group: StudyGroup,
                                     social: SocialService,
                                     settings: SettingsStore,
                                     context: ModelContext) {
        for member in members {
            let isMe = member.userId == social.userID
            // Le rôle est décidé par le serveur. Un membre qui se voit « admin »
            // dans l'app afficherait des actions que les politiques RLS refusent.
            let role = GroupRole(rawValue: member.role ?? "") ?? .member
            if let existing = group.members.first(where: { $0.userID == member.userId }) {
                if let name = member.profile?.displayName, !name.isEmpty {
                    existing.displayName = name
                }
                existing.isMe = isMe
                existing.isAnonymous = isMe ? settings.anonymousInLeaderboards : existing.isAnonymous
                existing.role = role
                continue
            }
            let entry = GroupMember(group: group,
                                    userID: member.userId,
                                    displayName: member.profile?.displayName ?? "Membre",
                                    isMe: isMe,
                                    isAnonymous: isMe ? settings.anonymousInLeaderboards : false,
                                    role: role)
            context.insert(entry)
        }
    }

    /// Applique les matières que chaque membre suit.
    ///
    /// Une liste vide côté serveur veut dire « tout le groupe » : c'est la valeur
    /// par défaut d'un membre qui vient de rejoindre, et la remplacer par « rien »
    /// le ferait disparaître de tous les tableaux d'avancement.
    private static func applyMemberCourses(_ rows: [RemoteMemberCourse], to group: StudyGroup) {
        let byUser = Dictionary(grouping: rows, by: \.userId)
        for member in group.members {
            guard let mine = byUser[member.userID] else { continue }
            let codes = StudyGroup.normalize(mine.map(\.courseCode))
            if !codes.isEmpty { member.courseCodes = codes }
        }
    }

    private static func applyLeaderboard(_ rows: [LeaderboardRow], to group: StudyGroup) {
        for row in rows {
            guard let member = group.members.first(where: { $0.userID == row.userId }) else { continue }
            member.weeklySeconds = row.weeklySeconds
            member.totalSeconds = row.totalSeconds
            member.completedSeriesCount = row.seriesCompleted
            if let name = row.displayName, !name.isEmpty, !member.isMe {
                member.displayName = name
            }
        }
    }

    /// Applique l'avancement détaillé récupéré du serveur.
    ///
    /// Upsert par clé (membre × cours × nature × numéro) : une ligne déjà connue est
    /// mise à jour plutôt que dupliquée, sinon chaque synchronisation gonflerait la
    /// base locale.
    private static func applyItemCompletions(_ rows: [RemoteItemCompletion],
                                             to group: StudyGroup,
                                             context: ModelContext) {
        for row in rows {
            let kind = GroupItemKind(rawValue: row.itemKind) ?? .exercise
            let known = group.itemCompletions.contains {
                $0.userID == row.userId
                    && $0.courseCode == row.courseCode
                    && $0.kind == kind
                    && $0.itemNumber == row.itemNumber
            }
            guard !known else { continue }
            let entry = GroupItemCompletion(group: group,
                                            userID: row.userId,
                                            displayName: "",
                                            courseCode: row.courseCode,
                                            kind: kind,
                                            itemNumber: row.itemNumber)
            context.insert(entry)
        }
    }

    private static func applyCompletions(_ rows: [RemoteSeriesCompletion],
                                         to group: StudyGroup,
                                         context: ModelContext) {
        for row in rows {
            let alreadyThere = group.completions.contains {
                $0.userID == row.userId
                    && $0.courseCode == row.courseCode
                    && $0.seriesNumber == row.seriesNumber
            }
            guard !alreadyThere else { continue }
            let member = group.members.first { $0.userID == row.userId }
            let entry = GroupSeriesCompletion(group: group,
                                              userID: row.userId,
                                              displayName: member?.displayName ?? "Membre",
                                              courseCode: row.courseCode,
                                              seriesNumber: row.seriesNumber)
            context.insert(entry)
        }
    }

    private static func applyPlannedSessions(_ rows: [RemotePlannedSession],
                                             group: StudyGroup,
                                             context: ModelContext) {
        let formatter = ISO8601DateFormatter()
        for row in rows {
            guard let startsAt = formatter.date(from: row.startsAt) else { continue }
            let exists = (try? context.fetch(FetchDescriptor<PlannedSession>()))?.contains(where: {
                $0.groupName == group.name
                    && abs($0.startsAt.timeIntervalSince(startsAt)) < 60
                    && $0.title == row.title
            }) ?? false
            guard !exists else { continue }
            let session = PlannedSession(course: nil,
                                         groupRemoteID: group.remoteID ?? group.inviteCode,
                                         groupName: group.name,
                                         title: row.title,
                                         startsAt: startsAt,
                                         durationMinutes: row.durationMinutes,
                                         location: row.location ?? "",
                                         createdByUserID: row.createdBy ?? "")
            context.insert(session)
        }
    }

    // MARK: - Push

    @discardableResult
    static func pushMyProgress(context: ModelContext,
                               social: SocialService,
                               settings: SettingsStore) async -> PushResult {
        var result = PushResult()
        guard social.isSignedIn else { return result }
        guard settings.shareProgressWithGroups else { return result }

        let groups = ((try? context.fetch(FetchDescriptor<StudyGroup>())) ?? [])
            .filter { !$0.members.filter(\.isMe).isEmpty }
        let remoteGroups = groups.compactMap { group -> (StudyGroup, String)? in
            guard let remoteID = group.remoteID else { return nil }
            return (group, remoteID)
        }
        guard !remoteGroups.isEmpty else { return result }

        // 1. Temps de travail : agrégat journalier par cours et type (7 derniers
        //    jours) — le chrono **et** les heures de cours suivies, comptés comme
        //    partout ailleurs (`StudyTime`).
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []
        let start = Calendar.current.startOfDay(for: DateUtils.dateRange(days: 7).start)
        let blocks = StudyTime.blocks(events: events.filter { $0.startsAt >= start },
                                      sessions: sessions.filter { $0.startedAt >= start })
        let calendar = Calendar.current
        var aggregated: [String: (Date, String?, String?, Int)] = [:]
        for block in blocks {
            let day = calendar.startOfDay(for: block.start)
            let key = "\(day.timeIntervalSince1970)-\(block.courseCode ?? "-")-\(block.taskType)"
            let existing = aggregated[key]
            aggregated[key] = (day, block.courseCode, block.taskType, (existing?.3 ?? 0) + block.seconds)
        }

        let formatter = ISO8601DateFormatter()
        for (group, remoteID) in remoteGroups {
            // Le temps compte **en entier** : le classement porte sur la charge de
            // travail, pas sur les matières du groupe. Mais le code d'un cours que
            // le groupe ne travaille pas n'a rien à y faire — il est masqué, la
            // durée reste. On garde le total, on retire l'information.
            let subjects = Set(group.subjectCodes)
            let logs = aggregated.values.map { entry in
                let code = entry.1.flatMap { subjects.contains($0.uppercased()) ? $0 : nil }
                return RemoteStudyLog(userId: social.userID ?? "",
                                      groupId: remoteID,
                                      courseCode: code,
                                      taskType: entry.2,
                                      startedAt: formatter.string(from: entry.0),
                                      durationSeconds: entry.3)
            }
            // Remplacées, pas ajoutées : deux codes masqués le même jour donnent
            // deux lignes de même clé, fusionnées ici avant l'envoi.
            let merged = Dictionary(grouping: logs) { "\($0.startedAt)|\($0.courseCode ?? "-")|\($0.taskType ?? "-")" }
                .values.map { group in
                    var first = group[0]
                    first.durationSeconds = group.reduce(0) { $0 + $1.durationSeconds }
                    return first
                }
            await social.replaceStudyLogs(merged, groupID: remoteID, since: start)
            result.logs += merged.count
        }

        // 2. Séries terminées et avancement détaillé, **restreints aux matières du
        //    groupe**. Sans ce filtre, ouvrir un groupe sur CS-250 publiait aussi
        //    l'avancement de mes quatre autres cours : inutile pour les autres, et
        //    une fuite de données que rien ne justifie.
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        for (group, remoteID) in remoteGroups {
            let subjects = Set(group.subjectCodes)
            let scoped = courses.filter { subjects.contains($0.code.uppercased()) }

            let completed = scoped.flatMap { course in
                // « Série 5 terminée » ne dit pas laquelle de 5a et 5b : une série
                // étiquetée ne se partage qu'exercice par exercice.
                course.sortedSeries.filter { $0.isComplete && $0.label.isEmpty }.map { (course.code, $0.seriesNumber) }
            }
            for item in completed {
                let alreadyShared = group.completions.contains {
                    $0.userID == (social.userID ?? "")
                        && $0.courseCode == item.0
                        && $0.seriesNumber == item.1
                }
                guard !alreadyShared else { continue }
                await social.pushSeriesCompletion(groupID: remoteID,
                                                  courseCode: item.0,
                                                  seriesNumber: item.1)
                context.insert(GroupSeriesCompletion(group: group,
                                                     userID: social.userID ?? "",
                                                     displayName: settings.displayName.isEmpty ? "Moi" : settings.displayName,
                                                     courseCode: item.0,
                                                     seriesNumber: item.1))
                result.completions += 1
            }

            // Avancement **exercice par exercice** : ce que la série ne dit pas.
            var payload: [RemoteItemCompletion] = []
            for course in scoped {
                for exercise in course.allExercises where exercise.isDone {
                    payload.append(RemoteItemCompletion(groupId: remoteID,
                                                        userId: social.userID ?? "",
                                                        courseCode: course.code,
                                                        itemKind: GroupItemKind.exercise.rawValue,
                                                        itemNumber: exercise.groupNumber))
                }
                for item in course.theoryItems where item.isWatched {
                    payload.append(RemoteItemCompletion(groupId: remoteID,
                                                        userId: social.userID ?? "",
                                                        courseCode: course.code,
                                                        itemKind: GroupItemKind.theory.rawValue,
                                                        itemNumber: item.number))
                }
            }
            let alreadyShared = Set(group.itemCompletions
                .filter { $0.userID == (social.userID ?? "") }
                .map { "\($0.courseCode)|\($0.kindRaw)|\($0.itemNumber)" })
            let fresh = payload.filter {
                !alreadyShared.contains("\($0.courseCode)|\($0.itemKind)|\($0.itemNumber)")
            }
            if !fresh.isEmpty {
                await social.pushItemCompletions(fresh)
                for row in fresh {
                    context.insert(GroupItemCompletion(group: group,
                                                       userID: row.userId,
                                                       displayName: settings.displayName.isEmpty ? "Moi" : settings.displayName,
                                                       courseCode: row.courseCode,
                                                       kind: GroupItemKind(rawValue: row.itemKind) ?? .exercise,
                                                       itemNumber: row.itemNumber))
                }
                result.completions += fresh.count
            }
        }

        try? context.save()
        return result
    }
}

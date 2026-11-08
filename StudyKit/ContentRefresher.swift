import Foundation
import SwiftData

/// Relit Moodle et Botafogo **tout seul**, pour les cours déjà importés —
/// sur l'iPhone comme sur le Mac, avec la même chaîne (règles, IA, Botafogo,
/// lecture des énoncés).
///
/// Sans elle, la série 4 publiée mardi n'existait dans l'app que si l'on
/// pensait à réimporter. Au passage au premier plan, au plus toutes les douze
/// heures : chaque cours relié à Moodle (son adresse est dans ses sources) ou à
/// Botafogo est relu, et ce qui est **nouveau** est ajouté.
///
/// Un seul appareil s'en charge (`CloudRelay.refreshIsDue`) : la relecture est
/// réclamée dans iCloud avant de commencer. Le Mac relisait avec ses seules
/// règles, toutes les six heures : sa réclamation privait l'iPhone de la
/// relecture complète, et ce qu'il trouvait ne s'annonçait nulle part.
/// Désormais, celui qui relit fait tout, et l'annonce est partagée.
///
/// Prudente par construction :
///   • rien n'est supprimé (`ContentDraftWriter` n'efface jamais) ;
///   • une semaine corrigée à la main n'est pas réécrite (`updateWeeks: false`) ;
///   • sans connexion Moodle valide, on n'insiste pas : pas de fenêtre de
///     connexion surgie de nulle part, l'écran d'import le dira.
@MainActor
enum ContentRefresher {
    static let interval: TimeInterval = 12 * 3600
    private static var running = false

    static func refreshIfDue(context: ModelContext, settings: SettingsStore, force: Bool = false, now: Date = Date()) async {
        guard settings.contentAutoRefresh || force, !running else { return }
        // Un seul appareil relit : l'iPad ouvert une heure après l'iPhone ne
        // relit pas Moodle (ni ne repaie l'IA) — ce qui a été ajouté arrive
        // par iCloud. Sauf si la surveillance d'ici vient de trouver du neuf.
        #if os(iOS)
        let forced = MoodleWatcher.hasPendingNews
        #else
        let forced = false
        #endif
        guard force || forced || CloudRelay.refreshIsDue(localLast: settings.contentLastRefresh,
                                                claim: CloudRelay.moodleRefreshClaim(),
                                                device: CloudRelay.deviceID,
                                                interval: interval, now: now) else {
            await watchSourcesIfDue(context: context, settings: settings, now: now)
            return
        }
        CloudRelay.claimMoodleRefresh(now: now)
        #if os(iOS)
        MoodleWatcher.hasPendingNews = false
        #endif
        running = true
        defer { running = false }

        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        let moodleCourses = courses.filter { MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
        // Un cours lié à Moodle passe par la chaîne d'import, qui lit Botafogo
        // elle-même quand il le faut : pas de seconde lecture.
        let botafogoCourses = courses.compactMap { course -> (Course, URL)? in
            guard MoodleCourseMatcher.linkedID(in: course.contentSources) == nil, let link = course.contentSources.compactMap(URL.init(string:))
                    .first(where: { ContentSource.detect(host: $0.host) == .botafogo }) else { return nil }
            return (course, link)
        }
        guard !moodleCourses.isEmpty || !botafogoCourses.isEmpty else {
            settings.contentLastRefresh = now
            return
        }

        var news: [String] = []

        if !moodleCourses.isEmpty {
            let client = MoodleClient.background
            // La session Moodle de l'app expire en quelques jours : on se
            // reconnecte d'abord sans rien afficher (Microsoft s'en souvient),
            // sinon la mise à jour était sautée en silence pendant des semaines.
            await SchoolConnect.shared.ensure(.moodle, prompting: false)
            if await client.ensureSignedIn() {
                let enrolled = (try? await client.enrolled()) ?? []
                for course in moodleCourses {
                    guard case .unique(let ref)? = try? await client.resolve(course, enrolled: enrolled),
                          let snapshot = try? await client.snapshot(of: ref) else { continue }
                    let draft = await CourseImportPipeline.draft(from: snapshot, termStart: course.term?.startDate,
                                                                 totalWeeks: course.term?.totalWeeks ?? 14, settings: settings).draft
                    if let line = apply(draft, to: course, context: context) { news.append(line) }
                }
            } else {
                AppLog.record(.info, "import", "Mise à jour Moodle sautée : reconnexion nécessaire")
            }
        }

        for (course, link) in botafogoCourses {
            guard let draft = try? await BotafogoClient.draft(at: link, termStart: course.term?.startDate,
                                                              totalWeeks: course.term?.totalWeeks ?? 14) else { continue }
            if let line = apply(draft, to: course, context: context) { news.append(line) }
        }

        try? context.save()
        settings.contentLastRefresh = now
        // Une série apparue sur Moodle arrive avec son énoncé lu.
        news.append(contentsOf: await SeriesAutoReader.shared.readPending(courses: courses, context: context, settings: settings))
        if !news.isEmpty {
            settings.contentRefreshNews = news.joined(separator: " · ")
            AppLog.record(.info, "import", "Mise à jour automatique", detail: settings.contentRefreshNews)
        }
    }

    /// Entre deux mises à jour (12 h, un seul appareil) : les énoncés publics
    /// des séries récentes, vérifiés au plus toutes les trois heures — une
    /// requête conditionnelle par série, rien de téléchargé s'ils n'ont pas
    /// changé. Un énoncé révisé est relu tout de suite (`SeriesSourceWatch`).
    static let sourceWatchInterval: TimeInterval = 3 * 3600
    private static let sourceWatchKey = "content.sourceWatch.last"

    private static func watchSourcesIfDue(context: ModelContext, settings: SettingsStore, now: Date) async {
        let last = UserDefaults.standard.object(forKey: sourceWatchKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= sourceWatchInterval else { return }
        UserDefaults.standard.set(now, forKey: sourceWatchKey)
        running = true
        defer { running = false }
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        // Sans Moodle : ses fichiers demandent la session, ils attendent la
        // mise à jour complète.
        guard await SeriesSourceWatch.flagChanged(courses: courses, moodleReady: false) > 0 else { return }
        let news = await SeriesAutoReader.shared.readPending(courses: courses, context: context, settings: settings)
        if !news.isEmpty {
            settings.contentRefreshNews = SettingsStore.mergedNews(settings.contentRefreshNews, adding: news.joined(separator: " · "))
        }
    }

    /// Écrit ce qui est nouveau ; rend « MATH-101 : 1 série » s'il y en a.
    private static func apply(_ draft: ContentDraft, to course: Course, context: ModelContext) -> String? {
        guard !draft.isEmpty else { return nil }
        let result = ContentDraftWriter.apply(draft, to: course, context: context, updateWeeks: false)
        var parts: [String] = []
        if result.seriesAdded > 0 { parts.append(Plural.count(result.seriesAdded, "\(result.seriesAdded) série", "\(result.seriesAdded) séries")) }
        if result.theoryAdded > 0 { parts.append(String(localized: "\(result.theoryAdded) théorie")) }
        return parts.isEmpty ? nil : "\(course.displayCode) : " + parts.joined(separator: ", ")
    }
}

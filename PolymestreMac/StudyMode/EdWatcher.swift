import Foundation
import Observation

/// Les nouveaux messages d'Ed du cours étudié : un point sur « Cours » dans la
/// colonne d'outils, et une notification. Ed n'a pas d'API de notification pour
/// nous : on relit la liste des fils du cours toutes les cinq minutes pendant la
/// session, et on compte ceux qu'on n'avait pas vus.
///
/// La première lecture d'un cours ne fait que retenir ce qui existe (sinon, tout
/// serait « nouveau »). Les fils sont « vus » quand on ouvre la source Ed du cours.
@MainActor
@Observable
final class EdWatcher {
    static let shared = EdWatcher()

    /// Les fils non vus, par cours (`Course.id`).
    private(set) var unread: [UUID: Int] = [:]
    @ObservationIgnored private var lastThreads: [UUID: [Int]] = [:]

    private func key(_ edCourse: Int) -> String { "ed.seen.\(edCourse)" }

    func poll(courses: [Course], hub: SiteHub) async {
        await hub.loadEdCourses()
        guard let edCourses = hub.edCourses else { return }
        for course in courses {
            guard let ed = EdDiscussion.match(code: course.code, in: edCourses),
                  let threads = try? await hub.ed.threads(course: ed.id) else { continue }
            let ids = threads.map(\.id)
            lastThreads[course.id] = ids
            hub.edThreads[ed.id] = threads
            guard let seen = UserDefaults.standard.array(forKey: key(ed.id)) as? [Int] else {
                // Première lecture : on retient, on ne signale rien.
                UserDefaults.standard.set(ids, forKey: key(ed.id))
                continue
            }
            let fresh = ids.filter { !seen.contains($0) }.count
            let before = unread[course.id] ?? 0
            unread[course.id] = fresh
            if fresh > before {
                DeskNotifications.shared.post(.info, Plural.count(fresh, "\(fresh) nouveau message sur Ed · \(course.displayCode)", "\(fresh) nouveaux messages sur Ed · \(course.displayCode)"),
                                              icon: "bubble.left.and.bubble.right")
            }
        }
    }

    /// Les fils du cours ont été lus (la source Ed est ouverte) : plus rien de nouveau.
    func markSeen(_ course: UUID, hub: SiteHub, courses: [Course]) {
        guard let code = courses.first(where: { $0.id == course })?.code,
              let edCourses = hub.edCourses, let ed = EdDiscussion.match(code: code, in: edCourses) else { return }
        let ids = (hub.edThreads[ed.id] ?? []).map(\.id)
        guard !ids.isEmpty else { return }
        UserDefaults.standard.set(ids, forKey: key(ed.id))
        unread[course] = 0
    }
}

import ActivityKit
import UIKit
import Foundation
import SwiftData
import os

/// Trace d'exécution de l'activité d'examen, lisible dans le journal unifié.
///
/// Même raison que pour le chrono : le simulateur ne photographie pas l'îlot, et
/// c'est la seule façon de savoir, depuis un terminal, si le **système** a accepté
/// l'activité.
private let examTrace = Logger(subsystem: "ch.polymestre", category: "îlot")

/// Pilote la Live Activity du jour d'examen.
///
/// Même contrat que `StudyActivityController` : la source de vérité est
/// `Activity.activities`, jamais une variable de ce type — une variable ne survit
/// pas à une relance de l'app, et c'est ce décalage qui laissait un îlot afficher
/// un état mort.
///
/// Ce qui change ici : l'activité n'est pas déclenchée par un geste, mais par le
/// **temps**. Personne n'appuie sur « commencer l'examen ». Le raccord se fait donc
/// à chaque replanification des rappels et à chaque activation de l'app : on
/// compare la liste des examens proches à ce qui est affiché, et on corrige.
@MainActor
enum ExamActivityController {

    private static var live: [Activity<ExamActivityAttributes>] {
        Activity<ExamActivityAttributes>.activities
    }

    static var liveCount: Int { live.count }

    /// Ce qui a empêché la dernière tentative, en clair — pour le diagnostic.
    private(set) static var lastError: String?

    /// Aligne les activités affichées sur les examens réellement proches.
    ///
    /// Une seule fonction pour les trois cas, parce qu'ils se ramènent tous à la
    /// même question : quel examen mérite l'écran maintenant ?
    ///   • un examen entre dans la fenêtre → on ouvre l'activité ;
    ///   • il en sort, ou il est passé → on la ferme ;
    ///   • il a changé d'heure ou de salle → on la met à jour.
    static func reconcile(exams: [Exam], now: Date = Date()) {
        // Le plus proche d'abord : deux examens le même jour ne doivent pas
        // encombrer l'écran verrouillé de deux comptes à rebours.
        let upcoming = exams
            .filter { ExamActivityState.isRelevant(examDate: $0.date, now: now) }
            .sorted { $0.date < $1.date }

        guard let exam = upcoming.first else {
            end()
            return
        }

        let attributes = ExamActivityAttributes(courseCode: exam.course?.displayCode ?? "Examen",
                                               courseName: exam.course?.name ?? "",
                                               title: exam.title,
                                               examDate: exam.date,
                                               room: exam.location.isEmpty ? nil : exam.location)
        let state = ExamActivityState.make(examDate: exam.date, now: now)

        // Une activité déjà ouverte sur **un autre** examen ne se met pas à jour :
        // les attributs sont figés à la création. Il faut la fermer et rouvrir.
        if let existing = live.first {
            if existing.attributes.examDate == exam.date,
               existing.attributes.title == exam.title {
                Task { await existing.update(content(state, examDate: exam.date)) }
                for extra in live.dropFirst() {
                    Task { await extra.end(nil, dismissalPolicy: .immediate) }
                }
                return
            }
            end()
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = String(localized: "Les Live Activities sont désactivées pour Polymestre.")
            return
        }

        // iOS n'ouvre une activité que depuis l'avant-plan (« Target is not
        // foreground »). Le raccord tourne aussi en tâche de fond — replanification
        // des rappels, rafraîchissement — et y remplissait le journal de refus.
        // Le prochain passage à l'avant-plan rattrape : `reconcileFromStore` est
        // appelé à chaque activation.
        guard UIApplication.shared.applicationState == .active else { return }

        do {
            let created = try Activity.request(attributes: attributes,
                                               content: content(state, examDate: exam.date),
                                               pushType: nil)
            lastError = nil
            examTrace.notice("activité d'examen créée \(created.id, privacy: .public) — \(exam.title, privacy: .public)")
        } catch {
            lastError = String(localized: "Activité d'examen impossible : \(error.localizedDescription)")
            AppLog.record(.error, "îlot", "Live Activity d'examen refusée",
                          detail: error.localizedDescription)
        }
    }

    /// Relit la base et raccorde. Point d'entrée unique pour l'app.
    static func reconcileFromStore(context: ModelContext) {
        let exams = (try? context.fetch(FetchDescriptor<Exam>())) ?? []
        reconcile(exams: exams)
    }

    static func end() {
        for activity in live {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ouvre une activité d'essai, pour vérifier l'affichage sans attendre la
    /// veille d'une vraie épreuve — le déclencheur étant le temps, c'est le seul
    /// moyen de la voir à la demande.
    static func startTest(now: Date = Date()) {
        let attributes = ExamActivityAttributes(courseCode: "TEST-100",
                                               courseName: String(localized: "Essai"),
                                               title: String(localized: "Examen d'essai"),
                                               examDate: now.addingTimeInterval(2 * 3600),
                                               room: "CO 1")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = String(localized: "Les Live Activities sont désactivées pour Polymestre.")
            examTrace.error("activité d'examen d'essai : activités désactivées")
            return
        }
        do {
            let created = try Activity.request(
                attributes: attributes,
                content: content(ExamActivityState(phase: .upcoming),
                                 examDate: attributes.examDate),
                pushType: nil)
            lastError = nil
            examTrace.notice("activité d'examen d'essai créée \(created.id, privacy: .public)")
        } catch {
            lastError = String(localized: "Activité d'examen impossible : \(error.localizedDescription)")
            examTrace.error("activité d'examen refusée : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// L'activité s'efface d'elle-même quand l'épreuve est finie.
    ///
    /// `staleDate` à la fin supposée de l'épreuve : le système grise l'activité
    /// sans que l'app ait à se réveiller, ce qu'elle ne peut pas garantir. Le
    /// raccord suivant la retirera.
    private static func content(_ state: ExamActivityState,
                                examDate: Date) -> ActivityContent<ExamActivityState> {
        ActivityContent(state: state,
                        staleDate: examDate.addingTimeInterval(ExamActivityState.assumedDuration))
    }
}

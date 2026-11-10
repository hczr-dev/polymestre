import SwiftUI

// MARK: - Type de tâche (traçage du temps par sous-catégorie)

/// Ce sur quoi une session a porté.
///
/// Le travail d'un cours se range en **trois** catégories — Théorie, Séries,
/// Correction — et c'est tout ce que l'étudiant·e choisit. Neuf types côte à
/// côte (« Vidéo », « Théorie », « Résumé », « Cours »…) posaient une question
/// sans réponse : regarder la vidéo 1.2, est-ce « Vidéo » ou « Théorie » ?
///
/// Les anciennes valeurs brutes restent décodables — des sessions, des widgets
/// et des raccourcis les ont enregistrées — mais `canonical` les replie sur la
/// catégorie qui compte. `.flashcards` n'est jamais choisi à la main : c'est le
/// temps passé dans **Anki**, importé tout seul et marqué comme tel.
enum TaskType: String, Codable, CaseIterable, Identifiable {
    case lecture, video, exercise, theory, flashcards, summary, correction, project, other

    var id: String { rawValue }

    /// Les seules catégories proposées dans un sélecteur.
    static let choices: [TaskType] = [.theory, .exercise, .correction, .other]

    /// Les catégories d'un bilan, dans l'ordre d'affichage.
    static let reportCategories: [TaskType] = [.theory, .exercise, .correction, .flashcards, .lecture, .other]

    /// La catégorie qui compte : une vidéo ou un résumé, c'est de la théorie.
    var canonical: TaskType {
        switch self {
        case .video, .summary, .theory: return .theory
        case .project: return .other
        default: return self
        }
    }

    var label: String {
        switch canonical {
        case .lecture: return String(localized: "Cours en amphi")
        case .exercise: return String(localized: "Séries")
        case .theory: return String(localized: "Théorie")
        case .flashcards: return String(localized: "Anki")
        case .correction: return String(localized: "Correction")
        default: return String(localized: "Autre")
        }
    }

    var shortLabel: String {
        switch canonical {
        case .lecture: return String(localized: "Amphi")
        case .exercise: return String(localized: "Séries")
        case .theory: return String(localized: "Théorie")
        case .flashcards: return String(localized: "Anki")
        case .correction: return String(localized: "Corr.")
        default: return String(localized: "Autre")
        }
    }

    var icon: String {
        switch canonical {
        case .lecture: return "building.columns.fill"
        case .exercise: return "list.number"
        case .theory: return "book.fill"
        case .flashcards: return "rectangle.stack.fill"
        case .correction: return "checkmark.seal.fill"
        default: return "ellipsis.circle.fill"
        }
    }

    // La teinte d'une catégorie (`tint`) est dans la palette du papier :
    // StudyKit/CarnetCore.swift.
}

// MARK: - Niveau de confiance (code couleur de sureté de la réponse)

enum ConfidenceLevel: String, Codable, CaseIterable, Identifiable {
    case high = "green"
    case medium = "orange"
    case low = "red"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return String(localized: "Sûr·e")
        case .medium: return String(localized: "Moyennement sûr·e")
        case .low: return String(localized: "Pas sûr·e")
        }
    }

    var shortLabel: String {
        switch self {
        case .high: return String(localized: "Vert")
        case .medium: return String(localized: "Orange")
        case .low: return String(localized: "Rouge")
        }
    }

    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var icon: String { "circle.fill" }

    /// Glyphe porté par la pastille sélectionnée.
    ///
    /// Le sureté ne doit pas être encodée **par la couleur seule** : vert /
    /// orange / rouge est précisément la triade que le daltonisme rouge-vert
    /// confond. La forme est l'indice redondant.
    var glyph: String {
        switch self {
        case .high: return "checkmark"
        case .medium: return "equal"
        case .low: return "questionmark"
        }
    }
}

// MARK: - Résultat de correction

enum Correctness: String, Codable, CaseIterable, Identifiable {
    case correct, partial, wrong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .correct: return String(localized: "Juste")
        case .partial: return String(localized: "Moyennement juste")
        case .wrong: return String(localized: "Faux")
        }
    }

    var shortLabel: String {
        switch self {
        case .correct: return String(localized: "Juste")
        case .partial: return String(localized: "Moyen")
        case .wrong: return String(localized: "Faux")
        }
    }

    var color: Color {
        switch self {
        case .correct: return .green
        case .partial: return .orange
        case .wrong: return .red
        }
    }

    var icon: String {
        switch self {
        case .correct: return "checkmark.circle.fill"
        case .partial: return "minus.circle.fill"
        case .wrong: return "xmark.circle.fill"
        }
    }
}

// MARK: - Type d'évaluation (midterm / examen / …)

enum ExamKind: String, Codable, CaseIterable, Identifiable {
    case midterm, exam, quiz, project, assignment, other

    /// Une vraie épreuve (midterm, examen) : ce qui fait passer le bureau en révision.
    /// Un quiz, un devoir ou une échéance importée n'en est pas une.
    var isSitting: Bool { self == .midterm || self == .exam }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midterm: return String(localized: "Midterm")
        case .exam: return String(localized: "Examen")
        case .quiz: return String(localized: "Quiz")
        case .project: return String(localized: "Projet")
        case .assignment: return String(localized: "Devoir")
        case .other: return String(localized: "Autre")
        }
    }

    var icon: String {
        switch self {
        case .midterm: return "clock.badge.exclamationmark.fill"
        case .exam: return "graduationcap.fill"
        case .quiz: return "questionmark.circle.fill"
        case .project: return "hammer.fill"
        case .assignment: return "doc.text.fill"
        case .other: return "calendar.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .midterm: return .orange
        case .exam: return .red
        case .quiz: return .yellow
        case .project: return .brown
        case .assignment: return .blue
        case .other: return .gray
        }
    }
}

// MARK: - Semestre

enum TermSeason: String, Codable, CaseIterable, Identifiable {
    case autumn, spring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autumn: return String(localized: "Automne")
        case .spring: return String(localized: "Printemps")
        }
    }
}

// MARK: - Fournisseur de tâches

/// Type de support d'un élément de théorie.
///
/// Certains cours EPFL n'ont aucune vidéo, d'autres mélangent vidéos et supports
/// écrits. Le support appartient donc à l'élément, jamais au cours : aucun écran
/// ne doit supposer qu'une théorie se regarde.
enum TheoryKind: String, Codable, CaseIterable, Identifiable {
    case video, reading, chapter, slides

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return String(localized: "Vidéo")
        case .reading: return String(localized: "Lecture")
        case .chapter: return String(localized: "Chapitre")
        case .slides: return String(localized: "Diapositives")
        }
    }

    /// Au pluriel, pour les en-têtes de section.
    var pluralLabel: String {
        switch self {
        case .video: return String(localized: "Vidéos")
        case .reading: return String(localized: "Lectures")
        case .chapter: return String(localized: "Chapitres")
        case .slides: return String(localized: "Diapositives")
        }
    }

    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .reading: return "book.fill"
        case .chapter: return "doc.text.fill"
        case .slides: return "rectangle.on.rectangle"
        }
    }

    /// Une durée a-t-elle un sens pour ce support ? Un chapitre sans durée ne
    /// doit pas s'afficher « 0 min ».
    var hasDuration: Bool {
        switch self {
        case .video, .slides: return true
        case .reading, .chapter: return false
        }
    }
}

enum TaskProvider: String, Codable, CaseIterable, Identifiable {
    case reminders, todoist, things, notion, webhook
    case googleTasks, tickTick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminders: return String(localized: "Rappels")
        case .todoist: return String(localized: "Todoist")
        case .things: return String(localized: "Things 3")
        case .notion: return String(localized: "Notion")
        case .webhook: return String(localized: "Webhook")
        case .googleTasks: return String(localized: "Google Tasks")
        case .tickTick: return String(localized: "TickTick")
        }
    }

    var icon: String {
        switch self {
        case .reminders: return "checklist"
        case .todoist: return "checkmark.square.fill"
        case .things: return "checkmark.circle"
        case .notion: return "doc.richtext"
        case .webhook: return "bolt.horizontal.circle.fill"
        case .googleTasks: return "checkmark.circle.fill"
        case .tickTick: return "checkmark.seal.fill"
        }
    }

    /// Ce fournisseur permet-il de **lire** les tâches existantes ?
    ///
    /// Things 3 n'expose pas d'API de lecture : on peut seulement y créer des tâches
    /// via son schéma d'URL. Le webhook est en écriture seule par construction.
    var supportsReading: Bool {
        switch self {
        case .reminders, .todoist, .notion,
             .googleTasks, .tickTick:
            return true
        case .things, .webhook:
            return false
        }
    }

    /// Clé de réglage associée (jeton, URL…).
    var credentialLabel: String? {
        switch self {
        case .reminders: return nil
        case .todoist: return String(localized: "Jeton API Todoist")
        case .things: return nil
        case .notion: return String(localized: "Jeton d'intégration Notion")
        case .webhook: return String(localized: "URL du webhook")
        case .googleTasks: return "Refresh token OAuth Google"
        case .tickTick: return String(localized: "Jeton d'accès TickTick")
        }
    }

    var helpText: String {
        switch self {
        case .reminders:
            return String(localized: "Synchronisation native avec l'app Rappels. Aucun réglage nécessaire.")
        case .todoist:
            return String(localized: "Créez un jeton dans Todoist › Paramètres › Intégrations › Développeur.")
        case .things:
            return String(localized: "Things 3 est en écriture seule : l'app peut y envoyer des tâches, mais pas les relire.")
        case .notion:
            return String(localized: "Créez une intégration Notion, partagez-lui une base de données, puis collez le jeton et l'ID de la base.")
        case .webhook:
            return String(localized: "Polymestre envoie un JSON à cette URL (compatible Shortcuts, Home Assistant, Zapier, n8n).")
        case .googleTasks:
            return String(localized: "Identifiant client, secret et refresh token OAuth : l'app renouvelle ensuite l'accès toute seule.")
        case .tickTick:
            return String(localized: "Jeton d'accès de l'API ouverte TickTick (OAuth2).")
        }
    }
}

// MARK: - Type d'événement d'agenda

enum CalendarEventKind: String, Codable, CaseIterable, Identifiable {
    case lecture, exerciseSession, midterm, exam, study, personal, task, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lecture: return String(localized: "Cours")
        case .exerciseSession: return String(localized: "Séance d'exercices")
        case .midterm: return String(localized: "Midterm")
        case .exam: return String(localized: "Examen")
        case .study: return String(localized: "Session d'étude")
        case .personal: return String(localized: "Personnel")
        case .task: return String(localized: "Tâche")
        case .other: return String(localized: "Autre")
        }
    }

    var icon: String {
        switch self {
        case .lecture: return "building.columns.fill"
        case .exerciseSession: return "pencil.and.list.clipboard"
        case .midterm: return "clock.badge.exclamationmark.fill"
        case .exam: return "graduationcap.fill"
        case .study: return "timer"
        case .personal: return "person.fill"
        case .task: return "checklist"
        case .other: return "calendar"
        }
    }

    var color: Color {
        switch self {
        case .lecture: return .blue
        case .exerciseSession: return .teal
        case .midterm: return .orange
        case .exam: return .red
        case .study: return .indigo
        case .personal: return .gray
        case .task: return .teal
        case .other: return .gray
        }
    }
}

// MARK: - Événement d'agenda unifié (calendrier + examens + sessions)

enum AgendaItemKind: String, Identifiable {
    case exam, calendar, planned, task, milestone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .milestone: return String(localized: "Calendrier EPFL")
        case .exam: return String(localized: "Évaluation")
        case .calendar: return String(localized: "Calendrier")
        case .planned: return String(localized: "Session planifiée")
        case .task: return String(localized: "Tâche")
        }
    }
}

// MARK: - Période pour les récaps visuels


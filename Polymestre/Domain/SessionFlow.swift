import Foundation

/// « Ta session » : les étapes que le bureau propose (Mac et iPhone), dans
/// l'ordre de l'étudiant·e. Par défaut les quatre : revoir le cours, faire la
/// série, bloqué ?, débriefer. Une étape retirée disparaît des deux appareils.
struct SessionFlow: Codable, Equatable {
    enum Step: String, Codable, CaseIterable, Identifiable {
        case course, series, help, debrief
        var id: String { rawValue }
        var title: String {
            switch self {
            case .course: return String(localized: "Revoir le cours")
            case .series: return String(localized: "Faire la série")
            case .help: return String(localized: "Bloqué ?")
            case .debrief: return String(localized: "Débriefer")
            }
        }
    }

    var steps: [Step] = Step.allCases

    static let standard = SessionFlow()
    static let storageKey = "studyFlow"

    static func load(defaults: UserDefaults = .standard) -> SessionFlow {
        guard let data = defaults.data(forKey: storageKey),
              let flow = try? JSONDecoder().decode(SessionFlow.self, from: data), !flow.steps.isEmpty else { return .standard }
        return flow
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    func contains(_ step: Step) -> Bool { steps.contains(step) }

    mutating func toggle(_ step: Step) {
        if let index = steps.firstIndex(of: step) {
            guard steps.count > 1 else { return }
            steps.remove(at: index)
        } else {
            // Remise à sa place d'origine.
            let order = Step.allCases
            let position = steps.firstIndex { order.firstIndex(of: $0)! > order.firstIndex(of: step)! } ?? steps.count
            steps.insert(step, at: position)
        }
    }

    mutating func move(_ step: Step, by offset: Int) {
        guard let index = steps.firstIndex(of: step) else { return }
        let target = min(max(index + offset, 0), steps.count - 1)
        steps.remove(at: index)
        steps.insert(step, at: target)
    }
}

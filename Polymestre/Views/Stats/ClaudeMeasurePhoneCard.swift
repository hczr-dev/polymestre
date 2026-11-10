import Charts
import SwiftUI

/// Le temps de Claude Code (Avec mesure), compté sur le Mac : l'iPhone n'en
/// reçoit que les totaux du jour, par iCloud clé-valeur. Rien à régler ici —
/// les règles vivent sur le Mac, où vit Claude Code.
struct ClaudeMeasurePhoneCard: View {
    @State private var days: [ClaudeMeasure.DaySummary] = []

    var body: some View {
        Group {
            if !days.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CarnetSectionTitle("Claude Code") { Text("compté sur le Mac") }
                    VStack(alignment: .leading, spacing: 12) {
                        figures
                        chart
                    }
                    .padding(16)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
                }
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in load() }
    }

    private var week: [ClaudeMeasure.DaySummary] { Array(days.suffix(7)) }

    private var figures: some View {
        let today = days.last
        let projets = week.reduce(0) { $0 + $1.projets }
        let passes = week.reduce(0) { $0 + $1.passes }
        return HStack(alignment: .firstTextBaseline, spacing: 24) {
            figure(ClaudeMeasure.duration(today?.projets ?? 0), String(localized: "projets aujourd'hui"))
            figure(ClaudeMeasure.duration(projets), String(localized: "projets en 7 jours"))
            figure("\(passes)", passes > 1 ? String(localized: "passes") : String(localized: "pass"))
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        // La légende est le texte des séries : le même, traduit, des deux côtés.
        let projects = String(localized: "projets"), study = String(localized: "étude")
        return Chart {
            ForEach(week) { day in
                BarMark(x: .value("Jour", date(day.day), unit: .day), y: .value("Heures", day.projets / 3600))
                    .foregroundStyle(by: .value("Claude", projects))
                BarMark(x: .value("Jour", date(day.day), unit: .day), y: .value("Heures", day.etude / 3600))
                    .foregroundStyle(by: .value("Claude", study))
            }
        }
        .chartForegroundStyleScale([projects: Carnet.wrong, study: Carnet.correct])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.caption2)
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Claude Code, sept derniers jours")
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Carnet.ink)
            Text(caption).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func load() {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: "claude.measure.days"),
              let decoded = try? JSONDecoder().decode([ClaudeMeasure.DaySummary].self, from: data) else { return }
        days = decoded
    }

    private func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").map { Int($0) ?? 0 }
        return Calendar.current.date(from: DateComponents(year: parts.first, month: parts.count > 1 ? parts[1] : 1,
                                                          day: parts.count > 2 ? parts[2] : 1)) ?? Date()
    }
}

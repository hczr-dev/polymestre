import SwiftUI
import WidgetKit

/// Les widgets du bureau, les mêmes que ceux de l'iPhone : le chrono, la
/// journée (horaire et échéances), la semaine cours par cours. Ils lisent
/// l'instantané écrit par l'app (`WidgetSnapshot`, partagé avec l'iPhone).
@main
struct PolymestreMacWidgets: WidgetBundle {
    var body: some Widget {
        TimerWidget()
        TodayWidget()
        WeekWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetBridge.read()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && snapshot?.courses == nil ? .preview
                                 : snapshot ?? WidgetSnapshot(updatedAt: .distantPast)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // L'app recharge les widgets à chaque changement ; ici, les instants où
        // ils changent d'eux-mêmes (fin d'un cours, échéance, minuit).
        let snapshot = WidgetBridge.read() ?? WidgetSnapshot(updatedAt: .distantPast)
        let plan = snapshot.timelineDates(from: Date())
        completion(Timeline(entries: plan.dates.map { SnapshotEntry(date: $0, snapshot: snapshot.resolved(at: $0)) },
                            policy: .after(plan.reloadAfter)))
    }
}

extension WidgetSnapshot {
    /// Le temps d'aujourd'hui (sessions et cours suivis), d'après la semaine.
    func todaySeconds(at date: Date = Date()) -> Int {
        guard let week else { return 0 }
        let index = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: week.weekStart),
                                                    to: Calendar.current.startOfDay(for: date)).day ?? -1
        return week.days.indices.contains(index) ? week.days[index] : 0
    }
}

// MARK: - Chrono

struct TimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.timer", provider: SnapshotProvider()) { entry in
            TimerWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chrono")
        .description("La session en cours, ou le temps du jour.")
        .supportedFamilies([.systemSmall])
    }
}

struct TimerWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let timer = snapshot.timer {
                HStack(spacing: 6) {
                    Circle().fill(Color(widgetHex: timer.colorHex)).frame(width: 8, height: 8)
                    Text(timer.label).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let end = timer.breakEndsAt, end > Date() {
                    Text(end, style: .timer)
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                    Text(timer.breakLabel ?? "Pause").font(.caption).foregroundStyle(.secondary)
                } else if timer.isRunning {
                    Text(timer.effectiveStart, style: .timer)
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                    Text("En cours").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Duration.seconds(timer.elapsedWhenPaused).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("En pause").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Aujourd'hui", systemImage: "timer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(WidgetFormat.hours(snapshot.todaySeconds()))
                    .font(.system(size: 30, weight: .light, design: .serif))
                Text("\(WidgetFormat.hours(snapshot.week?.actualSeconds ?? 0)) cette semaine")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Aujourd'hui

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.today", provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Aujourd'hui")
        .description("L'horaire du jour et les prochaines échéances.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var events: [WidgetEvent] {
        (entry.snapshot.schedule ?? [])
            .filter { Calendar.current.isDate($0.start, inSameDayAs: entry.date) && ($0.end ?? $0.start) >= entry.date }
    }

    private var deadlines: [WidgetDeadline] {
        (entry.snapshot.deadlines ?? []).filter { $0.date >= entry.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Aujourd'hui").font(.headline)
                Spacer()
                Text(WidgetFormat.hours(entry.snapshot.todaySeconds(at: entry.date)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let shown = events.prefix(family == .systemLarge ? 6 : 2)
            if shown.isEmpty {
                Text("Rien à l'horaire").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(shown)) { event in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(widgetHex: event.colorHex)).frame(width: 3, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title).font(.callout).lineLimit(1)
                        Text(event.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(event.start, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !deadlines.isEmpty {
                Divider()
                ForEach(Array(deadlines.prefix(family == .systemLarge ? 3 : 1))) { deadline in
                    HStack(spacing: 8) {
                        Text(deadline.courseCode).font(.caption.weight(.semibold))
                            .foregroundStyle(Color(widgetHex: deadline.colorHex))
                        Text(deadline.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(WidgetFormat.countdown(to: deadline.date, from: entry.date))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Semaine

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.week", provider: SnapshotProvider()) { entry in
            WeekWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Semaine")
        .description("Chaque cours : ce qui est fait cette semaine.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WeekWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.week?.number.map { "Semaine \($0)" } ?? "Cette semaine").font(.headline)
                Spacer()
                Text(WidgetFormat.hours(snapshot.week?.actualSeconds ?? 0)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach((snapshot.courses ?? []).prefix(6)) { course in
                HStack(spacing: 8) {
                    Text(course.code).font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                    ProgressView(value: Double(course.done), total: Double(max(course.total, 1)))
                        .tint(Color(widgetHex: course.colorHex))
                    Text("\(course.done)/\(course.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    if let late = course.late, late > 0 {
                        Text("\(late)").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        let now = Date()
        let monday = Calendar(identifier: .iso8601).dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return WidgetSnapshot(
            updatedAt: now,
            courses: [
                WidgetCourse(id: "a", code: "MATH-101", colorHex: "#3E7CB1", done: 3, total: 5, summary: "", late: 0),
                WidgetCourse(id: "b", code: "CS-107", colorHex: "#C0504D", done: 1, total: 4, summary: "", late: 2),
                WidgetCourse(id: "c", code: "PHYS-101", colorHex: "#4F9D69", done: 4, total: 4, summary: "", late: 0)
            ],
            timer: WidgetTimer(label: "MATH-101 · 4.2", colorHex: "#3E7CB1",
                               effectiveStart: now.addingTimeInterval(-1500), isRunning: true, elapsedWhenPaused: 1500),
            week: WidgetWeek(weekStart: monday, number: 4, totalWeeks: 14, actualSeconds: 44_000,
                             expectedSeconds: 60_000, days: [7800, 9000, 5400, 10800, 11000, 0, 0]),
            schedule: [WidgetEvent(id: "e", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200),
                                   title: "Analyse I", subtitle: "MATH-101 · CE1", colorHex: "#3E7CB1")],
            deadlines: [WidgetDeadline(id: "d", title: String(localized: "Série 4 à rendre"), courseCode: "CS-107",
                                       date: now.addingTimeInterval(2 * 86400), colorHex: "#C0504D")])
    }
}

extension Color {
    /// « #5B4FE0 » → couleur (les widgets n'ont pas le thème de l'app).
    init(widgetHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

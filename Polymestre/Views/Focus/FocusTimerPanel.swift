import SwiftUI
import SwiftData

/// Le chrono : sur quoi, combien de temps, et le geste suivant.
///
/// L'écran se lit de haut en bas dans l'ordre où l'on décide : **sur quoi** je
/// travaille (cours, type, cible), **comment** (chrono libre ou Pomodoro), puis
/// le cadran et ses trois boutons. Rien d'autre n'est visible pendant une
/// session : les raccourcis de démarrage disparaissent dès que le chrono tourne,
/// parce qu'ils ne servent qu'avant.
///
/// Tout l'état vit dans `FocusController`. Cette vue ne garde que le **brouillon**
/// d'une session pas encore démarrée — le cours et le type choisis avant d'appuyer
/// sur « Démarrer ».
struct FocusTimerPanel: View {
    @Binding var isAdjusting: Bool
    @Binding var showingPomodoroSettings: Bool
    @Binding var showingShortcutEditor: Bool

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Les sessions et l'horaire d'hier à demain : le total du jour et le
    /// contexte de l'horaire n'ont besoin de rien d'autre.
    @Query private var sessions: [StudySession]
    @Query private var events: [LinkedCalendarEvent]

    init(isAdjusting: Binding<Bool>, showingPomodoroSettings: Binding<Bool>, showingShortcutEditor: Binding<Bool>) {
        _isAdjusting = isAdjusting
        _showingPomodoroSettings = showingPomodoroSettings
        _showingShortcutEditor = showingShortcutEditor
        let since = DateUtils.addDays(-1, to: DateUtils.startOfDay(Date()))
        let until = DateUtils.addDays(3, to: since)
        _sessions = Query(filter: #Predicate<StudySession> { $0.startedAt >= since },
                          sort: \StudySession.startedAt, order: .reverse)
        _events = Query(filter: #Predicate<LinkedCalendarEvent> { $0.startsAt >= since && $0.startsAt < until },
                        sort: \LinkedCalendarEvent.startsAt)
    }

    // Brouillon d'une session pas encore démarrée.
    @State private var draftCourseID: UUID?
    @State private var draftTaskType: TaskType = .exercise
    @State private var draftTargetID: UUID?

    /// Une demande de démarrage qui remplacerait la session en cours.
    @State private var pendingStart: FocusRequest?
    @State private var confirmingDiscard = false
    /// « Session enregistrée · 42 min », affiché quelques secondes après « Terminer ».
    @State private var openedExercise: Exercise?
    @State private var browsing: BrowsedLink?
    /// Pourquoi le chrono s'est ouvert sur ce cours (« Séance d'exercices de
    /// MATH-101 en cours »), tant qu'on n'a rien changé.
    @State private var contextReason: String?
    /// L'énoncé de l'exercice suivi, affiché sous sa carte.
    @AppStorage("focus.showsStatement") private var showsStatement = true

    private var focus: FocusController { app.focus }
    /// Les durées du cycle de la session ouverte, sinon celles réglées ici.
    private var pomodoroSettings: PomodoroSettings { focus.cycle }
    private var trackedCourses: [Course] { courses.filter(\.isTracked) }

    // MARK: Contexte de la session

    private var courseID: UUID? { focus.hasSession ? focus.state?.courseID : draftCourseID }
    private var taskType: TaskType { focus.hasSession ? (focus.state?.taskType ?? .other) : draftTaskType }
    private var targetID: UUID? { focus.hasSession ? focus.state?.targetID : draftTargetID }
    private var course: Course? { courses.first { $0.id == courseID } }

    private var tint: Color { course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }

    private var courseBinding: Binding<UUID?> {
        Binding(get: { courseID }, set: { value in
            if focus.hasSession {
                focus.updateContext(courseID: .some(value), targetID: .some(nil), label: "")
            } else {
                draftCourseID = value
                draftTargetID = nil
                contextReason = nil
            }
        })
    }

    private var taskTypeBinding: Binding<TaskType> {
        Binding(get: { taskType }, set: { value in
            if focus.hasSession {
                focus.updateContext(taskType: value, targetID: .some(nil), label: "")
            } else {
                draftTaskType = value
                draftTargetID = nil
            }
        })
    }

    private var targetBinding: Binding<UUID?> {
        Binding(get: { targetID }, set: { value in
            if focus.hasSession {
                focus.updateContext(targetID: .some(value), label: "")
            } else {
                draftTargetID = value
            }
        })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { focus.state?.note ?? "" }, set: { focus.updateContext(note: $0) })
    }

    private var pomodoroBinding: Binding<Bool> {
        Binding(get: { focus.isPomodoro }, set: { value in
            withAnimation(Motion.snappy) { focus.setPomodoro(value) }
            Haptics.tap()
        })
    }

    // MARK: Corps

    var body: some View {
        VStack(spacing: 22) {
            if let link = focus.state?.groupSession {
                // Une session de groupe : l'horloge est commune, le travail à soi.
                Label("Session ensemble · \(link.groupName)", systemImage: "person.2.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Carnet.ink)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Carnet.sheetRaised, in: Capsule())
            }
            contextSection
            targetCard

            // Le cadran et ses boutons se redessinent chaque seconde tant qu'il y a
            // quelque chose qui s'écoule : un travail compté ou une pause qui
            // décompte. À l'arrêt, rien ne bat.
            TimelineView(.periodic(from: FocusTimerState.tickAnchor(focus.state), by: 1)) { timeline in
                dialSection(now: focus.isRunning || focus.phase().isBreak ? timeline.date : Date())
            }

            if isAdjusting {
                adjustPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // La session qui vient de finir : le temps, par exercice, et de
            // quoi cocher tout de suite. Un message de trois secondes
            // disparaissait avant qu'on ait lu ce qui avait été compté.
            if let note = focus.undoNote {
                // Le résultat de l'annulation, dit un instant : la carte a
                // disparu, il faut voir que la session est bien partie.
                Label(note, systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Carnet.inkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Carnet.sheet, in: Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(Motion.snappy) { focus.undoNote = nil }
                    }
            }
            if !focus.hasSession, let recap = focus.freshRecap {
                SessionRecapCard(totalSeconds: recap.totalSeconds, parts: recap.parts, endedAt: recap.endedAt,
                                 headline: { courseID, taskType, targetID in
                                     Self.headline(courseID: courseID, taskType: taskType, targetID: targetID,
                                                   courses: courses)
                                 },
                                 tint: { id in Carnet.tint(courses.first { $0.id == id }) },
                                 dismiss: { withAnimation(Motion.snappy) { focus.dismissRecap() } },
                                 undo: { withAnimation(Motion.snappy) { focus.undoRecap() } })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if focus.hasSession {
                noteField
            } else {
                shortcutsSection
            }

            if let problem = StudyActivityController.lastError, focus.isRunning {
                // Le chrono fonctionne sans Live Activity, mais on dit pourquoi
                // elle n'apparaît pas : un ornement qui échoue en silence laisse
                // croire à un bug du chrono.
                Label(problem, systemImage: "platter.filled.top.and.arrow.up.iphone")
                    .font(.footnote)
                    .foregroundStyle(Carnet.review)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            todaySummary
        }
        .animation(Motion.snappy, value: focus.hasSession)
        .task {
            if !focus.hasSession {
                draftTaskType = .exercise
            }
            applyRequest()
            applyContext()
            #if DEBUG
            applyDebugLaunch()
            #endif
        }
        .onChange(of: app.router.focusRequest) { _, newValue in
            guard newValue != nil else { return }
            Task { @MainActor in applyRequest() }
        }
        .onChange(of: focus.lastEvent) { _, event in
            // Une fin de bloc ou de pause pendant que l'écran est ouvert : on
            // sort de l'ajustement, qui n'a plus de sens sur une pause.
            if event != nil { isAdjusting = false }
        }
        .confirmationDialog("Remplacer la session en cours ?",
                            isPresented: Binding(get: { pendingStart != nil },
                                                 set: { if !$0 { pendingStart = nil } }),
                            titleVisibility: .visible) {
            if focus.isLocked {
                // Sous verrou, la session ne se coupe pas : elle passe dessus.
                Button("Passer dessus") {
                    if let request = pendingStart {
                        focus.updateContext(courseID: .some(request.courseID), taskType: request.taskType, targetID: .some(request.targetID))
                    }
                    pendingStart = nil
                }
            } else {
                Button("Enregistrer et démarrer") {
                    if let request = pendingStart {
                        finish()
                        begin(request)
                    }
                    pendingStart = nil
                }
                Button("Abandonner et démarrer", role: .destructive) {
                    if let request = pendingStart {
                        focus.discard()
                        begin(request)
                    }
                    pendingStart = nil
                }
            }
            Button("Continuer la session actuelle", role: .cancel) { pendingStart = nil }
        } message: {
            Text("Le chrono tourne déjà sur autre chose. Que faire du temps en cours ?")
        }
        .confirmationDialog("Abandonner cette session ?",
                            isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Abandonner \(DateUtils.durationLabel(seconds: Int(focus.elapsed())))", role: .destructive) {
                focus.discard()
                isAdjusting = false
                Haptics.removed()
            }
            Button("Garder", role: .cancel) {}
        } message: {
            Text("Le temps compté ne sera pas enregistré.")
        }
    }

    // MARK: Sur quoi

    /// « Sur quoi » : trois lignes de papier (cours, travail, cible), chacune un
    /// menu ; puis le mode — chrono libre ou Pomodoro — en deux puces.
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CarnetSheet {
                Menu {
                    Picker("Cours", selection: courseBinding) {
                        Label("Sans cours", systemImage: "circle.dashed").tag(UUID?.none)
                        ForEach(trackedCourses) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                } label: {
                    contextRow(title: "Cours",
                               value: course.map { "\($0.displayCode) · \($0.name)" } ?? String(localized: "Choisir"),
                               tint: course.map { Carnet.tint($0.colorHex) })
                }
                .accessibilityLabel("Cours")
                .accessibilityValue(course?.displayCode ?? "aucun")
                CarnetRule(inset: Carnet.rowInset)
                Menu {
                    Picker("Travail", selection: taskTypeBinding) {
                        ForEach(TaskType.choices) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                } label: {
                    contextRow(title: "Travail", value: taskType.label, tint: nil)
                }
                .accessibilityLabel("Type de travail")
                .accessibilityValue(taskType.label)
                if let course, !targetOptions(for: course).isEmpty {
                    let options = targetOptions(for: course)
                    CarnetRule(inset: Carnet.rowInset)
                    Menu {
                        Picker("Sur quoi ?", selection: targetBinding) {
                            Text("Tout le cours").tag(UUID?.none)
                            // Le prochain à faire en tête ; le reste derrière.
                            Section(taskType.canonical == .correction ? "À corriger" : "À faire") {
                                ForEach(options.filter { !$0.isDone }) { option in
                                    Text(option.label).tag(UUID?.some(option.id))
                                }
                            }
                            Section(taskType.canonical == .correction ? "Le reste" : "Déjà faits") {
                                ForEach(options.filter(\.isDone)) { option in
                                    Text(option.label).tag(UUID?.some(option.id))
                                }
                            }
                        }
                    } label: {
                        contextRow(title: "Sur", value: targetLabel ?? String(localized: "Tout le cours"), tint: nil)
                    }
                    .accessibilityLabel("Cible")
                    .accessibilityValue(targetLabel ?? "tout le cours")
                }
            }

            if let contextReason, !focus.hasSession, draftCourseID != nil {
                Label(contextReason, systemImage: "calendar.badge.clock")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                modeChip("Chrono libre", selected: !focus.isPomodoro) { pomodoroBinding.wrappedValue = false }
                modeChip("Pomodoro", selected: focus.isPomodoro) { pomodoroBinding.wrappedValue = true }
                Spacer(minLength: 0)
                if focus.isPomodoro {
                    Button {
                        showingPomodoroSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(pomodoroSettings.focusMinutes) / \(pomodoroSettings.shortBreakMinutes) min")
                                .font(Carnet.mono(.footnote, weight: .medium))
                            Image(systemName: "slider.horizontal.3").font(.caption)
                        }
                        .foregroundStyle(Carnet.inkSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Réglages Pomodoro : \(pomodoroSettings.focusMinutes) minutes de travail, \(pomodoroSettings.shortBreakMinutes) de pause")
                    .transition(.opacity)
                }
            }

            StudyModeEntry(courseID: courseID, taskType: taskType, targetID: targetID)
        }
    }

    private func contextRow(title: LocalizedStringKey, value: String, tint: Color?) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(width: 64, alignment: .leading)
            if let tint {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
            Text(value)
                .font(.body)
                .foregroundStyle(Carnet.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Carnet.inkTertiary)
        }
        .padding(.horizontal, Carnet.rowInset)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func modeChip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CarnetChip(text: title, isSelected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: L'exercice suivi

    /// Quand le chrono porte sur un exercice : ses sous-questions, et les deux
    /// gestes qu'on fait sans quitter le chrono — cocher la question en cours,
    /// ouvrir l'exercice. Sur un élément de théorie : le marquer vu.
    @ViewBuilder
    private var targetCard: some View {
        let target = FocusController.target(of: targetID, in: course)
        if let exercise = target.exercise {
            let leaves = exercise.leafSubQuestions
            let current = leaves.first { !$0.isDone }
            let siblings = exercise.series?.sortedExercises ?? []
            let position = siblings.firstIndex { $0.id == exercise.id }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 4) {
                    stepButton(systemImage: "chevron.left", label: "Exercice précédent",
                               target: position.flatMap { siblings.indices.contains($0 - 1) ? siblings[$0 - 1] : nil })
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.displayNumber)
                            .font(Carnet.serif(.title3))
                            .foregroundStyle(Carnet.ink)
                        Text([ExerciseStage(exercise).label.capitalizedFirst,
                              position.map { String(localized: "\($0 + 1) sur \(siblings.count)") }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    stepButton(systemImage: "chevron.right", label: "Exercice suivant",
                               target: position.flatMap { siblings.indices.contains($0 + 1) ? siblings[$0 + 1] : nil })
                    Spacer()
                    Button("Ouvrir") { openedExercise = exercise }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                }
                // L'énoncé, exercice par exercice : replié d'un toucher, et
                // l'état est gardé d'une session à l'autre.
                Button {
                    withAnimation(Motion.snappy) { showsStatement.toggle() }
                    Haptics.soft()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(showsStatement ? "Masquer l'énoncé" : "Afficher l'énoncé")
                        Spacer(minLength: 0)
                        Image(systemName: showsStatement ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Carnet.inkSecondary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsStatement {
                    ExerciseStatementView(exercise: exercise, onOpenLink: { browsing = $0 })
                        .id(exercise.id)
                        .transition(.opacity)
                }
                if !leaves.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(leaves) { question in
                            Text(question.displayLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(question.isDone ? Carnet.ground : (question.id == current?.id ? Carnet.ink : Carnet.inkSecondary))
                                .padding(.horizontal, 8)
                                .frame(minWidth: 30, minHeight: 28)
                                .background(question.isDone ? Carnet.ink : Carnet.sheetRaised,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(question.id == current?.id ? Carnet.ink : .clear, lineWidth: 1.2))
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(exercise.subQuestionDoneCount) sous-questions faites sur \(leaves.count)")
                }
                if let current {
                    Button {
                        current.toggle()
                        try? context.save()
                        Haptics.success()
                    } label: {
                        Label("\(current.displayLabel) faite", systemImage: "checkmark")
                    }
                    .buttonStyle(.carnetSecondaryWide)
                } else if !exercise.isDone {
                    Button {
                        exercise.setDone(true)
                        try? context.save()
                        Haptics.success()
                    } label: {
                        Label("Exercice fait", systemImage: "checkmark")
                    }
                    .buttonStyle(.carnetSecondaryWide)
                } else if let next = nextExercise(after: exercise) {
                    Button {
                        targetBinding.wrappedValue = next.id
                        Haptics.tap()
                    } label: {
                        Label("Passer à l'exercice \(next.exerciseNumber)", systemImage: "arrow.right")
                    }
                    .buttonStyle(.carnetSecondaryWide)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .sheet(item: $openedExercise) { ExerciseSheet(exercise: $0) }
            .sheet(item: $browsing) { InAppBrowser(link: $0) }
        } else if let item = target.theoryItem {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MathMarkup.plain(item.title.isEmpty ? item.displayNumber : item.title))
                        .font(Carnet.serif(.title3))
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(2)
                    Text(item.isWatched ? "Vu" : item.kind.label)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Button(item.isWatched ? "Vu ✓" : "Marquer vu") {
                    item.watchedAt = item.isWatched ? nil : Date()
                    try? context.save()
                    Haptics.success()
                }
                .buttonStyle(.carnetSecondary)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    /// ‹ et › : l'exercice voisin dans la série. Le chrono le suit.
    private func stepButton(systemImage: String, label: String, target: Exercise?) -> some View {
        Button {
            guard let target else { return }
            withAnimation(Motion.snappy) { targetBinding.wrappedValue = target.id }
            Haptics.soft()
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: Layout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? Carnet.inkTertiary : Carnet.ink)
        .disabled(target == nil)
        .accessibilityLabel(label)
    }

    private func nextExercise(after exercise: Exercise) -> Exercise? {
        guard let series = exercise.series else { return nil }
        return ExerciseFlow.next(after: exercise, in: series.sortedExercises)
    }

    // MARK: Le cadran

    /// Ce que le cadran montre, selon la phase.
    private struct DialContent {
        var time: String
        var progress: Double?
        var caption: String?
        var tint: Color
    }

    private func dialContent(now: Date) -> DialContent {
        let phase = focus.phase(at: now)
        let elapsed = focus.elapsed(at: now)
        if isAdjusting {
            return DialContent(time: TimerText.clock(elapsed),
                               progress: nil,
                               caption: String(localized: "Temps compté · un tour = 1 h"),
                               tint: tint)
        }
        switch phase {
        case .onBreak(let kind, let start, let end):
            let left = max(0, end.timeIntervalSince(now))
            let total = max(1, end.timeIntervalSince(start))
            return DialContent(time: TimerText.clock(left.rounded(.up)),
                               progress: left / total,
                               caption: String(localized: "\(kind.label) · bloc \(nextBlockNumber) ensuite"),
                               tint: Color.teal)
        case .readyForBlock(let block):
            return DialContent(time: TimerText.clock(pomodoroSettings.blockDuration),
                               progress: 0,
                               caption: String(localized: "Pause finie · bloc \(block) prêt"),
                               tint: tint)
        case .idle:
            if focus.isPomodoro {
                return DialContent(time: TimerText.clock(pomodoroSettings.blockDuration),
                                   progress: 0,
                                   caption: "Bloc 1 · \(pomodoroSettings.focusMinutes) min",
                                   tint: tint)
            }
            return DialContent(time: TimerText.clock(0), progress: 0, caption: "", tint: tint)
        case .working, .paused:
            let paused = phase == .paused
            if focus.isPomodoro {
                let status = focus.pomodoroStatus(at: now)
                return DialContent(time: TimerText.clock(status.remaining.rounded(.up)),
                                   progress: status.progress,
                                   caption: paused
                                       ? String(localized: "En pause · \(TimerText.clock(elapsed)) travaillées")
                                       : "Bloc \(status.blockNumber) · \(TimerText.clock(elapsed)) au total",
                                   tint: tint)
            }
            return DialContent(time: TimerText.clock(elapsed),
                               progress: elapsed.truncatingRemainder(dividingBy: 3600) / 3600,
                               caption: paused ? String(localized: "En pause") : String(localized: "Un tour = une heure"),
                               tint: tint)
        }
    }

    private var nextBlockNumber: Int {
        let accumulated = focus.state?.cycleAccumulated ?? 0
        return Int((accumulated / pomodoroSettings.blockDuration).rounded()) + 1
    }

    private func dialSection(now: Date) -> some View {
        let content = dialContent(now: now)
        let phase = focus.phase(at: now)
        return VStack(spacing: Layout.sectionSpacing) {
            TimerDial(time: content.time,
                      progress: content.progress,
                      tint: content.tint,
                      isRunning: focus.isRunning || phase.isBreak,
                      caption: content.caption,
                      // Le contexte est déjà dans les pastilles au-dessus : le
                      // répéter dans le cadran n'était que du bruit.
                      context: nil,
                      elapsed: focus.elapsed(at: now),
                      isAdjusting: isAdjusting,
                      onAdjust: { focus.adjust(by: $0) },
                      onSet: { total in
                          focus.setElapsed(total)
                          Haptics.success()
                      })
                .frame(maxWidth: .infinity)

            if focus.isPomodoro {
                PomodoroDots(total: max(2, pomodoroSettings.longBreakEvery),
                             completed: completedInCycle,
                             isOnBreak: phase.isBreak,
                             tint: content.tint)
            }

            controls(phase: phase)
        }
    }

    /// Blocs terminés dans le cycle en cours (jusqu'à la pause longue).
    private var completedInCycle: Int {
        let every = max(2, pomodoroSettings.longBreakEvery)
        let done = Int(((focus.state?.cycleAccumulated ?? 0) / pomodoroSettings.blockDuration).rounded(.down))
        guard done > 0 else { return 0 }
        let inCycle = done % every
        // Pile sur la pause longue : le cycle est plein, pas vide.
        return inCycle == 0 ? every : inCycle
    }

    // MARK: Boutons

    @ViewBuilder
    private func controls(phase: FocusPhase) -> some View {
        HStack(alignment: .top, spacing: Layout.sectionSpacing) {
            // À gauche : l'action rare. Abandonner, ou allonger la pause.
            if phase.isBreak {
                TimerSideButton(title: "+5 min", icon: "plus") {
                    focus.extendBreak(minutes: 5)
                    Haptics.tap()
                }
            } else {
                TimerSideButton(title: "Abandonner", icon: "xmark", role: .destructive,
                                isEnabled: focus.hasSession && !focus.isLocked) {
                    confirmingDiscard = true
                }
                // Au repos, rien à abandonner : le bouton s'efface (sa place reste,
                // pour que « Démarrer » ne bouge pas).
                .opacity(focus.hasSession ? 1 : 0)
            }

            primaryButton(phase: phase)

            // À droite : conclure.
            // Sous verrou, la session se termine dans l'écran du mode étude
            // (sortie d'urgence), pas d'ici.
            TimerSideButton(title: "Terminer", icon: "checkmark",
                            isEnabled: focus.hasSession && focus.elapsed() >= 1 && !focus.isLocked) {
                finish()
            }
            .opacity(focus.hasSession ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.snappy, value: focus.hasSession)
    }

    @ViewBuilder
    private func primaryButton(phase: FocusPhase) -> some View {
        switch phase {
        case .onBreak:
            TimerPrimaryButton(title: "Reprendre", icon: "forward.fill", tint: .teal) {
                focus.skipBreak()
            }
        case .readyForBlock(let block):
            TimerPrimaryButton(title: "Bloc \(block)", icon: "play.fill", tint: tint) {
                focus.resume()
            }
        case .working:
            TimerPrimaryButton(title: "Pause", icon: "pause.fill", tint: tint) {
                focus.pause()
            }
        case .paused:
            TimerPrimaryButton(title: "Reprendre", icon: "play.fill", tint: tint) {
                focus.resume()
            }
        case .idle:
            TimerPrimaryButton(title: "Démarrer", icon: "play.fill", tint: tint) {
                focus.start(courseID: draftCourseID,
                            taskType: draftTaskType,
                            targetID: draftTargetID,
                            pomodoro: focus.isPomodoro)
            }
        }
    }

    // MARK: Ajustement

    private var adjustPanel: some View {
        VStack(alignment: .leading, spacing: Layout.block) {
            HStack {
                Text("Corriger le temps compté")
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                Spacer()
                Button("OK") {
                    withAnimation(Motion.snappy) { isAdjusting = false }
                    Haptics.tap()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Carnet.ink)
            }
            // Trois façons, du plus grossier au plus fin : les boutons pour un
            // rattrapage courant, le glissement pour ajuster à la minute, le
            // champ pour une valeur exacte.
            HStack(spacing: Layout.control) {
                adjustButton("− 5 min", delta: -300)
                adjustButton("+ 5 min", delta: 300)
                adjustButton("+ 15 min", delta: 900)
            }
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private func adjustButton(_ title: String, delta: TimeInterval) -> some View {
        Button {
            focus.adjust(by: delta)
            Haptics.tap()
        } label: {
            Text(ui: title)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.carnetSecondaryWide)
    }

    // MARK: Note

    private var noteField: some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: "text.alignleft")
                .font(.subheadline)
                .foregroundStyle(Carnet.inkSecondary)
                .padding(.top, 2)
            TextField("Ajouter une note à la session…", text: noteBinding, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    // MARK: Raccourcis

    private var effectiveShortcuts: [FocusShortcut] {
        let stored = FocusShortcutDefaults.sanitize(app.settings.focusShortcuts,
                                                    knownCourses: Set(courses.map(\.displayCode)))
        if !stored.isEmpty { return stored }
        return FocusShortcutDefaults.make(from: trackedCourses.map(\.displayCode))
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        let shortcuts = effectiveShortcuts
        if !shortcuts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle(String(localized: "Démarrer en un toucher")) {
                    Button("Modifier") { showingShortcutEditor = true }
                }
                CarnetSheet {
                    ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        shortcutRow(shortcut)
                        if index < shortcuts.count - 1 { CarnetRule() }
                    }
                }
            }
        }
    }

    private func shortcutRow(_ shortcut: FocusShortcut) -> some View {
        let course = courses.first { $0.displayCode == shortcut.courseCode }
        let tint = course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink
        return Button {
            Haptics.tap()
            startOrConfirm(FocusRequest(courseID: course?.id,
                                 courseCode: shortcut.courseCode,
                                 taskType: shortcut.taskType,
                                 label: ""))
        } label: {
            CarnetRow(icon: shortcut.icon, tint: tint, title: shortcut.title, subtitle: shortcut.subtitle) {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Démarrer \(shortcut.title), \(shortcut.subtitle)")
    }

    // MARK: Aujourd'hui

    @ViewBuilder
    private var todaySummary: some View {
        let start = DateUtils.startOfDay(Date())
        let today = sessions.filter { $0.startedAt >= start }
        // Compté comme partout : sessions et cours suivis (`StudyTime`).
        let seconds = StudyTime.today(in: context)
        if seconds > 0 {
            HStack(spacing: Layout.snug) {
                Image(systemName: "sum")
                    .font(.caption)
                Text("Aujourd'hui : \(DateUtils.hoursLabel(seconds: seconds)) · \(Plural.count(today.count, "\(today.count) session", "\(today.count) sessions"))")
                    .font(.footnote)
                    .monospacedDigit()
            }
            .foregroundStyle(Carnet.inkSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Actions

    private func finish() {
        guard focus.finish() != nil else { return }
        isAdjusting = false
        Haptics.success()
    }

    /// Ce qu'on a travaillé, en mots : l'exercice, la théorie, ou le cours.
    static func headline(courseID: UUID?, taskType: TaskType, targetID: UUID?, courses: [Course]) -> String {
        guard let course = courses.first(where: { $0.id == courseID }) else { return String(localized: "Sans cours") }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return exercise.title.isEmpty ? exercise.displayNumber : "\(exercise.displayNumber) · \(exercise.title)"
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return item.title.isEmpty ? item.displayNumber : "\(item.displayNumber) · \(item.title)"
        }
        return taskType.label
    }

    /// Une demande venue d'ailleurs (dock, « Démarrer » d'une tâche, Siri).
    ///
    /// Une demande qui ne démarre pas (la bulle) ne fait que **préremplir** le
    /// brouillon — et ne touche à rien si une session tourne déjà : ouvrir
    /// Focus ne doit jamais déplacer le temps d'une session en cours.
    /// Sans demande explicite, le chrono s'ouvre sur ce que l'horaire dit du
    /// moment (`FocusContext`) : la séance d'exercices en cours et son
    /// prochain exercice, la théorie du cours qui vient de finir.
    private func applyContext() {
        guard !focus.hasSession, draftCourseID == nil else { return }
        let now = Date()
        let tracked = Set(trackedCourses.map(\.id))
        let slots = events
            .filter { $0.startsAt < now.addingTimeInterval(FocusContext.leadTime) && $0.endsAt > now.addingTimeInterval(-FocusContext.afterLecture) }
            .compactMap { event -> FocusContext.Slot? in
                guard let course = event.course, tracked.contains(course.id) else { return nil }
                return FocusContext.Slot(courseID: course.id, courseCode: course.displayCode, kind: event.kind,
                                         start: event.startsAt, end: event.endsAt)
            }
        guard let suggestion = FocusContext.suggestion(now: now, slots: slots),
              let course = courses.first(where: { $0.id == suggestion.courseID }) else { return }
        draftCourseID = course.id
        draftTaskType = suggestion.taskType
        draftTargetID = suggestion.taskType == .exercise
            ? FocusTargets.exercises(of: course.series, for: .exercise).upNext.first?.id
            : FocusTargets.theory(course.sortedTheoryItems).upNext.first?.id
        contextReason = suggestion.reason
    }

    private func applyRequest() {
        guard let pending = app.router.consumeFocusRequest() else { return }
        guard pending.autoStart else {
            guard !focus.hasSession else { return }
            let resolved = resolve(pending)
            draftCourseID = resolved.courseID
            draftTaskType = resolved.taskType
            draftTargetID = resolved.targetID
            return
        }
        startOrConfirm(pending)
    }

    /// Démarre tout de suite, ou demande quoi faire de la session en cours.
    private func startOrConfirm(_ request: FocusRequest) {
        let resolved = resolve(request)
        if focus.hasSession,
           resolved.courseID != focus.state?.courseID || resolved.taskType != focus.state?.taskType {
            pendingStart = resolved
            return
        }
        begin(resolved)
    }

    /// Même cours, même type, autre exercice : le chrono **continue** et le
    /// temps déjà compté reste à l'exercice précédent (voir `switchContext`).
    private func begin(_ request: FocusRequest) {
        draftCourseID = request.courseID
        draftTaskType = request.taskType
        draftTargetID = request.targetID
        focus.start(courseID: request.courseID,
                    taskType: request.taskType,
                    targetID: request.targetID,
                    label: request.label)
    }

    /// Retrouve le cours par son code quand la demande n'a pas d'identifiant.
    private func resolve(_ request: FocusRequest) -> FocusRequest {
        guard request.courseID == nil, !request.courseCode.isEmpty else { return request }
        var resolved = request
        resolved.courseID = courses.first {
            $0.code.caseInsensitiveCompare(request.courseCode) == .orderedSame
                || $0.displayCode.caseInsensitiveCompare(request.courseCode) == .orderedSame
        }?.id
        return resolved
    }

    #if DEBUG
    /// `-course CS-250 -pomodoro -timerSeconds 600` : `xcrun simctl` ne sait pas
    /// taper, c'est le seul moyen de capturer un chrono en marche.
    private func applyDebugLaunch() {
        if let code = PreviewLaunch.string(PreviewLaunch.courseFlag),
           let match = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            draftCourseID = match.id
        }
        if PreviewLaunch.isSet(PreviewLaunch.pomodoroFlag), !focus.hasSession {
            focus.setPomodoro(true)
        }
        if let seconds = PreviewLaunch.int(PreviewLaunch.timerSecondsFlag), !focus.hasSession {
            focus.start(courseID: draftCourseID, taskType: draftTaskType,
                        pomodoro: PreviewLaunch.isSet(PreviewLaunch.pomodoroFlag))
            focus.setElapsed(TimeInterval(seconds))
        }
    }
    #endif

    // MARK: Cibles

    /// Une cible proposée au chrono : un exercice ou un élément de théorie.
    private struct TargetOption: Identifiable {
        let id: UUID
        let label: String
        /// Fait (ou vu) : proposé après ce qui reste à faire.
        var isDone = false
    }

    /// Ce qu'on peut préciser pour ce cours et ce type de travail : les
    /// exercices pour un travail d'exercice ou de correction, la théorie pour le
    /// reste — et rien pour un type qui ne s'y prête pas. **Le prochain à
    /// faire d'abord** (`FocusTargets`) : l'ordre alphabétique mettait en tête
    /// des exercices faits depuis des semaines.
    private func targetOptions(for course: Course) -> [TargetOption] {
        switch taskType {
        case .exercise, .correction:
            let ordered = FocusTargets.exercises(of: course.series, for: taskType)
            return ordered.upNext.map { TargetOption(id: $0.id, label: Self.label(for: $0)) }
                + ordered.done.map { TargetOption(id: $0.id, label: Self.label(for: $0), isDone: true) }
        case .video, .theory, .summary:
            let ordered = FocusTargets.theory(course.sortedTheoryItems)
            return ordered.upNext.map { TargetOption(id: $0.id, label: $0.displayNumber) }
                + ordered.done.map { TargetOption(id: $0.id, label: $0.displayNumber, isDone: true) }
        default:
            return []
        }
    }

    /// « Ex. 3.2 · Suites bornées · 1/3 » : de quoi le reconnaître.
    private static func label(for exercise: Exercise) -> String {
        var parts = ["Ex. \(exercise.exerciseNumber)"]
        let title = MathMarkup.plain(exercise.title)
        if !title.isEmpty { parts.append(String(title.prefix(32))) }
        if exercise.isBonus { parts.append("bonus") }
        if case .inProgress(let done, let total) = ExerciseStage(exercise) { parts.append("\(done)/\(total)") }
        if ExerciseStage(exercise) == .redo { parts.append(String(localized: "à refaire")) }
        return parts.joined(separator: " · ")
    }

    private var targetLabel: String? {
        guard let course, let targetID else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return "Ex. \(exercise.exerciseNumber)"
        }
        return course.theoryItems.first { $0.id == targetID }?.displayNumber
    }
}

/// Les blocs du cycle, en pastilles : combien sont faits avant la pause longue.
///
/// Le Pomodoro ne se lisait qu'en texte (« Bloc 3 »). Des pastilles disent en
/// un regard où l'on en est du cycle, et quand viendra la vraie pause.
struct PomodoroDots: View {
    var total: Int
    var completed: Int
    var isOnBreak: Bool
    var tint: Color

    var body: some View {
        HStack(spacing: Layout.inline) {
            ForEach(0..<total, id: \.self) { index in
                let done = index < completed
                let current = index == completed && !isOnBreak
                Capsule()
                    .fill(done ? Carnet.ink : Carnet.rule)
                    .frame(width: current ? 22 : 8, height: 8)
                    .overlay {
                        if current {
                            Capsule().strokeBorder(Carnet.ink, lineWidth: 1.5)
                        }
                    }
            }
        }
        .animation(Motion.snappy, value: completed)
        .animation(Motion.snappy, value: isOnBreak)
        .accessibilityElement()
        .accessibilityLabel("\(min(completed, total)) blocs sur \(total) avant la pause longue")
    }
}

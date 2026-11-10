import AppKit

/// Les captures de vérification (`-snapshot`) : l'app tourne sans **rien**
/// montrer — ni icône dans le Dock, ni barre des menus, ni pilule du chrono,
/// ni raccourci global, ni fenêtre à l'écran. La seule fenêtre est celle du
/// mode étude, transparente et hors de l'écran, d'où l'image est tirée.
/// Toujours éteint en Release.
enum HeadlessCapture {
    #if DEBUG
    static let active = CommandLine.arguments.contains("-snapshot")
    #else
    static let active = false
    #endif

    // MARK: Préférences

    /// Les préférences telles qu'elles étaient avant la capture.
    nonisolated(unsafe) private static var savedPreferences: [String: Any]?

    /// Une capture ne laisse **rien** dans les vraies préférences, et une capture
    /// sur la base d'essai n'en montre rien de personnel. À appeler avant que
    /// quoi que ce soit ne lise un réglage (l'`init` de l'app).
    ///
    /// `-memoryStore` isole la base, pas les préférences : la page des réglages
    /// capturée changeait la page ouverte et les sections « Avancé » de la vraie
    /// app, et « Aujourd'hui » sur le cours d'essai affichait les vraies
    /// nouveautés des cours, le vrai prénom et la vraie adresse de l'école.
    static func isolatePreferences() {
        guard active, let domain = Bundle.main.bundleIdentifier else { return }
        savedPreferences = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        if CommandLine.arguments.contains("-memoryStore") {
            override(["settings.displayName": "", "mac.epflEmail": "", "settings.contentRefreshNews": ""])
        }
        atexit { HeadlessCapture.restorePreferences() }
    }

    /// Un réglage **pour cette capture seulement** : posé dans le domaine des
    /// arguments, lu avant tout le reste et jamais écrit sur le disque.
    static func override(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.merge(values) { _, new in new }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// À la sortie : ce que la capture a écrit au passage (date de relecture,
    /// réglage retouché par un `didSet`…) reprend sa valeur d'avant.
    private static func restorePreferences() {
        guard let saved = savedPreferences, let domain = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        for key in Set(current.keys).union(saved.keys) {
            let before = saved[key] as? NSObject, after = current[key] as? NSObject
            if before == after { continue }
            if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        CFPreferencesAppSynchronize(domain as CFString)
    }

    /// Au plus tôt (`applicationWillFinishLaunching`), avant que le Dock ne
    /// montre l'app ; puis on range toute fenêtre qui voudrait apparaître.
    @MainActor
    static func begin() {
        guard active else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            while true {
                if NSApp.activationPolicy() != .prohibited { NSApp.setActivationPolicy(.prohibited) }
                for window in NSApp.windows where window.isVisible && !(window is StudyWindow) {
                    window.orderOut(nil)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

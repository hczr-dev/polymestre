import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Tient le Mac (et, si demandé, l'écran) éveillé pendant le mode étude, par
/// une assertion d'énergie IOKit — visible dans le Moniteur d'activité
/// (« Empêche la suspension ») et `pmset -g assertions`.
///
/// Rien ne tourne en boucle : on réévalue à chaque changement du chrono et
/// quand macOS annonce un changement d'alimentation (secteur, batterie, mode
/// économie d'énergie). L'assertion porte sa propre échéance (la fin de la
/// session, plus une marge) : même si l'app plante ou se fige, le Mac finit
/// par dormir. La décision elle-même est dans `KeepAwakePolicy`.
@MainActor
final class MacKeepAwake {
    static let shared = MacKeepAwake()

    private var assertion: IOPMAssertionID = 0
    private var held: (hold: KeepAwakePolicy.Hold, expiry: Date)?
    private var lease: Task<Void, Never>?
    private var powerSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    /// La dernière demande, rejouée quand l'alimentation change.
    private var last: (mode: KeepAwakePolicy.Mode, studying: Bool, running: Bool, onBreak: Bool, until: Date?)?

    private init() {}

    func update(mode: KeepAwakePolicy.Mode, studying: Bool, running: Bool, onBreak: Bool, until: Date?) {
        last = (mode, studying, running, onBreak, until)
        let wanted = KeepAwakePolicy.hold(mode: mode, studying: studying, running: running, onBreak: onBreak,
                                          power: Self.power())
        // On n'écoute l'alimentation que tant qu'elle peut changer la décision.
        observePower(mode == .display && studying)
        guard let wanted else { return release() }
        let expiry = KeepAwakePolicy.expiry(until: until)
        // Même tenue, même échéance (à la minute) : rien à refaire.
        if let held, held.hold == wanted, abs(held.expiry.timeIntervalSince(expiry)) < 60 { return }
        acquire(wanted, expiry: expiry)
    }

    // MARK: Assertion

    private func acquire(_ hold: KeepAwakePolicy.Hold, expiry: Date) {
        let previous = assertion
        let type = hold == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let timeout = max(60, expiry.timeIntervalSinceNow)
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: type,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            // En ASCII : `pmset -g assertions` écorche les accents.
            kIOPMAssertionNameKey: "Polymestre study mode",
            kIOPMAssertionDetailsKey: hold == .display ? String(localized: "Le Mac et l'écran restent allumés pendant la session.")
                                                       : String(localized: "Le Mac reste éveillé pendant la session ; l'écran peut s'éteindre."),
            kIOPMAssertionTimeoutKey: timeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var created: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &created) == kIOReturnSuccess else {
            AppLog.record(.warning, "veille", "assertion d'énergie refusée")
            return
        }
        // La nouvelle d'abord, l'ancienne ensuite : pas un instant sans tenue.
        if previous != 0 { IOPMAssertionRelease(previous) }
        assertion = created
        held = (hold, expiry)
        scheduleRenewal(before: expiry)
    }

    private func release() {
        lease?.cancel()
        lease = nil
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        held = nil
    }

    /// Une session sans fin : un seul réveil, juste avant l'échéance, pour
    /// renouveler — et non une vérification régulière.
    private func scheduleRenewal(before expiry: Date) {
        lease?.cancel()
        lease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(30, expiry.timeIntervalSinceNow - 60)))
            guard !Task.isCancelled, let self else { return }
            self.held = nil
            self.replay()
        }
    }

    private func replay() {
        guard let last else { return }
        update(mode: last.mode, studying: last.studying, running: last.running, onBreak: last.onBreak, until: last.until)
    }

    // MARK: Alimentation

    private func observePower(_ wanted: Bool) {
        if wanted, powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let keeper = Unmanaged<MacKeepAwake>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { keeper.replay() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
            lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                                      object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.replay() }
            }
        } else if !wanted, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
            if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
            lowPowerObserver = nil
        }
    }

    private static func power() -> KeepAwakePolicy.Power { PowerReader.keepAwakePower() }
}

import SwiftUI

/// « Moi » : la feuille ouverte par l'avatar d'« Aujourd'hui » — qui (le prénom
/// se modifie sur place), le bilan, et les réglages directement.
///
/// C'était une page à elle : une carte « Profil », la semaine en trois chiffres
/// qu'« Aujourd'hui » venait de montrer, puis deux lignes — « Bilan » et
/// « Réglages ». La page restait presque vide, et les réglages étaient à deux
/// touchers de l'avatar. Elle est maintenant la page des réglages elle-même,
/// avec le bilan en première ligne.
struct MeView: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ProfileView(isEmbedded: true, showsSummaryLink: true)
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(action: onClose) { Image(systemName: "xmark") }
                                .accessibilityLabel("Fermer")
                        }
                    }
                }
        }
    }
}

// Synchronisation entre appareils — le compte Supabase et l'opt-in, pendant
// Windows de `SyncSettings` (Mac). Off par défaut, comme le plan Apple : se
// connecter n'envoie rien, et tout se débraye. Les données restent lisibles
// par leur seul auteur (RLS côté serveur).

import { useEffect, useState } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import { Button, Section, Card, Switch } from "../../kit.tsx";
import { SettingRow } from "./controls.tsx";
import { syncService, type SyncStatus } from "../../../services/syncService.ts";
import { EncryptionPanel } from "./SyncEncryption.tsx";
import { SyncAccount } from "./SyncAccount.tsx";

/** « lun. 28 sept. à 08:15 » — l'heure de la dernière passe. */
function syncMoment(iso: string): string {
  const date = new Date(iso);
  return `${DateUtils.shortDay(date)} à ${DateUtils.time(date)}`;
}

/** Le compte-rendu de la dernière passe : envoyées, reçues, gardées, rattrapées. */
function reportLine(status: SyncStatus): string {
  const r = status.lastReport;
  if (!r) return "—";
  const parts = [
    `${r.pushed} ${Plural.count(r.pushed, "envoyée", "envoyées")}`,
    `${r.pulled} ${Plural.count(r.pulled, "reçue", "reçues")}`,
    `${r.keptLocal} ${Plural.count(r.keptLocal, "gardée ici", "gardées ici")}`,
    `${r.orphans} ${Plural.count(r.orphans, "rattrapée", "rattrapées")}`,
  ];
  return parts.join(" · ");
}

export function SyncSection() {
  const { reload } = useData();
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** Le geste en vol, pour désactiver les boutons le temps qu'il finisse. */
  const [busy, setBusy] = useState<"sync" | "google" | null>(null);
  const [providers, setProviders] = useState<string[]>([]);

  useEffect(() => {
    // L'état vient du service (asynchrone : la session se relit), et chaque
    // notification — connexion, drapeau, passe — le rafraîchit.
    const refresh = () => { void syncService.status().then(setStatus); };
    refresh();
    return syncService.subscribe(refresh);
  }, []);

  const signedIn = status?.signedIn ?? false;
  useEffect(() => {
    if (!signedIn) { setProviders([]); return; }
    void syncService.providers().then(setProviders);
  }, [signedIn]);

  const google = async (link: boolean) => {
    if (busy !== null) return;
    setBusy("google");
    setError(null);
    try {
      if (link) await syncService.linkGoogle();
      else await syncService.signInWithGoogle();
      setProviders(await syncService.providers());
    } catch (e) {
      setError(e instanceof Error ? e.message : "La connexion Google a échoué.");
    } finally {
      setBusy(null);
    }
  };

  const signOut = async () => {
    if (busy !== null) return;
    setBusy("sync");
    try {
      await syncService.signOut();
    } finally {
      setBusy(null);
    }
  };

  const syncNow = async () => {
    if (busy !== null) return;
    setBusy("sync");
    try {
      const report = await syncService.syncNow();
      // Une lecture a pu changer le graphe sous l'écran : on le relit.
      if (report !== null) await reload();
    } finally {
      setBusy(null);
    }
  };

  // Le temps du premier rendu, rien ne s'affiche : l'état arrive tout de suite.
  if (status === null) return null;

  if (!status.configured) {
    return (
      <Section title="Synchronisation">
        <Card>
          <p className="settings-empty">Ce build n'embarque pas de projet Supabase.</p>
          <p className="settings-hint">
            Il manque <code className="mono">VITE_SUPABASE_URL</code> ou{" "}
            <code className="mono">VITE_SUPABASE_ANON_KEY</code> à la compilation.
            Toutes tes données restent sur cet appareil — rien d'autre ne change.
          </p>
        </Card>
        <p className="settings-footnote">
          Les valeurs se posent dans <code className="mono">windows/.env</code> (voir
          Support/SUPABASE.md et .env.example), puis on relance le build.
        </p>
      </Section>
    );
  }

  if (!status.signedIn) {
    return (
      <Section title="Compte et synchronisation">
        <Card>
          <SyncAccount />
        </Card>
        <p className="settings-footnote">
          Un compte n'envoie rien tout seul : la synchronisation s'allume ensuite, ici, et elle s'éteint quand tu veux.
        </p>
      </Section>
    );
  }

  return (
    <Section title="Synchronisation">
      <Card>
        <SettingRow label="Compte" hint="Le compte Polymestre relié à cet appareil.">
          <span className="settings-value">{status.email ?? "—"}</span>
        </SettingRow>

        <EncryptionPanel status={status} />

        <SettingRow
          label="Synchroniser mes données entre mes appareils"
          hint="Éteint : rien ne quitte cet appareil. Le premier allumage envoie ce qui est ici, chiffré, puis les changements suivent."
        >
          <Switch
            checked={status.enabled}
            ariaLabel="Synchroniser mes données entre mes appareils"
            disabled={status.encryption !== "ready" && !status.enabled}
            onChange={(value) => syncService.setEnabled(value)}
          />
        </SettingRow>

        <SettingRow label="Dernière synchronisation">
          <span className="settings-value">
            {status.syncing
              ? `en cours… ${status.syncing.pulled} reçues, ${status.syncing.pushed} envoyées`
              : status.lastSyncAt ? syncMoment(status.lastSyncAt) : "jamais"}
          </span>
        </SettingRow>

        <SettingRow label="Dernier rapport" hint="Lignes envoyées, reçues, gardées ici, rattrapées.">
          <span className="settings-value mono" style={{ fontWeight: 600 }}>{reportLine(status)}</span>
        </SettingRow>

        {!providers.includes("google") && (
          <SettingRow label="Compte Google" hint="Lie ton compte Google pour te connecter avec lui, sans mot de passe.">
            <Button disabled={busy !== null} onClick={() => void google(true)}>
              {busy === "google" ? "En attente du navigateur…" : "Lier un compte Google"}
            </Button>
            {busy === "google" && (
              <Button onClick={() => syncService.cancelOAuth()}>Annuler</Button>
            )}
          </SettingRow>
        )}

        {error && (
          <p className="settings-error" role="alert">{error}</p>
        )}
        {status.lastError && (
          <p className="settings-error" role="alert">{status.lastError}</p>
        )}

        <div className="settings-actions">
          <Button icon="rectangle.portrait.and.arrow.right" disabled={busy !== null} onClick={() => void signOut()}>
            Se déconnecter
          </Button>
          <Button variant="primary" icon="arrow.clockwise"
            disabled={!status.enabled || busy !== null} onClick={() => void syncNow()}>
            {busy === "sync" ? "Synchronisation…" : "Synchroniser maintenant"}
          </Button>
        </div>
      </Card>
      <p className="settings-footnote">
        Une passe toutes les cinq minutes tant que c'est allumé, et trois secondes après chaque
        changement. Le premier allumage envoie l'existant.
      </p>
    </Section>
  );
}

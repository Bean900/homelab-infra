# Power-Management: HP 24/7, nipogi nur bei Bedarf

## Überblick

```
                     24/7                                    nur bei Bedarf
          ┌──────────────────────────┐                ┌───────────────────────────┐
          │ HP260G4  (192.168.178.101)│                │ nipogi (192.168.178.102)  │
          │ Control-Plane + Worker    │◄──── LAN ─────►│ reiner Worker             │
          │ Label homelab.lab/role=   │                │ Label homelab.lab/role=   │
          │       always-on           │                │       burst               │
          │                           │                │ Taint homelab.lab/burst   │
          │ etcd, API-Server          │                │       =true:NoSchedule    │
          │ ArgoCD, Traefik, AdGuard  │                │                           │
          │ Longhorn-Disk (alle Daten)│                │ keine Longhorn-Disk       │
          │ Home Assistant            │ schaltet       │ Minecraft (bevorzugt)     │
          │ Power-Manager ────────────┼──Steckdose────►│ + weitere Burst-Workloads │
          │ kube-vip (VIP .100)       │  (Strom AN/AUS)│                           │
          └──────────────────────────┘                └───────────────────────────┘
```

| Anforderung | Umsetzung |
|---|---|
| 1. Nur der HP läuft 24/7 und betreibt Pods + Control-Plane | nipogi ist **Worker** (kein etcd/API-Server mehr). Alle Pods ohne Opt-in laufen wegen des Taints automatisch nur auf dem HP. |
| 2. Bei steigender Last nipogi starten, übernimmt performance-intensive Tasks | Power-Manager schaltet per Home Assistant die Steckdose ein; nach dem Boot werden Burst-Pods (z. B. Minecraft) automatisch auf nipogi verschoben. |
| 3. Bei längerer niedriger Last nipogi herunterfahren, alles läuft auf dem HP | cordon → drain → `talosctl shutdown` → Steckdose aus. Pods landen automatisch wieder auf dem HP. |
| 4. Home Assistant als Service, Steckdose trennt nach dem Shutdown den Strom | `applications/smart-home/home-assistant`, wird vom Power-Manager über die REST-API gesteuert. |

### Warum nipogi **kein** Control-Plane mehr sein darf
Vorher waren beide Nodes Control-Plane = 2 etcd-Mitglieder. Bei 2 Mitgliedern braucht etcd beide für das Quorum – sobald nipogi
ausgeschaltet wird, wäre das ganze Cluster (API-Server) tot. Mit einem einzigen Control-Plane (HP) gibt es kein Quorum-Problem.

## Scheduling-Regeln

* **Standard:** Ein Pod ohne Toleration läuft nur auf dem HP (nipogi hat den Taint `homelab.lab/burst=true:NoSchedule`).
  Neue Dienste sind also automatisch „sicher“ (laufen auf dem Always-on-Node).
* **Burst-Workload (Opt-in):** Ein Workload darf auf nipogi, wenn sein Pod-Template folgendes enthält
  (Beispiel: `applications/games/minecraft/statefulset.yaml`):

```yaml
metadata:
  labels:
    homelab.lab/workload-class: burst        # Power-Manager kennt den Pod (Migration, Scale-Up)
spec:
  tolerations:
    - {key: homelab.lab/burst, operator: Equal, value: "true", effect: NoSchedule}
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:   # "preferred": fällt auf den HP zurück, wenn nipogi aus ist
        - weight: 100
          preference:
            matchExpressions:
              - {key: homelab.lab/role, operator: In, values: [burst]}
```
* **Müssen garantiert auf dem HP laufen** (AdGuard, kube-vip, Home Assistant, Power-Manager): `nodeSelector: homelab.lab/role: always-on`.
* **DaemonSets** (Flannel, kube-proxy, Longhorn-Manager/-CSI) tolerieren den Taint und laufen auch auf nipogi.

## Ablauf

### Hochfahren (nipogi aus)
Der Power-Manager (Deployment auf dem HP, alle 30 s) startet nipogi, wenn **eine** Bedingung erfüllt ist:

1. Ein Burst-Pod ist seit ≥ 90 s `Unschedulable` (z. B. zu wenig RAM auf dem HP), **oder**
2. HP-CPU im Schnitt ≥ 75 % **oder** HP-RAM im Schnitt ≥ 85 % über 3 Minuten **und** es läuft ein Burst-Workload auf dem HP
   (nur dann bringt mehr Kapazität etwas), **oder**
3. Node-Annotation `power-manager.homelab.lab/mode=on` (`make burst-on`).

Dann: Steckdose **aus → 8 s → an** (sicherer „Strom kommt wieder“-Impuls) → nipogi bootet (BIOS: *Power On after AC loss*) →
Node ist `Ready` → Longhorn-Node ist bereit → Burst-Pods werden vom HP *evicted* und vom Scheduler auf nipogi neu gestartet.
Bootet der Node nicht innerhalb von 10 min, wird die Steckdose aus- und später erneut eingeschaltet.

### Herunterfahren (nipogi an)
Wenn die CPU-Last von nipogi **20 Minuten im Schnitt < 15 %** liegt (und nipogi ≥ 15 min läuft), prüft der Manager Schutzbedingungen:

* keine Minecraft-Spieler online (Server-List-Ping),
* der HP kann die Last tragen (projizierte CPU < 60 %, RAM < 75 %),
* die Requests der umziehenden Pods passen auf den HP (sonst gäbe es sofort wieder ein Scale-Up → Flapping).

Dann: cordon → Pods per Eviction drainen (PDBs werden respektiert, Minecraft speichert die Welt) → warten bis Longhorn-Volumes
detached sind → `talosctl shutdown` → warten bis die Talos-API weg ist + 60 s → **Home-Assistant-Steckdose aus** → nipogi ist komplett stromlos.
Schlägt irgendetwas fehl, wird der Node wieder uncordoned und es gibt nach 30 min einen neuen Versuch.

Der Manager übersteht Neustarts: Ein unterbrochenes Herunterfahren wird fortgesetzt (Node-Annotation `power-manager.homelab.lab/draining-since`),
ein gebooteter Node wird automatisch uncordoned.

### Parameter
Alle in `platform/automation/power-manager/config.env` (Änderung per Git → ArgoCD rollt den Pod neu aus):

| Variable | Default | Bedeutung |
|---|---|---|
| `UP_CPU_PCT` / `UP_MEM_PCT` | 75 / 85 | HP-Schwellen fürs Hochfahren |
| `UP_SUSTAIN_SECONDS` | 180 | Mittelungsfenster Hochfahren |
| `DOWN_CPU_PCT` | 15 | nipogi-CPU-Schwelle fürs Herunterfahren |
| `DOWN_SUSTAIN_SECONDS` | 1200 | Mittelungsfenster Herunterfahren (20 min) |
| `MIN_UPTIME_SECONDS` / `MIN_OFFTIME_SECONDS` | 900 / 300 | Mindestlaufzeit / Mindestpause (gegen Flapping) |
| `ABSORB_CPU_PCT` / `ABSORB_MEM_PCT` | 60 / 75 | max. projizierte HP-Last nach dem Herunterfahren |
| `BUSY_PROBES` | Minecraft | Kein Herunterfahren bei Spielern (leer = aus) |
| `HA_SWITCH_ENTITY` | `switch.nipogi_power` | Entity der Steckdose |
| `DRY_RUN` | false | nur loggen (automatisch aktiv, solange kein HA-Token gesetzt ist) |

## Einrichtung (Neu-Deploy)

### 0. Hardware-Voraussetzungen (einmalig)
* **nipogi BIOS:** *Restore on AC Power Loss* / *AC Back* = **Power On** (ohne das bootet er nach dem Einschalten der Steckdose nicht).
* Smarte Steckdose nur für nipogi, in Home Assistant einbindbar (FRITZ!DECT, Shelly, Tasmota, Zigbee, Tapo, …). Funktioniert mit jeder
  Integration, die eine `switch.*`-Entity liefert.
* Der HP selbst hängt **nicht** an einer schaltbaren Steckdose.

### 1. Cluster
```bash
make init-security        # nur falls noch kein Age-Key existiert
make setup-node1          # HP260G4 als Control-Plane (+ Worker)
make gitops-init          # ArgoCD + root-app
make setup-node2          # nipogi als WORKER (Taint/Label werden gesetzt)
```
Danach `git add -A && git commit && git push` (verschlüsselte `.enc`-Dateien). ArgoCD installiert alles.
Prüfen: `kubectl get nodes -L homelab.lab/role` → `hp260g4 always-on`, `nipogi burst`.

**Secrets:** `make setup-node1` erzeugt zuerst `talos/secrets.yaml` und generiert die Control-Plane-Config *damit*;
`make setup-node2` erzeugt die Worker-Config aus derselben Datei und bricht ab, wenn Token/CA/Cluster-ID nicht zur
`controlplane.yaml` passen. Es gibt also genau eine Quelle, `join-worker` erzeugt nie neue Secrets.

**Der Cluster-Endpoint bleibt die echte Node-IP `192.168.178.101`** (nicht die VIP `.100`). `.100` ist die kube-vip-*Service*-VIP
(DNS, HTTP(S), Minecraft); kube-vip läuft nicht im Control-Plane-Modus und ist selbst ein Pod, der den API-Server schon braucht.
Bei nur einem Control-Plane brächte eine API-VIP außerdem keine Ausfallsicherheit.

> Der Taint auf nipogi wird nur bei der **ersten** Registrierung gesetzt (Kubernetes NodeRestriction). Bei einem bereits
> registrierten Node: `kubectl taint node nipogi homelab.lab/burst=true:NoSchedule`.

### 2. DNS
In AdGuard (DNS-Rewrites) `homeassistant.lab` → `192.168.178.100` eintragen (wie `adguard.lab`).

### 3. Home Assistant einrichten
1. `https://homeassistant.lab` öffnen → Onboarding (Benutzer anlegen).
2. Steckdose von nipogi als Integration hinzufügen (Einstellungen → Geräte & Dienste). HA läuft mit `hostNetwork`, die
   automatische Erkennung im LAN funktioniert.
3. Entity-ID der Steckdose prüfen (Einstellungen → Entitäten) und ggf. `HA_SWITCH_ENTITY` in `config.env` anpassen.
4. Profil (unten links) → Sicherheit → **Langlebiges Zugriffstoken** erstellen.
5. Token ablegen und committen:
   ```bash
   make power-manager-secret
   git add platform/automation/power-manager/secret-ha-token.enc.yaml && git commit -m "ha token" && git push
   ```
6. Test: `make burst-status` (Logs ansehen), dann `make burst-off` → nipogi fährt herunter, Steckdose geht aus;
   `make burst-on` → Steckdose an, nipogi bootet; `make burst-auto` → Automatik.

Solange kein Token hinterlegt ist, läuft der Power-Manager im **DRY-RUN** (loggt nur, was er tun würde).

## Betrieb

| Befehl | Wirkung |
|---|---|
| `make burst-status` | Nodes, Modus, letzte Logs |
| `make burst-on` | nipogi läuft dauerhaft (z. B. für längere Spielsessions/Wartung) |
| `make burst-off` | nipogi bleibt aus |
| `make burst-auto` | Automatik (Standard) |
| `kubectl -n power-manager logs deploy/power-manager -f` | Entscheidungen live |

Tests der Logik (ohne Cluster): `cd platform/automation/power-manager && python3 test_power_manager.py`.

## Troubleshooting

| Symptom | Ursache / Lösung |
|---|---|
| Logs: `*** DRY-RUN ***` | Kein HA-Token → Schritt 3.5 |
| `keine Talos-Config in /var/run/secrets/talos.dev` | Secret `power-manager-talos` fehlt: `KubeTalosAPIAccessConfig` in `talos/patch.yaml` aktiv? (`talosctl get kubetalosapiaccessconfig`), ArgoCD-App `power-manager` synchronisiert? |
| `talosctl Fehler: ... PermissionDenied` | Rolle: `os:operator` in `talos-serviceaccount.yaml` **und** `allowedRoles` in `talos/patch.yaml` |
| Worker joint nicht (`x509: certificate signed by unknown authority`, `invalid token`, Node taucht nie in `kubectl get nodes` auf) | Worker-Config wurde mit anderen Secrets als die Control-Plane erzeugt. **Reparatur:** `make export-secrets` (rekonstruiert `secrets.yaml` aus dem *laufenden* HP) → `make sops-encrypt` → nipogi neu in den Maintenance-Mode bringen (Talos-Installer-USB erneut booten, sein bisheriger Zustand vertraut der falschen CA) → `make setup-node2`. |
| Worker joint nicht, Secrets sind konsistent | Von nipogi aus müssen `192.168.178.101:6443` (API) und `:50000` (Talos/trustd) erreichbar sein. Auf dem Bildschirm/der Konsole von nipogi stehen die Join-Fehler. |
| nipogi ist im Cluster, aber es laufen dort keine Longhorn-Pods / Minecraft | `make burst-diagnose` zeigt die Ursache. **(a)** Longhorn-DaemonSet hat keine Toleration → Änderungen noch nicht gepusht / Argo-App `longhorn` nicht synchronisiert. **(b)** `taint-toleration`-Setting leer → `defaultSettings` gelten nur bei der **Erstinstallation**; bei bestehendem Longhorn setzen (alle Volumes müssen dafür detached sein, d. h. Workloads mit PVC vorher herunterskalieren): `kubectl -n longhorn-system patch settings.longhorn.io taint-toleration --type merge -p '{"value":"homelab.lab/burst=true:NoSchedule"}'`. **(c)** Taint fehlt auf dem Node → `kubectl taint node nipogi homelab.lab/burst=true:NoSchedule`. |
| Minecraft läuft weiter auf dem HP, obwohl nipogi Ready ist | Gewollt/normal: `preferred`-Affinity gilt nur beim Schedulen. Umgezogen wird durch den Power-Manager (nur außerhalb des DRY-RUN, und erst wenn Longhorn auf nipogi bereit ist), oder manuell: `kubectl -n minecraft delete pod minecraft-0`. |
| k9s zeigt bei nipogi die Rolle `<none>` | Kosmetisch: Kubelets dürfen `node-role.kubernetes.io/*` nicht selbst setzen. `make setup-node2` setzt das Label jetzt nachträglich; manuell: `kubectl label node nipogi node-role.kubernetes.io/worker=`. Die eigentliche Rolle steht im Label `homelab.lab/role` (`kubectl get nodes -L homelab.lab/role`). |
| Pods bleiben `Pending` mit „untolerated taint homelab.lab/burst“ | Gewollt – nur Pods mit Toleration dürfen auf nipogi. Kein Handlungsbedarf, sie laufen auf dem HP. |
| Longhorn-Volume lässt sich auf nipogi nicht attachen | Longhorn-Manager/Instance-Manager auf nipogi prüfen; `defaultSettings.taintToleration` wirkt nur bei Neuinstallation (sonst in der Longhorn-UI → Settings → *Kubernetes Taint Toleration* setzen). |
| Nipogi schaltet sich nach dem Einschalten der Steckdose nicht an | BIOS-Option *Power On after AC loss* (Schritt 0). |
| Home Assistant: „400 Bad Request“ | `trusted_proxies` in `/config/configuration.yaml` muss das Pod-CIDR enthalten (`10.244.0.0/16` = Talos-Default). |

## Einschränkungen / bewusste Entscheidungen

* **Longhorn mit 1 Replica:** Daten liegen nur auf der HP-NVMe. Ein zweites Replica auf nipogi wäre bei jedem Herunterfahren
  „degraded“ und würde ständig neu aufgebaut. Redundanz → **Backups** (`infrastructure/storage/longhorn/recurring-jobs.yaml.later`
  zeigt die Vorlage, Ziel z. B. Garage/S3).
* **Minecraft auf dem HP:** Bei ausgeschaltetem nipogi läuft Minecraft auf dem HP (`MEMORY=8G`, Limit 9Gi). Reicht der RAM des HP nicht,
  bleibt der Pod `Pending` → Power-Manager startet nipogi (gewolltes Verhalten). Bei knappem HP-RAM ggf. `MEMORY`/Limits anpassen.
* **Kein Wake-on-LAN:** Weil die Steckdose den Strom komplett trennt, funktioniert WoL nicht – der Start läuft über Steckdose + BIOS-Einstellung.
* **Metrics:** `metrics-server` läuft mit `--kubelet-insecure-tls` (Talos-Kubelet-Zertifikate sind selbstsigniert).

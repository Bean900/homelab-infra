#!/usr/bin/env python3
"""
power-manager - startet/stoppt den Burst-Worker (nipogi) abhaengig von der Last.

  AUS  --(HP-Last hoch | Burst-Pods nicht schedulbar | mode=on)-->  Home Assistant Steckdose AN
                                                                    -> Node bootet, joint, Burst-Pods ziehen um
  AN   --(Node-Last lange niedrig & HP kann alles uebernehmen)-->   cordon -> drain -> talosctl shutdown
                                                                    -> Home Assistant Steckdose AUS (kein Standby-Strom)

Nur Python-Standardbibliothek. Konfiguration ueber Umgebungsvariablen (siehe config.env).
Override per Node-Annotation  power-manager.homelab.lab/mode = auto | on | off  (make burst-on/off/auto)
"""
import calendar
import collections
import glob
import json
import os
import re
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request


# --------------------------------------------------------------------------- config
def _f(name, default):
    return float(os.environ.get(name, default))


def _s(name, default=""):
    return os.environ.get(name, default).strip()


class Config:
    def __init__(self):
        self.always_on_node = _s("NODE_ALWAYS_ON", "hp260g4")
        self.burst_node = _s("NODE_BURST", "nipogi")
        self.burst_ip = _s("BURST_NODE_IP", "192.168.178.102")
        self.talos_port = int(_f("TALOS_API_PORT", 50000))
        self.talosctl = _s("TALOSCTL", "/opt/bin/talosctl")
        self.talos_secret_dir = _s("TALOS_SECRET_DIR", "/var/run/secrets/talos.dev")

        self.ha_url = _s("HA_URL", "http://home-assistant.home-assistant.svc.cluster.local:8123").rstrip("/")
        self.ha_entity = _s("HA_SWITCH_ENTITY", "switch.nipogi_power")
        self.ha_token = _s("HA_TOKEN")

        self.burst_label = _s("BURST_POD_LABEL", "homelab.lab/workload-class=burst")
        self.burst_taint_key = _s("BURST_TAINT_KEY", "homelab.lab/burst")
        self.mode_annotation = "power-manager.homelab.lab/mode"
        self.drain_annotation = "power-manager.homelab.lab/draining-since"

        self.poll = _f("POLL_SECONDS", 30)
        # Hochfahren
        self.up_cpu = _f("UP_CPU_PCT", 75)
        self.up_mem = _f("UP_MEM_PCT", 85)
        self.up_sustain = _f("UP_SUSTAIN_SECONDS", 180)
        self.pending_sustain = _f("PENDING_SUSTAIN_SECONDS", 90)
        self.min_off = _f("MIN_OFFTIME_SECONDS", 300)
        self.boot_timeout = _f("BOOT_TIMEOUT_SECONDS", 600)
        self.longhorn_wait = _f("LONGHORN_WAIT_SECONDS", 300)
        # Herunterfahren
        self.down_cpu = _f("DOWN_CPU_PCT", 15)
        self.down_sustain = _f("DOWN_SUSTAIN_SECONDS", 1200)
        self.min_up = _f("MIN_UPTIME_SECONDS", 900)
        self.absorb_cpu = _f("ABSORB_CPU_PCT", 60)
        self.absorb_mem = _f("ABSORB_MEM_PCT", 75)
        self.drain_timeout = _f("DRAIN_TIMEOUT_SECONDS", 600)
        self.poweroff_grace = _f("POWEROFF_GRACE_SECONDS", 60)
        self.down_retry = _f("DOWN_RETRY_SECONDS", 1800)
        self.busy_probes = [p for p in _s("BUSY_PROBES").split(",") if p.strip()]

        self.dry_run = _s("DRY_RUN", "false").lower() in ("1", "true", "yes")
        if not self.ha_token or self.ha_token.upper().startswith("REPLACE"):
            self.dry_run = True
            self.dry_reason = "kein Home-Assistant-Token gesetzt (make power-manager-secret)"
        else:
            self.dry_reason = "DRY_RUN=true"


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


# --------------------------------------------------------------------------- helpers
_MULT = {"": 1, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
         "P": 1e15, "E": 1e18, "Ki": 2 ** 10, "Mi": 2 ** 20, "Gi": 2 ** 30, "Ti": 2 ** 40,
         "Pi": 2 ** 50, "Ei": 2 ** 60}


def parse_qty(q):
    """Kubernetes-Quantity -> float (cpu: Kerne, memory: Bytes)."""
    q = str(q).strip()
    m = re.fullmatch(r"([0-9.]+)([a-zA-Z]*)", q)
    if not m or m.group(2) not in _MULT:
        return float(q)
    return float(m.group(1)) * _MULT[m.group(2)]


def parse_ts(ts):
    return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))


def pod_requests(pod):
    """Effektive Requests eines Pods (cpu_cores, mem_bytes) wie der Scheduler sie sieht."""
    spec = pod.get("spec", {})

    def total(containers):
        c = m = 0.0
        for ct in containers:
            r = (ct.get("resources") or {}).get("requests") or {}
            c += parse_qty(r.get("cpu", 0))
            m += parse_qty(r.get("memory", 0))
        return c, m

    cc, cm = total(spec.get("containers", []))
    for ic in spec.get("initContainers", []):
        r = (ic.get("resources") or {}).get("requests") or {}
        cc = max(cc, parse_qty(r.get("cpu", 0)))
        cm = max(cm, parse_qty(r.get("memory", 0)))
    return cc, cm


def is_daemonset_pod(pod):
    return any(o.get("kind") == "DaemonSet" for o in pod.get("metadata", {}).get("ownerReferences", []))


def is_mirror_pod(pod):
    return "kubernetes.io/config.mirror" in (pod.get("metadata", {}).get("annotations") or {})


def node_ready(node):
    """-> (ready: bool, ready_since_epoch: float|None)"""
    for c in node.get("status", {}).get("conditions", []):
        if c.get("type") == "Ready":
            ts = c.get("lastTransitionTime")
            return c.get("status") == "True", (parse_ts(ts) if ts else None)
    return False, None


def tolerates_burst(pod, key):
    for t in pod.get("spec", {}).get("tolerations", []) or []:
        if t.get("key") == key:
            return True
        if not t.get("key") and t.get("operator") == "Exists":
            return True
    return False


def tcp_open(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | 0x80 if n else b])
        if not n:
            return out


def _read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("connection closed")
        buf += chunk
    return buf


def _read_varint(sock):
    n = shift = 0
    while True:
        b = _read_exact(sock, 1)[0]
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n
        shift += 7


def mc_players_online(host, port, timeout=5):
    """Minecraft 'Server List Ping' -> Anzahl Spieler online (Exception bei Fehler)."""
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.settimeout(timeout)
        hb = host.encode()
        payload = b"\x00" + _varint(765) + _varint(len(hb)) + hb + struct.pack(">H", port) + _varint(1)
        s.sendall(_varint(len(payload)) + payload + b"\x01\x00")
        length = _read_varint(s)
        body = _read_exact(s, length)
    # body: varint packet-id, varint string-length, json
    i = 0
    while body[i] & 0x80:
        i += 1
    i += 1
    n = shift = 0
    while True:
        b = body[i]
        i += 1
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            break
        shift += 7
    return int(json.loads(body[i:i + n].decode("utf-8")).get("players", {}).get("online", 0))


class Window:
    """Gleitendes Zeitfenster. covered() ist erst wahr, wenn es seit >= `seconds` Daten sammelt."""

    def __init__(self, seconds):
        self.seconds = seconds
        self.clear()

    def clear(self):
        self.samples = collections.deque()
        self.first = None

    def add(self, now, value):
        if self.first is None:
            self.first = now
        self.samples.append((now, value))
        while self.samples and self.samples[0][0] < now - self.seconds:
            self.samples.popleft()

    def covered(self, now):
        return self.first is not None and now - self.first >= self.seconds and len(self.samples) >= 2

    def avg(self):
        return sum(v for _, v in self.samples) / len(self.samples) if self.samples else 0.0


# --------------------------------------------------------------------------- Kubernetes API
class KubeError(Exception):
    pass


class Kube:
    def __init__(self):
        self.base = os.environ.get("KUBE_BASE", "https://kubernetes.default.svc")
        self.token_file = os.environ.get("KUBE_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
        ca = os.environ.get("KUBE_CA_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
        self.ctx = ssl.create_default_context(cafile=ca) if os.path.exists(ca) else None

    def request(self, method, path, body=None, ctype="application/json"):
        with open(self.token_file) as f:  # Token rotiert -> jedes Mal neu lesen
            token = f.read().strip()
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": "Bearer " + token, "Accept": "application/json", "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=20) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"message": raw.decode(errors="replace")}

    def _get(self, path):
        code, body = self.request("GET", path)
        if code == 404:
            return None
        if code >= 300:
            raise KubeError("GET %s -> %s %s" % (path, code, body.get("message")))
        return body

    # ---- high level
    def node(self, name):
        return self._get("/api/v1/nodes/" + name)

    def node_usage(self, name):
        """(cpu_cores, mem_bytes) oder None, falls (noch) keine Metrics vorhanden."""
        m = self._get("/apis/metrics.k8s.io/v1beta1/nodes/" + name)
        if not m:
            return None
        u = m.get("usage", {})
        return parse_qty(u.get("cpu", 0)), parse_qty(u.get("memory", 0))

    def pods(self, field=None, label=None):
        qs = []
        if field:
            qs.append("fieldSelector=" + urllib.request.quote(field, safe=""))
        if label:
            qs.append("labelSelector=" + urllib.request.quote(label, safe=""))
        body = self._get("/api/v1/pods" + ("?" + "&".join(qs) if qs else ""))
        return (body or {}).get("items", [])

    def patch_node(self, name, patch):
        code, body = self.request("PATCH", "/api/v1/nodes/" + name, patch, "application/merge-patch+json")
        if code >= 300:
            raise KubeError("PATCH node %s -> %s %s" % (name, code, body.get("message")))

    def evict(self, ns, name):
        """-> 'ok' | 'gone' | 'blocked' (PodDisruptionBudget)"""
        body = {"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": name, "namespace": ns}}
        code, resp = self.request("POST", "/api/v1/namespaces/%s/pods/%s/eviction" % (ns, name), body)
        if code in (200, 201):
            return "ok"
        if code == 404:
            return "gone"
        if code == 429:
            return "blocked"
        raise KubeError("evict %s/%s -> %s %s" % (ns, name, code, resp.get("message")))

    def longhorn_node_ready(self, name):
        """True/False; None wenn Longhorn-API nicht lesbar (dann nicht blockieren)."""
        code, body = self.request("GET", "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes/" + name)
        if code in (401, 403):
            return None
        if code == 404:
            lcode, _ = self.request("GET", "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes")
            return None if lcode == 404 else False   # Longhorn gar nicht installiert -> nicht blockieren
        if code != 200:
            return False
        conds = body.get("status", {}).get("conditions", [])
        if isinstance(conds, dict):
            conds = list(conds.values())
        return any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds)

    def longhorn_attached_to(self, node):
        """Liste der Volume-Namen, die noch an `node` attached sind (leer, wenn nicht ermittelbar)."""
        code, body = self.request("GET", "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes")
        if code != 200:
            return []
        return [v["metadata"]["name"] for v in body.get("items", [])
                if v.get("status", {}).get("currentNodeID") == node
                and v.get("status", {}).get("state") in ("attached", "attaching")]


# --------------------------------------------------------------------------- Manager
class Manager:
    def __init__(self, cfg, kube=None):
        self.cfg = cfg
        self.kube = kube or Kube()
        self.up_cpu = Window(cfg.up_sustain)
        self.up_mem = Window(cfg.up_sustain)
        self.down_cpu = Window(cfg.down_sustain)
        self.pending_since = None
        self.boot_started = None
        self.last_off = 0.0              # Zeitpunkt des letzten Ausschaltens (0 = darf sofort starten)
        self.next_down_attempt = 0.0
        self.next_wake_attempt = 0.0
        self.migrated_for = None
        self.last_status = 0.0
        self.warned_missing_node = False
        self.last_lh_warn = 0.0
        self.heartbeat = os.environ.get("HEARTBEAT_FILE", "/tmp/heartbeat")

    # ---- Zeit / Heartbeat (ueberschreibbar fuer Tests)
    def now(self):
        return time.time()

    def sleep(self, seconds):
        end = self.now() + seconds
        while self.now() < end:
            self.beat()
            time.sleep(min(5, max(0.1, end - self.now())))

    def beat(self):
        try:
            with open(self.heartbeat, "w") as f:
                f.write(str(int(self.now())))
        except OSError:
            pass

    # ---- Aktoren (ueberschreibbar fuer Tests)
    def ha_call(self, service):
        """service: turn_on | turn_off  -> True bei Erfolg"""
        if self.cfg.dry_run:
            log("[DRY-RUN] Home Assistant: %s %s" % (service, self.cfg.ha_entity))
            return True
        req = urllib.request.Request(
            "%s/api/services/homeassistant/%s" % (self.cfg.ha_url, service),
            data=json.dumps({"entity_id": self.cfg.ha_entity}).encode(), method="POST",
            headers={"Authorization": "Bearer " + self.cfg.ha_token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status < 300
        except (urllib.error.URLError, OSError) as e:
            log("Home Assistant %s fehlgeschlagen: %s" % (service, e))
            return False

    def ha_state(self):
        req = urllib.request.Request("%s/api/states/%s" % (self.cfg.ha_url, self.cfg.ha_entity),
                                     headers={"Authorization": "Bearer " + self.cfg.ha_token})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.loads(r.read()).get("state")
        except (urllib.error.URLError, OSError, ValueError):
            return None

    def talos_shutdown(self):
        cfgs = sorted(glob.glob(os.path.join(self.cfg.talos_secret_dir, "*")))
        if not cfgs:
            log("FEHLER: keine Talos-Config in %s (Secret 'power-manager-talos' fehlt?)" % self.cfg.talos_secret_dir)
            return False
        path = next((c for c in cfgs if os.path.basename(c) == "config"), cfgs[0])
        cmd = [self.cfg.talosctl, "--talosconfig", path, "--endpoints", self.cfg.burst_ip,
               "--nodes", self.cfg.burst_ip, "shutdown", "--wait=false"]
        log("talosctl shutdown -> %s" % self.cfg.burst_ip)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=90,
                               env=dict(os.environ, HOME="/tmp"))
        except (OSError, subprocess.TimeoutExpired) as e:
            log("talosctl fehlgeschlagen: %s" % e)
            return False
        if r.returncode != 0:
            log("talosctl Fehler: %s %s" % (r.stdout.strip(), r.stderr.strip()))
            return False
        return True

    def api_up(self):
        return tcp_open(self.cfg.burst_ip, self.cfg.talos_port)

    def players_online(self):
        total = 0
        for probe in self.cfg.busy_probes:
            host, _, port = probe.strip().rpartition(":")
            try:
                total += mc_players_online(host, int(port))
            except (OSError, ValueError, IndexError, KeyError):
                pass  # Server nicht erreichbar/kein Minecraft -> zaehlt als 0 Spieler
        return total

    # ---- Metriken
    def usage_pct(self, node_obj, usage):
        alloc = node_obj["status"]["allocatable"]
        return (usage[0] / parse_qty(alloc["cpu"]) * 100.0, usage[1] / parse_qty(alloc["memory"]) * 100.0)

    # ---- Haupt-Tick
    def tick(self):
        cfg = self.cfg
        now = self.now()
        self.beat()
        burst = self.kube.node(cfg.burst_node)
        if burst is None:
            if not self.warned_missing_node:
                log("Node '%s' ist (noch) nicht im Cluster registriert - warte." % cfg.burst_node)
                self.warned_missing_node = True
            return
        self.warned_missing_node = False
        mode = (burst["metadata"].get("annotations") or {}).get(cfg.mode_annotation, "auto")
        ready, ready_since = node_ready(burst)
        if ready and now - self.last_off < 120:
            return  # Node meldet kurz nach dem Shutdown noch "Ready" (veralteter Heartbeat)
        if ready:
            self.on_ready(burst, ready_since or now, mode)
        else:
            self.on_not_ready(mode)
        if now - self.last_status > 300:
            self.last_status = now
            log("Status: burst-node=%s mode=%s dry_run=%s" % ("AN" if ready else "AUS", mode, cfg.dry_run))

    # ---- Node ist AUS / bootet
    def on_not_ready(self, mode):
        cfg = self.cfg
        now = self.now()
        self.down_cpu.clear()
        self.migrated_for = None
        if self.boot_started:
            if now - self.boot_started < cfg.boot_timeout:
                return
            log("WARNUNG: %s ist %ds nach dem Einschalten nicht Ready -> Strom-Zyklus (Steckdose aus)."
                % (cfg.burst_node, cfg.boot_timeout))
            self.ha_call("turn_off")
            self.boot_started = None
            self.last_off = now
            return
        if mode == "off":
            return
        if now < self.next_wake_attempt:
            return
        reason = "mode=on" if mode == "on" else None
        if reason is None:
            if now - self.last_off < cfg.min_off:
                return
            reason = self.scale_up_reason(now)
        if reason:
            self.wake(reason)

    def scale_up_reason(self, now):
        cfg = self.cfg
        hp = self.kube.node(cfg.always_on_node)
        usage = self.kube.node_usage(cfg.always_on_node) if hp else None
        if not hp or not usage:
            log("Keine Metriken fuer %s - keine Entscheidung." % cfg.always_on_node)
            return None
        cpu, mem = self.usage_pct(hp, usage)
        self.up_cpu.add(now, cpu)
        self.up_mem.add(now, mem)

        pending = [p["metadata"]["name"] for p in self.kube.pods(field="status.phase=Pending")
                   if not is_daemonset_pod(p) and tolerates_burst(p, cfg.burst_taint_key)
                   and any(c.get("type") == "PodScheduled" and c.get("status") == "False"
                           and c.get("reason") == "Unschedulable" for c in p.get("status", {}).get("conditions", []))]
        if pending:
            self.pending_since = self.pending_since or now
            if now - self.pending_since >= cfg.pending_sustain:
                return "Burst-Pods nicht schedulbar: %s" % ", ".join(pending)
        else:
            self.pending_since = None

        # Mehr Kapazitaet hilft nur, wenn Burst-Workloads auf dem HP laufen, die umziehen koennen.
        on_hp = [p for p in self.kube.pods(field="spec.nodeName=" + cfg.always_on_node, label=cfg.burst_label)
                 if p.get("status", {}).get("phase") == "Running"]
        if not on_hp:
            return None
        if self.up_cpu.covered(now) and self.up_cpu.avg() >= cfg.up_cpu:
            return "HP-CPU im Schnitt %.0f%% (>= %.0f%%) seit %ds" % (self.up_cpu.avg(), cfg.up_cpu, cfg.up_sustain)
        if self.up_mem.covered(now) and self.up_mem.avg() >= cfg.up_mem:
            return "HP-RAM im Schnitt %.0f%% (>= %.0f%%) seit %ds" % (self.up_mem.avg(), cfg.up_mem, cfg.up_sustain)
        return None

    def wake(self, reason):
        cfg = self.cfg
        now = self.now()
        log("==> STARTE %s: %s" % (cfg.burst_node, reason))
        if cfg.dry_run:
            log("[DRY-RUN] (%s) wuerde Steckdose aus->an schalten." % cfg.dry_reason)
            self.next_wake_attempt = now + 600
            return
        # Erst AUS, dann AN: erzeugt sicher ein "AC restored" (BIOS: Power On after AC loss),
        # auch wenn die Steckdose faelschlich noch an war und der Rechner im Standby haengt.
        if not self.ha_call("turn_off"):
            self.next_wake_attempt = now + 120
            return
        self.sleep(8)
        if not self.ha_call("turn_on"):
            self.next_wake_attempt = now + 120
            return
        self.boot_started = self.now()
        self.up_cpu.clear()
        self.up_mem.clear()
        self.pending_since = None

    # ---- Node ist AN
    def on_ready(self, burst, ready_since, mode):
        cfg = self.cfg
        now = self.now()
        self.boot_started = None
        self.up_cpu.clear()
        self.up_mem.clear()
        self.pending_since = None
        ann = burst["metadata"].get("annotations") or {}
        drain_ts = ann.get(cfg.drain_annotation)

        if drain_ts:
            if ready_since > float(drain_ts):
                log("%s ist neu gebootet -> uncordon." % cfg.burst_node)
                self.uncordon()
                burst["spec"]["unschedulable"] = False
            else:
                log("Unterbrochenes Herunterfahren erkannt -> setze fort.")
                self.shutdown_sequence(resume=True)
                return

        if mode == "off":
            log("mode=off -> fahre %s herunter." % cfg.burst_node)
            self.shutdown_sequence()
            return

        unschedulable = bool(burst.get("spec", {}).get("unschedulable"))

        # Einmal pro Boot: Burst-Pods vom HP auf den Burst-Node umziehen lassen.
        if self.migrated_for != ready_since and not unschedulable:
            lh = self.kube.longhorn_node_ready(cfg.burst_node)
            if lh is not False:
                self.migrate()
                self.migrated_for = ready_since
            elif now - ready_since > cfg.longhorn_wait and now - self.last_lh_warn > 300:
                # Nicht verschieben: Der Pod wuerde auf nipogi schedult, das Longhorn-Volume liesse sich dort
                # aber nicht attachen -> Minecraft wuerde in ContainerCreating haengen.
                self.last_lh_warn = now
                log("WARNUNG: Longhorn auf %s ist seit %ds nicht bereit - verschiebe KEINE Pods dorthin. "
                    "Pruefen: kubectl -n longhorn-system get pods -o wide | grep %s"
                    % (cfg.burst_node, now - ready_since, cfg.burst_node))

        usage = self.kube.node_usage(cfg.burst_node)
        if usage:
            self.down_cpu.add(now, self.usage_pct(burst, usage)[0])
        if mode == "on" or unschedulable:
            return
        if now < self.next_down_attempt or now - ready_since < cfg.min_up:
            return
        if not (self.down_cpu.covered(now) and self.down_cpu.avg() < cfg.down_cpu):
            return
        log("%s: CPU im Schnitt %.1f%% (< %.0f%%) seit %ds -> pruefe Herunterfahren."
            % (cfg.burst_node, self.down_cpu.avg(), cfg.down_cpu, cfg.down_sustain))
        if self.safe_to_shutdown(burst):
            self.shutdown_sequence()
        else:
            self.next_down_attempt = now + 300

    def safe_to_shutdown(self, burst):
        cfg = self.cfg
        players = self.players_online()
        if players > 0:
            log("Abbruch: %d Spieler online." % players)
            return False
        hp = self.kube.node(cfg.always_on_node)
        hp_use = self.kube.node_usage(cfg.always_on_node)
        if not hp or not hp_use:
            log("Abbruch: keine HP-Metriken.")
            return False
        hp_cpu_alloc = parse_qty(hp["status"]["allocatable"]["cpu"])
        hp_mem_alloc = parse_qty(hp["status"]["allocatable"]["memory"])
        b_cpu_abs = self.down_cpu.avg() / 100.0 * parse_qty(burst["status"]["allocatable"]["cpu"])
        b_use = self.kube.node_usage(cfg.burst_node) or (b_cpu_abs, 0.0)
        proj_cpu = (hp_use[0] + b_cpu_abs) / hp_cpu_alloc * 100.0
        proj_mem = (hp_use[1] + b_use[1]) / hp_mem_alloc * 100.0
        if proj_cpu >= cfg.absorb_cpu or proj_mem >= cfg.absorb_mem:
            log("Abbruch: HP koennte die Last nicht tragen (CPU %.0f%% / RAM %.0f%% projiziert, Limit %.0f/%.0f)."
                % (proj_cpu, proj_mem, cfg.absorb_cpu, cfg.absorb_mem))
            return False
        # Scheduler-Sicht: passen die Requests der umziehenden Pods noch auf den HP?
        req_c = req_m = 0.0
        for p in self.kube.pods(field="spec.nodeName=" + cfg.always_on_node):
            if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
                continue
            c, m = pod_requests(p)
            req_c += c
            req_m += m
        for p in self.drainable_pods():
            c, m = pod_requests(p)
            req_c += c
            req_m += m
        if req_c > hp_cpu_alloc or req_m > hp_mem_alloc * 0.95:
            log("Abbruch: Requests passen nicht auf den HP (CPU %.2f/%.2f, RAM %.1f/%.1f GiB)."
                % (req_c, hp_cpu_alloc, req_m / 2 ** 30, hp_mem_alloc / 2 ** 30))
            return False
        return True

    # ---- Migration (nach dem Boot)
    def migrate(self):
        cfg = self.cfg
        moved = 0
        for p in self.kube.pods(label=cfg.burst_label):
            node = p.get("spec", {}).get("nodeName")
            if node == cfg.burst_node or p.get("status", {}).get("phase") != "Running":
                continue
            if p["metadata"].get("deletionTimestamp"):
                continue
            name = "%s/%s" % (p["metadata"]["namespace"], p["metadata"]["name"])
            log("Migration: evicte %s (laeuft auf %s) -> wird auf %s neu gestartet" % (name, node, cfg.burst_node))
            if cfg.dry_run:
                continue
            res = self.kube.evict(p["metadata"]["namespace"], p["metadata"]["name"])
            moved += res == "ok"
        if moved:
            log("Migration: %d Pod(s) verschoben." % moved)

    # ---- Herunterfahren
    def drainable_pods(self):
        out = []
        for p in self.kube.pods(field="spec.nodeName=" + self.cfg.burst_node):
            if is_daemonset_pod(p) or is_mirror_pod(p):
                continue
            if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
                continue
            out.append(p)
        return out

    def uncordon(self):
        self.kube.patch_node(self.cfg.burst_node, {"metadata": {"annotations": {self.cfg.drain_annotation: None}},
                                                   "spec": {"unschedulable": False}})

    def drain(self):
        cfg = self.cfg
        deadline = self.now() + cfg.drain_timeout
        while True:
            pods = self.drainable_pods()
            if not pods:
                return True
            for p in pods:
                if p["metadata"].get("deletionTimestamp"):
                    continue
                res = self.kube.evict(p["metadata"]["namespace"], p["metadata"]["name"])
                if res == "blocked":
                    log("Drain: %s/%s durch PodDisruptionBudget blockiert." % (p["metadata"]["namespace"], p["metadata"]["name"]))
            if self.now() > deadline:
                log("Drain: Timeout, noch %d Pod(s): %s" % (len(pods), ", ".join(p["metadata"]["name"] for p in pods)))
                return False
            self.sleep(10)

    def shutdown_sequence(self, resume=False):
        cfg = self.cfg
        now = self.now()
        if cfg.dry_run:
            log("[DRY-RUN] (%s) wuerde %s cordonen, drainen, herunterfahren und Steckdose ausschalten."
                % (cfg.dry_reason, cfg.burst_node))
            self.next_down_attempt = now + cfg.down_retry
            return
        log("==> FAHRE %s HERUNTER" % cfg.burst_node)
        patch = {"spec": {"unschedulable": True}}
        if not resume:
            patch["metadata"] = {"annotations": {cfg.drain_annotation: str(int(now))}}
        self.kube.patch_node(cfg.burst_node, patch)

        if not self.drain():
            log("Drain fehlgeschlagen -> Abbruch, uncordon, naechster Versuch in %ds." % cfg.down_retry)
            self.uncordon()
            self.next_down_attempt = self.now() + cfg.down_retry
            return

        # Longhorn-Volumes muessen sauber detached sein, bevor der Node verschwindet.
        end = self.now() + 180
        while self.kube.longhorn_attached_to(cfg.burst_node) and self.now() < end:
            self.sleep(5)
        self.sleep(5)

        if not self.api_up():
            log("%s antwortet nicht mehr (bereits heruntergefahren) -> ueberspringe Shutdown-Befehl." % cfg.burst_node)
        elif not self.talos_shutdown():
            log("Shutdown-Befehl fehlgeschlagen -> uncordon, naechster Versuch in %ds." % cfg.down_retry)
            self.uncordon()
            self.next_down_attempt = self.now() + cfg.down_retry
            return

        closed = 0
        end = self.now() + 300
        while closed < 3 and self.now() < end:
            self.sleep(5)
            closed = closed + 1 if not self.api_up() else 0
        if closed < 3:
            log("FEHLER: %s faehrt nicht herunter -> uncordon." % cfg.burst_node)
            self.uncordon()
            self.next_down_attempt = self.now() + cfg.down_retry
            return

        log("Talos-API weg, warte %ds bis der Rechner wirklich aus ist..." % cfg.poweroff_grace)
        self.sleep(cfg.poweroff_grace)
        ok = False
        for _ in range(3):
            if self.ha_call("turn_off"):
                ok = True
                break
            self.sleep(10)
        if ok:
            log("Steckdose ausgeschaltet. %s ist komplett vom Strom getrennt." % cfg.burst_node)
        else:
            log("WARNUNG: Steckdose konnte nicht geschaltet werden (Home Assistant nicht erreichbar?). "
                "Node ist heruntergefahren, aber noch am Strom.")
        self.last_off = self.now()
        self.boot_started = None
        self.down_cpu.clear()
        self.up_cpu.clear()
        self.up_mem.clear()
        self.migrated_for = None


# --------------------------------------------------------------------------- main
def main():
    cfg = Config()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("power-manager gestartet: always-on=%s burst=%s (%s) entity=%s" %
        (cfg.always_on_node, cfg.burst_node, cfg.burst_ip, cfg.ha_entity))
    if cfg.dry_run:
        log("*** DRY-RUN: es werden KEINE Aktionen ausgefuehrt (%s) ***" % cfg.dry_reason)
    mgr = Manager(cfg)
    while True:
        try:
            mgr.tick()
        except Exception:  # noqa: BLE001 - Schleife darf nie sterben
            log("Fehler im Tick:\n" + traceback.format_exc())
        mgr.sleep(cfg.poll)


if __name__ == "__main__":
    main()

"""Simulationstests fuer power_manager.py (Zeit + Cluster simuliert).  Ausfuehren: python3 test_power_manager.py"""
import os
import time
import unittest

os.environ["HEARTBEAT_FILE"] = "/tmp/pm-test-heartbeat"
import power_manager as pm  # noqa: E402

T0 = 1_800_000_000  # beliebiger fester Startzeitpunkt


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


class World:
    """Minimal-Cluster: hp (4 Kerne/16Gi), nipogi (4 Kerne/16Gi), 1 Minecraft-Pod + 1 AdGuard-Pod."""

    def __init__(self):
        self.t = T0
        self.events = []  # (zeit, fn)
        self.log = []
        self.plug = "off"
        self.nip = {"ready": False, "ready_since": T0 - 9999, "unschedulable": False, "ann": {}}
        self.api_up = False
        self.mc_load = 0.2      # Kerne, die Minecraft verbraucht
        self.mc_mem = 6.0       # GiB
        self.mc_req_mem = 2.5   # GiB (Requests)
        self.players = 0
        self.hp_base_cpu = 0.3
        self.hp_base_mem = 3.0
        self.ha_ok = True
        self.talos_ok = True
        self.pods = {
            "minecraft-0": self.pod("minecraft-0", "minecraft", "hp260g4", burst=True, cpu="500m", mem="%dMi" % (self.mc_req_mem * 1024)),
            "adguard-0": self.pod("adguard-0", "network", "hp260g4", burst=False, cpu="100m", mem="128Mi"),
            "ds-flannel": self.pod("ds-flannel", "kube-system", "hp260g4", burst=False, ds=True),
            "ds-flannel-n": self.pod("ds-flannel-n", "kube-system", "nipogi", burst=False, ds=True),
        }
        self.mode = "auto"

    @staticmethod
    def pod(name, ns, node, burst, cpu="0", mem="0", ds=False):
        p = {"metadata": {"name": name, "namespace": ns, "labels": {}, "annotations": {}},
             "spec": {"nodeName": node, "containers": [{"resources": {"requests": {"cpu": cpu, "memory": mem}}}],
                      "tolerations": []},
             "status": {"phase": "Running", "conditions": []}}
        if burst:
            p["metadata"]["labels"]["homelab.lab/workload-class"] = "burst"
            p["spec"]["tolerations"].append({"key": "homelab.lab/burst", "operator": "Equal", "value": "true", "effect": "NoSchedule"})
        if ds:
            p["metadata"]["ownerReferences"] = [{"kind": "DaemonSet"}]
        return p

    def at(self, delay, fn):
        self.events.append((self.t + delay, fn))

    def advance(self, dt):
        end = self.t + dt
        while True:
            due = sorted([e for e in self.events if e[0] <= end], key=lambda e: e[0])
            if not due:
                break
            e = due[0]
            self.events.remove(e)
            self.t = max(self.t, e[0])
            e[1]()
        self.t = end

    # --- Scheduler
    def schedule(self, name):
        p = self.pods[name]
        burst = "homelab.lab/workload-class" in p["metadata"]["labels"]
        hp_free = 16 * 0.95 - sum(self.mem_req(q) for q in self.pods.values() if q["spec"].get("nodeName") == "hp260g4" and q is not p)
        if burst and self.nip["ready"] and not self.nip["unschedulable"]:
            p["spec"]["nodeName"] = "nipogi"; p["status"]["phase"] = "Running"; p["status"]["conditions"] = []
        elif hp_free >= self.mem_req(p):
            p["spec"]["nodeName"] = "hp260g4"; p["status"]["phase"] = "Running"; p["status"]["conditions"] = []
        else:
            p["spec"]["nodeName"] = None
            p["status"]["phase"] = "Pending"
            p["status"]["conditions"] = [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}]

    @staticmethod
    def mem_req(p):
        return pm.parse_qty(p["spec"]["containers"][0]["resources"]["requests"]["memory"]) / 2 ** 30


class FakeKube:
    def __init__(self, w):
        self.w = w

    def node(self, name):
        w = self.w
        if name == "hp260g4":
            return {"metadata": {"name": name, "annotations": {}}, "spec": {},
                    "status": {"allocatable": {"cpu": "4", "memory": "16Gi"},
                               "conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": iso(T0 - 99999)}]}}
        n = w.nip
        return {"metadata": {"name": name, "annotations": dict(n["ann"], **{"power-manager.homelab.lab/mode": w.mode})},
                "spec": {"unschedulable": n["unschedulable"]},
                "status": {"allocatable": {"cpu": "4", "memory": "16Gi"},
                           "conditions": [{"type": "Ready", "status": "True" if n["ready"] else "False",
                                           "lastTransitionTime": iso(n["ready_since"])}]}}

    def node_usage(self, name):
        w = self.w
        mc_node = w.pods["minecraft-0"]["spec"].get("nodeName")
        if name == "hp260g4":
            c = w.hp_base_cpu + (w.mc_load if mc_node == "hp260g4" else 0)
            m = w.hp_base_mem + (w.mc_mem if mc_node == "hp260g4" else 0)
            return c, m * 2 ** 30
        if not w.nip["ready"]:
            return None
        return (w.mc_load if mc_node == "nipogi" else 0.05), (w.mc_mem if mc_node == "nipogi" else 0.5) * 2 ** 30

    def pods(self, field=None, label=None):
        out = []
        for p in self.w.pods.values():
            if field:
                k, v = field.split("=")
                cur = p["status"]["phase"] if k == "status.phase" else p["spec"].get("nodeName")
                if cur != v:
                    continue
            if label:
                k, v = label.split("=")
                if p["metadata"]["labels"].get(k) != v:
                    continue
            out.append(p)
        return out

    def patch_node(self, name, patch):
        n = self.w.nip
        if "spec" in patch and "unschedulable" in patch["spec"]:
            n["unschedulable"] = patch["spec"]["unschedulable"]
        for k, v in (patch.get("metadata", {}).get("annotations") or {}).items():
            if v is None:
                n["ann"].pop(k, None)
            else:
                n["ann"][k] = v
        self.w.log.append(("patch", dict(patch)))

    def evict(self, ns, name):
        w = self.w
        if name not in w.pods:
            return "gone"
        w.log.append(("evict", name))
        w.pods[name]["spec"]["nodeName"] = None
        w.pods[name]["status"]["phase"] = "Pending"
        w.at(15, lambda n=name: w.schedule(n))  # StatefulSet-Controller + Scheduler
        return "ok"

    def longhorn_node_ready(self, name):
        return True

    def longhorn_attached_to(self, node):
        return []


class FakeManager(pm.Manager):
    def __init__(self, w, cfg):
        super().__init__(cfg, FakeKube(w))
        self.w = w

    def now(self):
        return self.w.t

    def sleep(self, s):
        self.w.advance(s)

    def ha_call(self, service):
        w = self.w
        w.log.append(("ha", service))
        if not w.ha_ok:
            return False
        if service == "turn_off":
            w.plug = "off"
            w.api_up = False
            if w.nip["ready"]:
                w.at(45, lambda: w.nip.update(ready=False))
        else:
            if w.plug == "off":
                w.plug = "on"
                w.at(90, self._booted)
        return True

    def _booted(self):
        w = self.w
        w.nip.update(ready=True, ready_since=w.t)
        w.api_up = True
        for name, p in w.pods.items():
            if p["status"]["phase"] == "Pending":
                w.schedule(name)

    def talos_shutdown(self):
        self.w.log.append(("talos", "shutdown"))
        if not self.w.talos_ok:
            return False
        self.w.at(20, lambda: setattr(self.w, "api_up", False))
        return True

    def api_up(self):  # noqa: F811 - wird unten per Attribut ersetzt
        return self.w.api_up

    def players_online(self):
        return self.w.players


def make_cfg(**over):
    env = {"HA_TOKEN": "test-token", "BUSY_PROBES": ""}
    env.update({k: str(v) for k, v in over.items()})
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    cfg = pm.Config()
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    return cfg


def run(mgr, seconds, step=30):
    end = mgr.w.t + seconds
    while mgr.w.t < end:
        mgr.tick()
        mgr.sleep(step)


def events(w, kind):
    return [e[1] for e in w.log if e[0] == kind]


def minecraft_node(w):
    return w.pods["minecraft-0"]["spec"].get("nodeName")


class Tests(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.cfg = make_cfg()
        self.m = FakeManager(self.w, self.cfg)
        self.m.api_up = lambda: self.w.api_up

    def test_helpers(self):
        self.assertAlmostEqual(pm.parse_qty("500m"), 0.5)
        self.assertEqual(pm.parse_qty("2Gi"), 2 * 2 ** 30)
        self.assertAlmostEqual(pm.parse_qty("250000000n"), 0.25)
        self.assertEqual(pm.parse_qty("1024Ki"), 1024 * 1024)

    def test_idle_hp_never_wakes_nipogi(self):
        self.w.mc_load = 0.2
        run(self.m, 3600)
        self.assertEqual(events(self.w, "ha"), [])

    def test_high_load_wakes_and_migrates(self):
        self.w.mc_load = 3.6  # HP: (0.3+3.6)/4 = 97%
        run(self.m, 150)
        self.assertEqual(events(self.w, "ha"), [], "darf erst nach 180s Dauerlast starten")
        run(self.m, 120)
        self.assertEqual(events(self.w, "ha")[:2], ["turn_off", "turn_on"], "Strom-Zyklus erwartet")
        self.assertEqual(minecraft_node(self.w), "hp260g4")
        run(self.m, 300)
        self.assertTrue(self.w.nip["ready"])
        self.assertEqual(minecraft_node(self.w), "nipogi", "Minecraft muss auf nipogi umgezogen sein")
        self.assertEqual(events(self.w, "evict"), ["minecraft-0"])

    def test_burst_pending_pod_triggers_wake(self):
        self.w.mc_req_mem = 20
        self.w.pods["minecraft-0"]["spec"]["containers"][0]["resources"]["requests"]["memory"] = "20Gi"
        self.w.schedule("minecraft-0")
        self.assertEqual(self.w.pods["minecraft-0"]["status"]["phase"], "Pending")
        run(self.m, 60)
        self.assertEqual(events(self.w, "ha"), [])
        run(self.m, 120)
        self.assertIn("turn_on", events(self.w, "ha"))
        run(self.m, 300)
        self.assertEqual(minecraft_node(self.w), "nipogi")

    def _boot_nipogi_with_idle_minecraft(self):
        self.w.mc_load = 3.6
        run(self.m, 600)
        self.assertEqual(minecraft_node(self.w), "nipogi")
        self.w.log.clear()
        self.w.mc_load = 0.2

    def test_idle_shutdown_full_sequence(self):
        self._boot_nipogi_with_idle_minecraft()
        run(self.m, 900)
        self.assertEqual(events(self.w, "talos"), [], "vor Ablauf des Fensters (1200s) kein Shutdown")
        run(self.m, 1500)
        log = [e[0] if e[0] != "ha" else "ha:" + e[1] for e in self.w.log]
        self.assertIn("talos", log)
        self.assertEqual(log.index("evict") < log.index("talos") < log.index("ha:turn_off"), True,
                         "Reihenfolge: drain -> talos shutdown -> Steckdose aus: %s" % log)
        self.assertEqual(self.w.plug, "off")
        self.assertEqual(minecraft_node(self.w), "hp260g4", "Minecraft muss auf den HP zurueckgezogen sein")
        self.assertFalse(self.w.nip["ready"])
        # danach keine Flapping-Wiederholung (HP-Last niedrig)
        self.w.log.clear()
        run(self.m, 3600)
        self.assertEqual(events(self.w, "ha"), [])

    def test_players_online_block_shutdown(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.players = 2
        run(self.m, 3000)
        self.assertEqual(events(self.w, "talos"), [])
        self.w.players = 0
        run(self.m, 900)
        self.assertEqual(len(events(self.w, "talos")), 1)

    def test_hp_cannot_absorb_blocks_shutdown(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.mc_mem = 12.0  # HP: 3+12 = 15 GiB von 16 -> >75%
        self.w.mc_load = 0.3
        run(self.m, 3000)
        self.assertEqual(events(self.w, "talos"), [])

    def test_requests_dont_fit_blocks_shutdown(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.pods["minecraft-0"]["spec"]["containers"][0]["resources"]["requests"]["memory"] = "16Gi"
        self.w.mc_mem = 1.0
        run(self.m, 3000)
        self.assertEqual(events(self.w, "talos"), [])

    def test_mode_on_keeps_node_running(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.mode = "on"
        run(self.m, 4000)
        self.assertEqual(events(self.w, "talos"), [])

    def test_mode_off_shuts_down_immediately_and_never_wakes(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.mode = "off"
        run(self.m, 900)
        self.assertEqual(len(events(self.w, "talos")), 1)
        self.assertEqual(self.w.plug, "off")
        self.w.log.clear()
        self.w.mc_load = 3.8
        run(self.m, 3000)
        self.assertEqual(events(self.w, "ha"), [], "mode=off darf nie starten")

    def test_mode_on_wakes_without_load(self):
        self.w.mode = "on"
        run(self.m, 300)
        self.assertEqual(events(self.w, "ha")[:2], ["turn_off", "turn_on"])

    def test_boot_timeout_power_cycles(self):
        self.w.mode = "on"
        orig = self.m._booted
        self.m._booted = lambda: None  # Node bootet nie
        run(self.m, 900)
        self.assertGreaterEqual(events(self.w, "ha").count("turn_off"), 2)
        self.m._booted = orig

    def test_shutdown_failure_uncordons_and_retries_later(self):
        self._boot_nipogi_with_idle_minecraft()
        self.w.talos_ok = False
        run(self.m, 2400)
        self.assertEqual(self.w.nip["unschedulable"], False)
        self.assertEqual(self.w.nip["ann"], {})
        self.assertEqual(len(events(self.w, "talos")), 1, "Retry erst nach down_retry (1800s)")
        self.assertEqual(self.w.plug, "on")

    def test_ha_down_wake_retries(self):
        self.w.mode = "on"
        self.w.ha_ok = False
        run(self.m, 150)
        self.assertEqual(self.w.plug, "off")
        self.w.ha_ok = True
        run(self.m, 300)
        self.assertEqual(self.w.plug, "on")

    def test_resume_interrupted_shutdown(self):
        self._boot_nipogi_with_idle_minecraft()
        # Controller wurde mitten im Drain neu gestartet: Node cordoned + Annotation nach ready_since
        self.w.nip["unschedulable"] = True
        self.w.nip["ann"] = {self.cfg.drain_annotation: str(self.w.t)}
        self.m = FakeManager(self.w, self.cfg)
        self.m.api_up = lambda: self.w.api_up
        run(self.m, 600)
        self.assertEqual(len(events(self.w, "talos")), 1)
        self.assertEqual(self.w.plug, "off")

    def test_uncordon_after_reboot(self):
        self.w.nip.update(unschedulable=True, ann={self.cfg.drain_annotation: str(T0 - 5000)}, ready=True, ready_since=T0 - 100)
        run(self.m, 60)
        self.assertFalse(self.w.nip["unschedulable"])
        self.assertEqual(self.w.nip["ann"], {})

    def test_no_migration_while_longhorn_not_ready(self):
        self.m.kube.longhorn_node_ready = lambda name: False
        self.w.mc_load = 3.6
        run(self.m, 900)                      # Node ist hochgefahren und Ready
        self.assertTrue(self.w.nip["ready"])
        run(self.m, 1200)                     # weit ueber longhorn_wait (300s)
        self.assertEqual(events(self.w, "evict"), [], "darf nicht auf einen Node ohne Longhorn migrieren")
        self.assertEqual(minecraft_node(self.w), "hp260g4")
        self.m.kube.longhorn_node_ready = lambda name: True
        run(self.m, 120)                      # Longhorn wird bereit -> jetzt Migration
        self.assertEqual(minecraft_node(self.w), "nipogi")

    def test_dry_run_does_nothing(self):
        cfg = make_cfg(HA_TOKEN="REPLACE_ME")
        self.assertTrue(cfg.dry_run)
        m = FakeManager(self.w, cfg)
        m.api_up = lambda: self.w.api_up
        self.w.mc_load = 3.8
        run(m, 1000)
        self.assertEqual(events(self.w, "ha"), [])
        self.assertEqual(self.w.plug, "off")


class MinecraftPing(unittest.TestCase):
    def test_status_ping(self):
        import json
        import socket
        import threading

        def srv(sock):
            c, _ = sock.accept()
            c.recv(4096)
            body = json.dumps({"players": {"online": 3, "max": 10}, "favicon": "x" * 20000}).encode()
            payload = b"\x00" + pm._varint(len(body)) + body
            c.sendall(pm._varint(len(payload)) + payload)
            c.close()

        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        threading.Thread(target=srv, args=(s,), daemon=True).start()
        self.assertEqual(pm.mc_players_online("127.0.0.1", s.getsockname()[1]), 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)

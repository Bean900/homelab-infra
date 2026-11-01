# homelab-infra

Declarative GitOps definition of my Talos Linux / Kubernetes homelab (Argo CD).

## Cluster

| Node | Role | Power |
|---|---|---|
| HP260G4 (`192.168.178.101`) | Control-Plane + Worker, all always-on workloads, Longhorn storage | 24/7 |
| nipogi (`192.168.178.102`) | Worker for heavy workloads (e.g. Minecraft) | started on demand, powered off via smart plug when idle |

Details, setup order and operation: **[docs/POWER-MANAGEMENT.md](docs/POWER-MANAGEMENT.md)**

## Repository layout

- `talos/` - Talos machine config patches (`patch.yaml` = HP, `patch-nipogi.yaml` = nipogi worker); generated configs are SOPS-encrypted
- `cluster/` - Argo CD root app + ApplicationSets (one per layer)
- `infrastructure/` - kube-vip, Longhorn, metrics-server
- `platform/` - Traefik, cert-manager, AdGuard, power-manager
- `applications/` - Minecraft, Home Assistant

Every directory two levels below `infrastructure/`, `platform/` and `applications/` becomes one Argo CD application
(see `cluster/applicationsets/`).

## Quick start (from scratch)

```bash
make init-security     # age key + .sops.yaml (once)
make setup-node1       # HP260G4: control plane
make gitops-init       # Argo CD + root app
make setup-node2       # nipogi: worker
git add -A && git commit -m "cluster" && git push
```

Then set up Home Assistant and the Power-Manager token (see docs).

## Key principles

- Git is the single source of truth, secrets only SOPS-encrypted (age)
- Pods run on the always-on node by default; heavy workloads opt in via toleration + label

## Talos extensions (schematic)

- siderolabs/intel-ucode
- siderolabs/i915
- siderolabs/realtek-firmware
- siderolabs/iscsi-tools

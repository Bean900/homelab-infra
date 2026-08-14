1. `age-keygen -o age.key`
2. `age.key` Public key in `.sops.yaml` eintragen
3. Encrypt der einzelnen clusterconfigs `sops encrypt clusterconfig/controlplane-base.yaml > clusterconfig/controlplane-base.enc.yaml`

 talosctl apply-config --insecure  --nodes 192.168.178.54 --file clusterconfig/controlplane-base.yaml




 -----



1. talosctl machineconfig patch clusterconfig/controlplane.yaml --patch @patches/controlplane.base.yaml > clusterconfig/controlplane.base.enc.yaml
2. sops --encrypt --in-place clusterconfig/controlplane.base.enc.yaml 
3. mv talosconfig talosconfig.enc.yaml
4. sops --encrypt --in-place talosconfig.enc.yaml



Von vorne:
# Repository klonen & entschlüsseln:
git clone https://github.com/Bean900/homelab-infra.git
cd homelab-infra

Talos Configs lokal für den Moment entschlüsseln
sops --decrypt talos/controlplane.enc.yaml > talos/controlplane.yaml
sops --decrypt talos/talosconfig.enc.yaml > talos/talosconfig

# Talos auf die 3 nackten VMs flashen:
talosctl apply-config --insecure --nodes 192.168.1.10 --file talos/controlplane.yaml
talosctl apply-config --insecure --nodes 192.168.1.11 --file talos/controlplane.yaml
talosctl apply-config --insecure --nodes 192.168.1.12 --file talos/controlplane.yaml

Bootstrappen (nur auf dem ersten Node)
talosctl bootstrap --nodes 192.168.1.10 --talosconfig talos/talosconfig


Sobald ArgoCD läuft, musst du via kubectl nur noch ein einziges Mal die cluster/root.yaml anwenden:
export KUBECONFIG=talos/kubeconfig # (vorher via talosctl gen kubeconfig holen)
kubectl apply -f cluster/root.yaml
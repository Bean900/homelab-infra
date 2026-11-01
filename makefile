SHELL := /bin/bash

.PHONY: setup-node1 setup-node2 setup-talos gitops-init gitops-patch get-argocd-password init-security sops-encrypt sops-decrypt traefik-secret longhorn-secret shutdown-cluster export-secrets join-worker join-controlplane power-manager-secret burst-on burst-off burst-auto burst-status burst-diagnose

# Node & Cluster Configuration
# Echte IP des Control-Plane-Nodes. Sie dient als Cluster-Endpoint (:6443) und fuer Talos (:50000/trustd).
# NICHT die kube-vip-Service-VIP (.100) verwenden: Die VIP traegt nur LoadBalancer-Services (DNS, HTTP(S), Minecraft),
# kube-vip laeuft hier nicht im Control-Plane-Modus, und er ist selbst ein Pod (braucht den API-Server -> Henne-Ei).
CONTROL_PLANE_IP ?= 192.168.178.101
CLUSTER_NAME     ?= homelab
DISK_NAME        ?= sda
SCHEMATIC_ID     ?= 654f89bd9b7cc6fc59b0ef86b9eff3068e73154a09492c1b41800782747c84ce
TALOS_VERSION    ?= v1.14.1

# Zweiter Node (NiPoGi) = reiner WORKER (Burst-Node, wird bei geringer Last ausgeschaltet)
# Defaults für "make join-worker" / "make setup-node2"
NODE_IP          ?= 192.168.178.102
NODE_HOSTNAME    ?= nipogi
NODE_DISK        ?= nvme0n1
NODE_PATCH       ?= talos/patch-nipogi.yaml

# Paths & Directories
OUTPUT_DIR       ?= ./talos
TALOSCONFIG      ?= $(OUTPUT_DIR)/talosconfig
KUBECONFIG       ?= $(OUTPUT_DIR)/kubeconfig
SECRETS_FILE     ?= $(OUTPUT_DIR)/secrets.yaml
SOPS_AGE_DIR     ?= $(HOME)/.config/sops/age
SOPS_AGE_KEY     ?= $(SOPS_AGE_DIR)/keys.txt

# SOPS / Secrets Configuration
export SOPS_AGE_KEY_FILE := $(SOPS_AGE_KEY)
SOPS_MANAGED_FILES ?= talos/controlplane.yaml talos/kubeconfig talos/talosconfig talos/secrets.yaml talos/nipogi/worker.yaml platform/dns/adguard/secret.yaml

# ==========================================
# W O R K F L O W   T A R G E T S
# ==========================================

# 1. Schritt: Node 1 komplett aufsetzen, Secrets exportieren und alles verschlüsseln
setup-node1: setup-talos sops-encrypt
	@echo "🎉 Node 1 (.101) Setup, Secret-Export und Verschlüsselung erfolgreich abgeschlossen."
	@echo "👉 Nächster Schritt: 'make init-security' (falls noch kein Age-Key existiert) oder 'make gitops-init'."

# 2. Schritt: Node 2 hinzufügen (entschlüsselt zuerst die nötigen Files, joint, und verschlüsselt neu)
setup-node2:
	@echo "🔓 Stelle sicher, dass die Secrets entschlüsselt vorliegen..."
	@if [ -f "$(SECRETS_FILE)" ] && [ -f "$(OUTPUT_DIR)/controlplane.yaml" ] && [ -f "$(TALOSCONFIG)" ]; then \
		echo "ℹ️  Klartext-Dateien liegen lokal vor - werden NICHT mit alten .enc-Dateien überschrieben."; \
	else \
		$(MAKE) sops-decrypt; \
	fi
	@echo "🚀 Füge den zweiten Node (.102) hinzu..."
	@$(MAKE) join-worker
	@echo "🔒 Verschlüssele die neu generierten Konfigurationsdateien..."
	@$(MAKE) sops-encrypt
	@echo "🎉 Node 2 (.102) erfolgreich als Worker zum Cluster hinzugefügt und Konfiguration verschlüsselt!"
	@echo "📦 Führe nun 'git add' für die .enc.yaml Dateien aus, um sie zu committen."

# ==========================================
# C O R E   T A R G E T S
# ==========================================

setup-talos:
	@echo "🔍 Checking if disk /dev/$(DISK_NAME) exists on $(CONTROL_PLANE_IP)..."
	@if ! talosctl get disks --insecure --nodes $(CONTROL_PLANE_IP) | grep -q "$(DISK_NAME)"; then \
		echo "❌ Error: Disk $(DISK_NAME) not found on $(CONTROL_PLANE_IP)! Aborting."; \
		exit 1; \
	fi
	@echo "✅ Disk $(DISK_NAME) found."
	
	@echo "⚙️ Generating Talos configuration in $(OUTPUT_DIR)..."
	@mkdir -p $(OUTPUT_DIR)
	@echo "🔑 Erzeuge NEUE Cluster-Secrets ($(SECRETS_FILE)) - einzige Quelle für Control-Plane UND Worker..."
	talosctl gen secrets -o $(SECRETS_FILE) --force
	talosctl gen config $(CLUSTER_NAME) https://$(CONTROL_PLANE_IP):6443 \
		--with-secrets $(SECRETS_FILE) \
		--output-types controlplane,talosconfig \
		--install-disk /dev/$(DISK_NAME) \
		--install-image factory.talos.dev/installer-secureboot/$(SCHEMATIC_ID):$(TALOS_VERSION) \
		--config-patch-control-plane @talos/patch.yaml \
		--output-dir $(OUTPUT_DIR) \
		--force
		
	@echo "🚀 Applying configuration to $(CONTROL_PLANE_IP)..."
	talosctl apply-config --insecure --nodes $(CONTROL_PLANE_IP) --file $(OUTPUT_DIR)/controlplane.yaml
	talosctl --talosconfig=$(TALOSCONFIG) config endpoints $(CONTROL_PLANE_IP)
	talosctl --talosconfig=$(TALOSCONFIG) config nodes $(CONTROL_PLANE_IP)
	
	@echo "⏳ Waiting for node API to become ready (node installation/reboot)..."
	@sleep 120
	@for i in $$(seq 1 30); do \
		if talosctl version --nodes $(CONTROL_PLANE_IP) --talosconfig=$(TALOSCONFIG) >/dev/null 2>&1; then \
			echo "✅ Node API is reachable!"; \
			break; \
		fi; \
		if [ $$i -eq 30 ]; then \
			echo "❌ Error: Timed out waiting for node API on $(CONTROL_PLANE_IP)!"; \
			exit 1; \
		fi; \
		echo "  Node not ready yet, retrying in 5s ($$i/30)..."; \
		sleep 5; \
	done

	@echo "⏳ Starting bootstrap process..."
	talosctl bootstrap --nodes $(CONTROL_PLANE_IP) --talosconfig=$(TALOSCONFIG)

	@echo "🩺 Checking cluster health..."
	talosctl --nodes $(CONTROL_PLANE_IP) --talosconfig=$(TALOSCONFIG) health
	
	@echo "🔑 Downloading kubeconfig..."
	talosctl kubeconfig $(KUBECONFIG) \
		--nodes $(CONTROL_PLANE_IP) \
		--endpoints $(CONTROL_PLANE_IP) \
		--talosconfig=$(TALOSCONFIG)
	@echo "🎉 Cluster setup complete!"

# Reparatur: baut $(SECRETS_FILE) aus der Machine-Config des LAUFENDEN Control-Plane neu auf.
# Nutzen, wenn secrets.yaml nicht (mehr) zum laufenden Cluster passt (Worker kann nicht joinen).
export-secrets:
	@echo "🔍 Lese Machine-Config vom laufenden Control-Plane $(CONTROL_PLANE_IP)..."
	@mkdir -p $(OUTPUT_DIR)
	talosctl --talosconfig=$(TALOSCONFIG) --nodes $(CONTROL_PLANE_IP) --endpoints $(CONTROL_PLANE_IP) \
		read /system/state/config.yaml > $(OUTPUT_DIR)/.running-controlplane.yaml
	@echo "🔑 Rekonstruiere Secrets-Bundle..."
	talosctl gen secrets --from-controlplane-config $(OUTPUT_DIR)/.running-controlplane.yaml -o $(SECRETS_FILE) --force
	@rm -f $(OUTPUT_DIR)/.running-controlplane.yaml
	@echo "✅ $(SECRETS_FILE) passt jetzt zum laufenden Cluster. Danach: 'make sops-encrypt' und 'make setup-node2'."

join-worker:
	@echo "🔍 Checking prerequisites for $(NODE_HOSTNAME)..."
	@if [ ! -f "$(SECRETS_FILE)" ]; then \
		echo "❌ Error: $(SECRETS_FILE) nicht gefunden! Erst 'make export-secrets' ausführen."; \
		exit 1; \
	fi
	@if [ ! -f "$(NODE_PATCH)" ]; then \
		echo "❌ Error: Patch-Datei $(NODE_PATCH) nicht gefunden!"; \
		exit 1; \
	fi
	@echo "🔍 Checking if disk /dev/$(NODE_DISK) exists on $(NODE_IP)..."
	@if ! talosctl get disks --insecure --nodes $(NODE_IP) | grep -q "$(NODE_DISK)"; then \
		echo "❌ Error: Disk $(NODE_DISK) not found on $(NODE_IP)! Aborting."; \
		exit 1; \
	fi
	@echo "✅ Disk $(NODE_DISK) found."

	@echo "⚙️ Generating WORKER configuration for $(NODE_HOSTNAME) in $(OUTPUT_DIR)/$(NODE_HOSTNAME)..."
	@mkdir -p $(OUTPUT_DIR)/$(NODE_HOSTNAME)
	talosctl gen config $(CLUSTER_NAME) https://$(CONTROL_PLANE_IP):6443 \
		--with-secrets $(SECRETS_FILE) \
		--install-disk /dev/$(NODE_DISK) \
		--install-image factory.talos.dev/installer-secureboot/$(SCHEMATIC_ID):$(TALOS_VERSION) \
		--config-patch-worker @$(NODE_PATCH) \
		--output-dir $(OUTPUT_DIR)/$(NODE_HOSTNAME) \
		--output-types worker \
		--force

	@echo "🔐 Prüfe, ob Worker-Config zum Cluster passt (Token/CA/Cluster-ID)..."
	@MISSING=$$(grep -E '^\s+(token|secret|id|crt):' $(OUTPUT_DIR)/$(NODE_HOSTNAME)/worker.yaml | sed 's/^\s*//' | \
		while read -r l; do grep -qF -- "$$l" $(OUTPUT_DIR)/controlplane.yaml || echo "$$l"; done | wc -l); \
	if [ "$$MISSING" != "0" ]; then \
		echo "❌ Worker-Config und controlplane.yaml haben UNTERSCHIEDLICHE Secrets ($$MISSING Abweichungen)!"; \
		echo "   Der Worker könnte dem Cluster nie beitreten. Lösung: 'make export-secrets' (holt die Secrets vom laufenden"; \
		echo "   Control-Plane) und danach erneut 'make setup-node2'."; \
		exit 1; \
	fi
	@echo "✅ Secrets konsistent."
	@echo "🚀 Applying configuration to $(NODE_IP)..."
	talosctl apply-config --insecure --nodes $(NODE_IP) --file $(OUTPUT_DIR)/$(NODE_HOSTNAME)/worker.yaml

	@echo "🔄 Talosconfig: Endpoint/Node bleiben NUR der Control-Plane (nipogi ist oft ausgeschaltet)..."
	talosctl --talosconfig=$(TALOSCONFIG) config endpoints $(CONTROL_PLANE_IP)
	talosctl --talosconfig=$(TALOSCONFIG) config nodes $(CONTROL_PLANE_IP)

	@echo "⏳ Warte, bis $(NODE_HOSTNAME) dem Cluster beigetreten ist (90s)..."
	@sleep 90
	@echo "🩺 Checking cluster health..."
	talosctl --nodes $(CONTROL_PLANE_IP) --talosconfig=$(TALOSCONFIG) health
	@echo "🏷️  Rolle für kubectl/k9s setzen (rein kosmetisch, Kubelets dürfen node-role-Labels nicht selbst setzen)..."
	-@kubectl --kubeconfig=$(KUBECONFIG) label node $(NODE_HOSTNAME) node-role.kubernetes.io/worker= --overwrite
	@echo "🎉 $(NODE_HOSTNAME) ist nun Worker (Taint homelab.lab/burst=true:NoSchedule)."

# Alias fuer alte Workflows
join-controlplane: join-worker

# ==========================================
# S E C U R I T Y   &   S O P S
# ==========================================

init-security:
	@echo "🔍 Checking for age-keygen binary..."
	@if ! command -v age-keygen >/dev/null 2>&1; then \
		echo "❌ Error: 'age-keygen' is not installed! Please install 'age' first."; \
		exit 1; \
	fi
	@if [ -f "$(SOPS_AGE_KEY)" ]; then \
		echo "❌ Error: Key already exists at $(SOPS_AGE_KEY)! Move or delete it manually to start fresh."; \
		exit 1; \
	fi
	
	@echo "📁 Creating SOPS configuration directory at $(SOPS_AGE_DIR)..."
	@mkdir -p $(SOPS_AGE_DIR)
	
	@echo "🔑 Generating fresh Age key-pair..."
	@age-keygen -o $(SOPS_AGE_KEY)
	
	@PUBKEY=$$(grep "public key:" $(SOPS_AGE_KEY) | awk '{print $$4}'); \
	if [ -z "$$PUBKEY" ]; then \
		echo "❌ Error: Failed to extract public key from $(SOPS_AGE_KEY)!"; \
		exit 1; \
	fi; \
	echo "✅ Extracted public key: $$PUBKEY"; \
	echo "⚙️ Creating .sops.yaml..."; \
	printf "creation_rules:\n  - path_regex: .*(yaml|yml|kubeconfig|talosconfig)$$\n    encrypted_regex: ^(data|stringData|crt|key|secret|secretboxEncryptionSecret|id|token)$$\n    key_groups:\n      - age:\n          - \"%s\"\n" "$$PUBKEY" > .sops.yaml
	
	@echo "🎉 Security setup complete! Key saved to $(SOPS_AGE_KEY) and .sops.yaml created."

sops-encrypt:
	@echo "🔒 Encrypting configuration files (plain -> .enc)..."
	@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
	@[ -f .sops.yaml ] || { echo "❌ Error: No '.sops.yaml' found in root directory!"; exit 1; }
	
	@FILES="$(SOPS_MANAGED_FILES)"; \
	for file in $$FILES; do \
		if [[ "$$file" == *.yaml ]]; then \
			enc="$${file%.yaml}.enc.yaml"; \
		elif [[ "$$file" == *.yml ]]; then \
			enc="$${file%.yml}.enc.yml"; \
		else \
			enc="$$file.enc"; \
		fi; \
		if [ -f "$$file" ]; then \
			echo "🔄 Encrypting $$file -> $$enc..."; \
			sops --encrypt "$$file" > "$$enc" || echo "⚠️ Warning: Failed to encrypt $$file."; \
		else \
			echo "⚠️ Warning: Plain file $$file not found. Skipping."; \
		fi; \
	done
	@echo "✅ Encryption process finished."

sops-decrypt:
	@echo "🔓 Decrypting configuration files (.enc -> plain)..."
	@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
	
	@FILES="$(SOPS_MANAGED_FILES)"; \
	for file in $$FILES; do \
		if [[ "$$file" == *.yaml ]]; then \
			enc="$${file%.yaml}.enc.yaml"; \
		elif [[ "$$file" == *.yml ]]; then \
			enc="$${file%.yml}.enc.yml"; \
		else \
			enc="$$file.enc"; \
		fi; \
		if [ -f "$$enc" ]; then \
			echo "🔄 Decrypting $$enc -> $$file..."; \
			sops --decrypt "$$enc" > "$$file" || echo "⚠️ Warning: Failed to decrypt $$enc."; \
		else \
			echo "⚠️ Warning: Encrypted file $$enc not found. Skipping."; \
		fi; \
	done
	@echo "✅ Decryption process finished."

# ==========================================
# G I T O P S   &   A P P S
# ==========================================

gitops-init:
	@echo "🚀 Starting GitOps bootstrap..."
	@if [ ! -f "$(SOPS_AGE_KEY)" ]; then \
		echo "❌ Error: Private Age key not found at $(SOPS_AGE_KEY)! Aborting."; \
		exit 1; \
	fi
	
	@echo "📦 Creating argocd namespace & setting PodSecurity policy..."
	kubectl create namespace argocd --kubeconfig $(KUBECONFIG) || true
	kubectl label --overwrite namespace argocd \
		pod-security.kubernetes.io/enforce=privileged \
		pod-security.kubernetes.io/warn=privileged \
		pod-security.kubernetes.io/audit=privileged \
		--kubeconfig $(KUBECONFIG)
	
	@echo "🔑 Injecting SOPS Age Key..."
	kubectl create secret generic sops-age \
		--namespace argocd \
		--from-file=keys.txt=$(SOPS_AGE_KEY) \
		--dry-run=client -o yaml | kubectl apply --kubeconfig $(KUBECONFIG) -f -
	
	@echo "📦 Applying ArgoCD via local Kustomize base..."
	kubectl apply -k cluster/argo-cd --server-side --force-conflicts --kubeconfig $(KUBECONFIG)

	@echo "🌐 Applying cluster root application..."
	kubectl apply -f cluster/root.yaml --kubeconfig $(KUBECONFIG)
	@echo "🎉 GitOps initialized successfully!"

gitops-patch:
	@echo "🔍 Checking for kubeconfig at $(KUBECONFIG)..."
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "❌ Error: Kubeconfig not found at $(KUBECONFIG)! Run 'make setup-talos' first."; \
		exit 1; \
	fi
	
	@echo "📦 Re-applying ArgoCD Kustomize base..."
	kubectl apply -k cluster/argo-cd --server-side --force-conflicts --kubeconfig $(KUBECONFIG)
	
	@echo "🌐 Re-applying cluster root application..."
	kubectl apply -f cluster/root.yaml --kubeconfig $(KUBECONFIG)
	
	@echo "🔄 Triggering ArgoCD hard refresh on root-app..."
	kubectl annotate application root-app -n argocd argocd.argoproj.io/refresh=hard --overwrite --kubeconfig $(KUBECONFIG) || true
	
	@echo "🎉 GitOps patched and refreshed successfully!"

get-argocd-password:
	@echo "🔍 Checking for kubeconfig at $(KUBECONFIG)..."
	@if [ ! -f "$(KUBECONFIG)" ]; then \
		echo "❌ Error: Kubeconfig not found at $(KUBECONFIG)! Run 'make setup-talos' first."; \
		exit 1; \
	fi
	@echo "🔑 Retrieving initial ArgoCD admin password..."
	@if ! kubectl get secret argocd-initial-admin-secret -n argocd --kubeconfig $(KUBECONFIG) >/dev/null 2>&1; then \
		echo "❌ Error: Secret 'argocd-initial-admin-secret' not found in 'argocd' namespace!"; \
		exit 1; \
	fi
	@echo -n "Password: "
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --kubeconfig $(KUBECONFIG) | base64 -d; echo ""

define generate-htpasswd-secret
@command -v htpasswd >/dev/null 2>&1 || { echo "❌ Error: 'htpasswd' (apache2-utils) is not installed."; exit 1; }
@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
@command -v kubectl >/dev/null 2>&1 || { echo "❌ Error: 'kubectl' is not installed."; exit 1; }
@[ -f .sops.yaml ] || { echo "❌ Error: No '.sops.yaml' found in root directory!"; exit 1; }
@read -p "Enter desired username: " UNAME; \
read -s -p "Enter desired password: " PASS; echo ""; \
if [ -z "$$UNAME" ] || [ -z "$$PASS" ]; then \
	echo "❌ Error: Username and password cannot be empty."; \
	exit 1; \
fi; \
HASH=$$(htpasswd -Bnb "$$UNAME" "$$PASS" | tr -d '\n\r'); \
OUT_FILE="$(3)"; \
mkdir -p "$$(dirname "$$OUT_FILE")"; \
if kubectl create secret generic $(1) \
	--namespace $(2) \
	--from-literal=users="$$HASH" \
	--dry-run=client -o yaml | \
	sops --filename-override "$$OUT_FILE" --encrypt /dev/stdin > "$$OUT_FILE"; then \
	echo "✅ Secret successfully encrypted and saved to:"; \
	echo "   $$OUT_FILE"; \
else \
	echo "❌ Error during SOPS encryption."; \
	rm -f "$$OUT_FILE"; \
	exit 1; \
fi
endef

traefik-secret:
	$(call generate-htpasswd-secret,traefik-auth,traefik,platform/ingress/traefik/secret-traefik-auth.enc.yaml)

longhorn-secret:
	$(call generate-htpasswd-secret,longhorn-auth,longhorn-system,infrastructure/storage/longhorn/secret-longhorn-auth.enc.yaml)

# ==========================================
# P O W E R - M A N A G E R   (nipogi Auto-Start/Stop)
# ==========================================

# Home-Assistant Long-Lived-Token als SOPS-Secret ablegen.
# Token erzeugen: Home Assistant -> Profil (unten links) -> Sicherheit -> Langlebige Zugriffstoken
power-manager-secret:
	@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ Error: 'kubectl' is not installed."; exit 1; }
	@[ -f .sops.yaml ] || { echo "❌ Error: No '.sops.yaml' found in root directory!"; exit 1; }
	@read -s -p "Home Assistant Long-Lived Access Token: " TOKEN; echo ""; \
	if [ -z "$$TOKEN" ]; then echo "❌ Token darf nicht leer sein."; exit 1; fi; \
	OUT_FILE="platform/automation/power-manager/secret-ha-token.enc.yaml"; \
	if kubectl create secret generic power-manager-ha \
		--namespace power-manager \
		--from-literal=HA_TOKEN="$$TOKEN" \
		--dry-run=client -o yaml | \
		sops --filename-override "$$OUT_FILE" --encrypt /dev/stdin > "$$OUT_FILE.tmp"; then \
		mv "$$OUT_FILE.tmp" "$$OUT_FILE"; \
		echo "✅ Gespeichert: $$OUT_FILE"; \
		echo "👉 Jetzt: git add $$OUT_FILE && git commit && git push (ArgoCD rollt aus)"; \
	else \
		rm -f "$$OUT_FILE.tmp"; echo "❌ Error during SOPS encryption."; exit 1; \
	fi

BURST_MODE_ANNOTATION := power-manager.homelab.lab/mode

# nipogi dauerhaft AN lassen (wird bei Bedarf gestartet, nie automatisch heruntergefahren)
burst-on:
	kubectl --kubeconfig=$(KUBECONFIG) annotate node $(NODE_HOSTNAME) $(BURST_MODE_ANNOTATION)=on --overwrite
# nipogi AUS lassen (faehrt herunter und startet nicht mehr automatisch)
burst-off:
	kubectl --kubeconfig=$(KUBECONFIG) annotate node $(NODE_HOSTNAME) $(BURST_MODE_ANNOTATION)=off --overwrite
# Automatik (Standard)
burst-auto:
	kubectl --kubeconfig=$(KUBECONFIG) annotate node $(NODE_HOSTNAME) $(BURST_MODE_ANNOTATION)=auto --overwrite

burst-status:
	@kubectl --kubeconfig=$(KUBECONFIG) get nodes -L homelab.lab/role
	@echo "--- Modus:"; kubectl --kubeconfig=$(KUBECONFIG) get node $(NODE_HOSTNAME) -o jsonpath='{.metadata.annotations.power-manager\.homelab\.lab/mode}'; echo
	@echo "--- Letzte Power-Manager-Logs:"; kubectl --kubeconfig=$(KUBECONFIG) -n power-manager logs deploy/power-manager --tail=20

# Warum laufen auf nipogi keine Pods (Longhorn, Minecraft)? Zeigt die relevanten Fakten auf einen Blick.
burst-diagnose:
	@echo "=== 1) Labels/Taints von nipogi (erwartet: homelab.lab/role=burst, Taint homelab.lab/burst=true:NoSchedule)"
	@kubectl --kubeconfig=$(KUBECONFIG) get nodes -L homelab.lab/role
	@kubectl --kubeconfig=$(KUBECONFIG) get node $(NODE_HOSTNAME) -o jsonpath='Taints: {.spec.taints}{"\n"}'
	@echo "=== 2) Longhorn-DaemonSet-Toleration (erwartet: Eintrag homelab.lab/burst)"
	@kubectl --kubeconfig=$(KUBECONFIG) -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
	@echo "=== 3) Longhorn-Setting taint-toleration (erwartet: homelab.lab/burst=true:NoSchedule)"
	@kubectl --kubeconfig=$(KUBECONFIG) -n longhorn-system get settings.longhorn.io taint-toleration -o jsonpath='{.value}{"\n"}'
	@echo "=== 4) Pods auf $(NODE_HOSTNAME)"
	@kubectl --kubeconfig=$(KUBECONFIG) get pods -A -o wide --field-selector spec.nodeName=$(NODE_HOSTNAME)
	@echo "=== 5) Wo laufen Minecraft / Longhorn-Instance-Manager?"
	@kubectl --kubeconfig=$(KUBECONFIG) get pods -A -o wide | grep -E "minecraft|instance-manager|engine-image" || true

shutdown-cluster:
	@echo "⚠️ WARNING: This will shut down the ENTIRE cluster (nipogi first, then $(CONTROL_PLANE_IP))!"
	@echo "   Danach muss HP260G4 manuell eingeschaltet werden. Home-Assistant-Steckdose von nipogi ggf. manuell schalten."
	@read -p "Are you sure you want to proceed? (yes/no): " CONFIRM; \
	if [ "$$CONFIRM" != "yes" ]; then \
		echo "❌ Aborting shutdown."; \
		exit 0; \
	fi; \
	echo "⏳ Shutting down $(NODE_HOSTNAME) (falls erreichbar)..."; \
	talosctl --talosconfig=$(TALOSCONFIG) shutdown --endpoints $(CONTROL_PLANE_IP) --nodes $(NODE_IP) --force || echo "ℹ️ $(NODE_HOSTNAME) nicht erreichbar (vermutlich schon aus)."; \
	echo "⏳ Shutting down control plane..."; \
	talosctl --talosconfig=$(TALOSCONFIG) shutdown --endpoints $(CONTROL_PLANE_IP) --nodes $(CONTROL_PLANE_IP) --force; \
	echo "✅ Shutdown commands issued."

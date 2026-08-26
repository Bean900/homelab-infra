SHELL := /bin/bash

.PHONY: setup-talos gitops-init gitops-patch get-argocd-password init-security

# Node & Cluster Configuration
CONTROL_PLANE_IP ?= 192.168.178.101
CLUSTER_NAME     ?= homelab
DISK_NAME        ?= sda
SCHEMATIC_ID     ?= 613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
TALOS_VERSION    ?= v1.13.9

# Paths & Directories
OUTPUT_DIR       ?= ./talos
TALOSCONFIG      ?= $(OUTPUT_DIR)/talosconfig
KUBECONFIG       ?= $(OUTPUT_DIR)/kubeconfig
SOPS_AGE_DIR     ?= $(HOME)/.config/sops/age
SOPS_AGE_KEY     ?= $(SOPS_AGE_DIR)/keys.txt

setup-talos:
	@echo "🔍 Checking if disk /dev/$(DISK_NAME) exists on $(CONTROL_PLANE_IP)..."
	@if ! talosctl get disks --insecure --nodes $(CONTROL_PLANE_IP) | grep -q "$(DISK_NAME)"; then \
		echo "❌ Error: Disk $(DISK_NAME) not found on $(CONTROL_PLANE_IP)! Aborting."; \
		exit 1; \
	fi
	@echo "✅ Disk $(DISK_NAME) found."
	
	@echo "⚙️ Generating Talos configuration in $(OUTPUT_DIR)..."
	@mkdir -p $(OUTPUT_DIR)
	talosctl gen config $(CLUSTER_NAME) https://$(CONTROL_PLANE_IP):6443 \
		--install-disk /dev/$(DISK_NAME) \
		--install-image factory.talos.dev/installer-secureboot/$(SCHEMATIC_ID):$(TALOS_VERSION) \
		--config-patch @talos/patch.yaml \
		--output-dir $(OUTPUT_DIR) \
		--force
		
	@echo "🚀 Applying configuration to $(CONTROL_PLANE_IP)..."
	talosctl apply-config --insecure --nodes $(CONTROL_PLANE_IP) --file $(OUTPUT_DIR)/controlplane.yaml
	talosctl --talosconfig=$(TALOSCONFIG) config endpoints $(CONTROL_PLANE_IP)
	talosctl --talosconfig=$(TALOSCONFIG) config nodes $(CONTROL_PLANE_IP)
	
	@echo "⏳ Waiting for node API to become ready (node installation/reboot)..."
	@sleep 5
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
	printf "creation_rules:\n  - path_regex: \\.yaml$$\n    encrypted_regex: ^(data|stringData|crt|key|secret|secretboxEncryptionSecret|id|token)$$\n    key_groups:\n      - age:\n          - \"%s\"\n" "$$PUBKEY" > .sops.yaml
	
	@echo "🎉 Security setup complete! Key saved to $(SOPS_AGE_KEY) and .sops.yaml created."

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

traefik-secret:
	@# 1. Check dependencies & prerequisites
	@command -v htpasswd >/dev/null 2>&1 || { echo "❌ Error: 'htpasswd' (apache2-utils) is not installed."; exit 1; }
	@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ Error: 'kubectl' is not installed."; exit 1; }
	@[ -f .sops.yaml ] || { echo "❌ Error: No '.sops.yaml' found in root directory!"; exit 1; }

	@# 2. Prompt user input, generate YAML, and stream to SOPS
	@read -p "Enter desired username: " UNAME; \
	read -s -p "Enter desired password: " PASS; echo ""; \
	if [ -z "$$UNAME" ] || [ -z "$$PASS" ]; then \
		echo "❌ Error: Username and password cannot be empty."; \
		exit 1; \
	fi; \
	HASH=$$(htpasswd -Bnb "$$UNAME" "$$PASS" | tr -d '\n\r'); \
	OUT_FILE="platform/ingress/traefik/secret-traefik-auth.enc.yaml"; \
	if kubectl create secret generic traefik-auth \
		--namespace traefik \
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

longhorn-secret:
	@# 1. Check dependencies & prerequisites
	@command -v htpasswd >/dev/null 2>&1 || { echo "❌ Error: 'htpasswd' (apache2-utils) is not installed."; exit 1; }
	@command -v sops >/dev/null 2>&1 || { echo "❌ Error: 'sops' CLI is not installed."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ Error: 'kubectl' is not installed."; exit 1; }
	@[ -f .sops.yaml ] || { echo "❌ Error: No '.sops.yaml' found in root directory!"; exit 1; }

	@# 2. Prompt user input, generate YAML, and stream to SOPS
	@read -p "Enter desired username: " UNAME; \
	read -s -p "Enter desired password: " PASS; echo ""; \
	if [ -z "$$UNAME" ] || [ -z "$$PASS" ]; then \
		echo "❌ Error: Username and password cannot be empty."; \
		exit 1; \
	fi; \
	HASH=$$(htpasswd -Bnb "$$UNAME" "$$PASS" | tr -d '\n\r'); \
	OUT_FILE="infrastructure/storage/longhorn/secret-longhorn-auth.enc.yaml"; \
	if kubectl create secret generic longhorn-auth \
		--namespace longhorn-system \
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

shutdown-cluster:
	@echo "⚠️ WARNING: This will shut down the entire Talos cluster on $(CONTROL_PLANE_IP)!"
	@read -p "Are you sure you want to proceed? (yes/no): " CONFIRM; \
	if [ "$$CONFIRM" != "yes" ]; then \
		echo "❌ Aborting shutdown."; \
		exit 0; \
	fi
	@echo "⏳ Shutting down the cluster..."
	talosctl --talosconfig=$(TALOSCONFIG) shutdown --nodes $(CONTROL_PLANE_IP) --force
	@echo "✅ Cluster shutdown command issued. Nodes will power off."
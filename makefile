SHELL := /bin/bash

# Adjust these variables for your cluster
VIP = 192.168.178.50
NODE_1 = 192.168.178.29
NODE_2 = 192.168.178.11
NODE_3 = 192.168.178.12
BOOTSTRAP_NODE = $(NODE_1)

SOPS_AGE_DIR = $(HOME)/.config/sops/age
SOPS_AGE_KEY = $(SOPS_AGE_DIR)/keys.txt

# Aktualisiert um init-security und gitops-init sicherzustellen
.PHONY: help decrypt encrypt apply-config bootstrap kubeconfig gitops-init init-security traefik-secret clean

help: ## Displays this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

decrypt: ## Decrypts Talos configurations (requires SOPS & your private Age key)
	@echo "Decrypting Talos configurations..."
	sops --decrypt talos/clusterconfig/controlplane.base.enc.yaml > talos/clusterconfig/controlplane.base.yaml
	sops --decrypt talos/talosconfig.enc.yaml > talos/talosconfig.yaml
	@echo "Done! (Unencrypted files are ignored by .gitignore)"

encrypt: ## Merges base config with patches and encrypts the result
	@echo "Merging configuration with patches and encrypting..."
	rm -f talos/clusterconfig/controlplane.base.yaml
	talosctl machineconfig patch talos/clusterconfig/controlplane.yaml --patch @talos/patches/controlplane.base.yaml > talos/clusterconfig/controlplane.base.yaml
	sops --encrypt talos/clusterconfig/controlplane.base.yaml > talos/clusterconfig/controlplane.base.enc.yaml
	sops --encrypt talos/talosconfig.yaml > talos/talosconfig.enc.yaml
	@echo "Production files successfully encrypted!"

apply-config: decrypt ## Pushes the configuration to all 3 VMs (uses --insecure for fresh nodes)
	@echo "Applying Talos configuration to nodes..."
	talosctl apply-config --insecure --nodes $(NODE_1) --file talos/clusterconfig/controlplane.base.yaml

bootstrap: ## Bootstraps the cluster initially (run ONLY ONCE!)
	@echo "Starting Talos bootstrap on $(BOOTSTRAP_NODE)..."
	talosctl bootstrap --nodes $(BOOTSTRAP_NODE) --talosconfig talos/talosconfig.yaml

kubeconfig: ## Downloads the kubeconfig for kubectl
	@echo "Downloading kubeconfig..."
	talosctl kubeconfig ./talos/kubeconfig --nodes $(BOOTSTRAP_NODE) --talosconfig talos/talosconfig.yaml
	@echo "Export it using: export KUBECONFIG=\$$(pwd)/talos/kubeconfig"

gitops-init: ## Applies the ArgoCD root app and transfers the SOPS Age key
	@echo "Starting GitOps bootstrap..."
	@# Schritt 1: Namespace erstellen
	kubectl create namespace argocd --kubeconfig talos/kubeconfig || true
	
	@# Schritt 2: AGE-Key für SOPS hinterlegen
	@if [ ! -f $(SOPS_AGE_KEY) ]; then \
		echo "\033[31mError: Private Age-Key unter $(SOPS_AGE_KEY) nicht gefunden!\033[0m"; \
		exit 1; \
	fi
	@echo "Injecting SOPS Age Key..."
	kubectl create secret generic sops-age \
		--namespace argocd \
		--from-file=keys.txt=$(SOPS_AGE_KEY) \
		--dry-run=client -o yaml | kubectl apply --kubeconfig talos/kubeconfig -f -
	
	@# Schritt 3: ArgoCD initial über den lokalen Kustomize-Ordner installieren
	@echo "Applying ArgoCD via local Kustomize base..."
	kubectl apply -k cluster/argo-cd --server-side --kubeconfig talos/kubeconfig 
	
	@# Schritt 4: Die Root-App anwenden (aktiviert den GitOps-Kreislauf)
	@echo "Applying cluster root application..."
	kubectl apply -f cluster/root.yaml --kubeconfig talos/kubeconfig

init-security: ## Generates a new Age key in the default SOPS directory and configures .sops.yaml
	@if [ -f $(SOPS_AGE_KEY) ]; then \
		echo "\033[31mError: $(SOPS_AGE_KEY) already exists! Move or delete it manually if you want to start fresh.\033[0m"; \
		exit 1; \
	fi
	@echo "Creating SOPS configuration directory at $(SOPS_AGE_DIR)..."
	@mkdir -p $(SOPS_AGE_DIR)
	@echo "Generating fresh Age key-pair into $(SOPS_AGE_KEY)..."
	@age-keygen -o $(SOPS_AGE_KEY)
	@PUBKEY=$$(grep "public key:" $(SOPS_AGE_KEY) | awk '{print $$4}'); \
	echo "Public key extracted: $$PUBKEY"; \
	echo "Creating .sops.yaml file..."; \
	echo "creation_rules:" > .sops.yaml; \
	echo "  - path_regex: \.yaml$$" >> .sops.yaml; \
	echo "    encrypted_regex: ^(data|stringData|crt|key|secret|secretboxEncryptionSecret|id|token)$$" >> .sops.yaml; \
	echo "    key_groups:" >> .sops.yaml; \
	echo "      - age:" >> .sops.yaml; \
	echo "          - \"$$PUBKEY\"" >> .sops.yaml; \
	echo "\033[32mSuccess! Key stored in $(SOPS_AGE_KEY) and .sops.yaml is configured.\033[0m"

traefik-secret:
	@# 1. Abhängigkeiten prüfen
	@command -v htpasswd >/dev/null 2>&1 || { echo "❌ Fehler: 'htpasswd' (apache2-utils) ist nicht installiert."; exit 1; }
	@command -v sops >/dev/null 2>&1 || { echo "❌ Fehler: 'sops' CLI ist nicht installiert."; exit 1; }
	
	@# 2. Zielverzeichnis sicherstellen
	@mkdir -p platform/traefik
	
	@# 3. Benutzereingaben abfragen (Funktioniert jetzt dank SHELL := /bin/bash)
	@read -p "Gewünschten Benutzernamen eingeben: " UNAME; \
	read -s -p "Gewünschtes Passwort eingeben: " PWD; echo ""; \
	\
	if [ -z "$$UNAME" ] || [ -z "$$PWD" ]; then \
		echo "❌ Fehler: Benutzername und Passwort dürfen nicht leer sein."; \
		exit 1; \
	fi; \
	\
	HASH=$$(htpasswd -Bnb "$$UNAME" "$$PWD" | tr -d '\n\r'); \
	TMPFILE=$$(mktemp /tmp/traefik-secret.XXXXXX.yaml); \
	\
	trap 'rm -f "$$TMPFILE"' EXIT; \
	\
	printf "apiVersion: v1\nkind: Secret\nmetadata:\n  name: traefik-auth\n  namespace: traefik\ntype: Opaque\nstringData:\n  users: |\n    %s\n" "$$HASH" > "$$TMPFILE"; \
	\
	if sops --encrypt "$$TMPFILE" > platform/traefik/secret-traefik-auth.enc.yaml; then \
		echo "✅ Secret erfolgreich verschlüsselt und abgelegt unter:"; \
		echo "   platform/traefik/secret-traefik-auth.enc.yaml"; \
	else \
		echo "❌ Fehler bei der SOPS-Verschlüsselung."; \
		exit 1; \
	fi

clean: ## Deletes local, unencrypted sensitive files
	@echo "Cleaning up unencrypted files..."
	rm -f talos/clusterconfig/controlplane.yaml talos/clusterconfig/talosconfig.yaml talos/clusterconfig/kubeconfig
	@echo "Security cleanup complete!"
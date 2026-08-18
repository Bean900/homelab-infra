.PHONY: setup-talos gitops-init init-security

# Node & Cluster Configuration
CONTROL_PLANE_IP ?= 192.168.178.101
CLUSTER_NAME     ?= homelab
DISK_NAME        ?= sda
SCHEMATIC_ID     ?= 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
TALOS_VERSION    ?= v1.13.8

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
		--config-patch-control-plane 'cluster: {allowSchedulingOnControlPlanes: true}' \
		--output-dir $(OUTPUT_DIR)
		
	@echo "🚀 Applying configuration to $(CONTROL_PLANE_IP)..."
	talosctl apply-config --insecure --nodes $(CONTROL_PLANE_IP) --file $(OUTPUT_DIR)/controlplane.yaml
	talosctl --talosconfig=$(TALOSCONFIG) config endpoints $(CONTROL_PLANE_IP)
	talosctl --talosconfig=$(TALOSCONFIG) config nodes $(CONTROL_PLANE_IP)
	
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

gitops-init:
	@echo "🚀 Starting GitOps bootstrap..."
	@if [ ! -f "$(SOPS_AGE_KEY)" ]; then \
		echo "❌ Error: Private Age key not found at $(SOPS_AGE_KEY)! Aborting."; \
		exit 1; \
	fi
	
	@echo "📦 Creating argocd namespace & setting PodSecurity policy..."
	kubectl create namespace argocd --kubeconfig $(KUBECONFIG) || true
	kubectl label --overwrite namespace argocd pod-security.kubernetes.io/enforce=privileged --kubeconfig $(KUBECONFIG)
	
	@echo "🔑 Injecting SOPS Age Key..."
	kubectl create secret generic sops-age \
		--namespace argocd \
		--from-file=keys.txt=$(SOPS_AGE_KEY) \
		--dry-run=client -o yaml | kubectl apply --kubeconfig $(KUBECONFIG) -f -
	
	@echo "📦 Applying ArgoCD via local Kustomize base..."
	kubectl apply -k cluster/argo-cd --server-side --kubeconfig $(KUBECONFIG)
	
	@echo "🌐 Applying cluster root application..."
	kubectl apply -f cluster/root.yaml --kubeconfig $(KUBECONFIG)
	@echo "🎉 GitOps initialized successfully!"

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
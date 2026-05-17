# Adjust these variables for your cluster
VIP = 192.168.178.9
NODE_1 = 192.168.178.10
NODE_2 = 192.168.178.11
NODE_3 = 192.168.178.12
BOOTSTRAP_NODE = $(NODE_1)

.PHONY: help decrypt encrypt apply-config bootstrap kubeconfig gitops-init clean

help: ## Displays this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

decrypt: ## Decrypts Talos configurations (requires SOPS & your private Age key)
	@echo "Decrypting Talos configurations..."
	sops --decrypt talos/clusterconfig/controlplane.base.enc.yaml > talos/clusterconfig/controlplane.base.yaml
	sops --decrypt talos/talosconfig.enc.yaml > talos/talosconfig
	@echo "Done! (Unencrypted files are ignored by .gitignore)"

encrypt: ## Merges base config with patches and encrypts the result
	@echo "Merging configuration with patches and encrypting..."
	rm talos/clusterconfig/controlplane.base.yaml
	talosctl machineconfig patch talos/clusterconfig/controlplane.yaml --patch @talos/patches/controlplane.base.yaml > talos/clusterconfig/controlplane.base.yaml
	sops --encrypt talos/clusterconfig/controlplane.base.yaml > talos/clusterconfig/controlplane.base.enc.yaml
	sops --encrypt talos/talosconfig > talos/talosconfig.enc.yaml
	@echo "Production files successfully encrypted!"

apply-config: decrypt ## Pushes the configuration to all 3 VMs (uses --insecure for fresh nodes)
	@echo "Applying Talos configuration to nodes..."
	talosctl apply-config --insecure --nodes $(NODE_1) --file talos/clusterconfig/controlplane.base.yaml

bootstrap: ## Bootstraps the cluster initially (run ONLY ONCE!)
	@echo "Starting Talos bootstrap on $(BOOTSTRAP_NODE)..."
	talosctl bootstrap --nodes $(BOOTSTRAP_NODE) --talosconfig talos/talosconfig

kubeconfig: ## Downloads the kubeconfig for kubectl
	@echo "Downloading kubeconfig..."
	talosctl kubeconfig ./talos/kubeconfig --nodes $(VIP) --talosconfig talos/talosconfig
	@echo "Export it using: export KUBECONFIG=\$$(pwd)/talos/kubeconfig"

gitops-init: ## Applies the ArgoCD root app to start the GitOps process
	@echo "Starting GitOps sync via ArgoCD..."
	KUBECONFIG=talos/kubeconfig kubectl apply -f cluster/root.yaml

clean: ## Deletes local, unencrypted sensitive files
	@echo "Cleaning up unencrypted files..."
	rm -f talos/controlplane.yaml talos/talosconfig talos/kubeconfig
	@echo "Security cleanup complete!"
# ==============================================================================
# CloudNativePG Management
# ==============================================================================
CNPG_NAMESPACE ?= database
CNPG_CLUSTER   ?= main-pg-cluster
CNPG_SECRET_FILE ?= apps/database/secret-cnpg.enc.yaml

.PHONY: cnpg-edit-secrets cnpg-status cnpg-backup

## cnpg-edit-secrets: Öffnet die Secrets im Editor und verschlüsselt sie beim Speichern automatisch wieder
cnpg-edit-secrets:
	@echo "Öffne $(CNPG_SECRET_FILE) im Editor via SOPS..."
	@sops $(CNPG_SECRET_FILE)
	@echo "Bearbeitung abgeschlossen. Führe 'git diff' aus, um sicherzustellen, dass keine Klartext-Daten sichtbar sind."

## cnpg-status: Zeigt den Gesundheitsstatus des Clusters an
cnpg-status:
	@echo "Lese Status für Cluster $(CNPG_CLUSTER)..."
	kubectl cnpg status $(CNPG_CLUSTER) -n $(CNPG_NAMESPACE)

## cnpg-backup: Startet sofort ein imperatives On-Demand Backup
cnpg-backup:
	@echo "Starte On-Demand Backup für $(CNPG_CLUSTER)..."
	kubectl cnpg backup $(CNPG_CLUSTER) -n $(CNPG_NAMESPACE)
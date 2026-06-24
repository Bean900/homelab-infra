SHELL := /bin/bash

.PHONY: secret

secret: ## Verschlüsselt eine lokal erzeugte AdGuardHome.yaml als KSOPS-Secret
	@if [ ! -f ./AdGuardHome.yaml ]; then \
		echo -e "\033[31mFehler: Keine AdGuardHome.yaml im aktuellen Verzeichnis gefunden.\033[0m"; \
		echo "Starte AdGuard einmal lokal, durchlaufe den Setup-Wizard und kopiere die generierte Datei hierher."; \
		exit 1; \
	fi
	kubectl create secret generic adguard-secret \
		--from-file=AdGuardHome.yaml=./AdGuardHome.yaml \
		--dry-run=client -o yaml > .tmp.yaml && \
	sops --encrypt .tmp.yaml > secret.enc.yaml && \
	rm -f .tmp.yaml AdGuardHome.yaml && \
	echo -e "\033[32mErfolg! 'secret.enc.yaml' enthält die verschlüsselte AdGuardHome.yaml.\033[0m"
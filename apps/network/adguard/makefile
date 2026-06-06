SHELL := /bin/bash

.PHONY: secret

secret: ## Erstellt und verschlüsselt das AdGuard-Secret (Username & Passwort) in einem Schritt
	@read -p "Gib den gewünschten AdGuard-Benutzernamen ein: " USERNAME; \
	read -s -p "Gib das gewünschte AdGuard-Passwort ein: " PASSWORD; echo ""; \
	kubectl create secret generic adguard-secret \
		--from-literal=username="$$USERNAME" \
		--from-literal=password="$$PASSWORD" \
		--dry-run=client -o yaml > .tmp.yaml && \
	sops --encrypt .tmp.yaml > secret.enc.yaml && \
	rm -f .tmp.yaml && \
	echo -e "\033[32mErfolg! 'secret.enc.yaml' wurde mit Benutzername und Passwort erstellt.\033[0m"
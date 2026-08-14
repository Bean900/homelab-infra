# Central PostgreSQL with CloudNativePG

CloudNativePG manages the central PostgreSQL cluster. Data lives on Longhorn,
while continuous WAL archiving and daily physical base backups are stored
independently in the SeaweedFS S3 bucket.

## Before the first sync

1. Replace the SeaweedFS bucket and endpoint placeholders in `object-store.yaml`.
2. Edit the already SOPS-encrypted credentials with `sops apps/database/secret-cnpg.enc.yaml`.
   Use a separate SeaweedFS S3 identity restricted to the CNPG backup prefix.
3. Confirm the SeaweedFS endpoint certificate is trusted by Kubernetes nodes. For
   a private CA, add its CA bundle as `endpointCA` to the `ObjectStore`.

## Applications

Applications use `main-pg-cluster-rw.database.svc:5432`. Create a dedicated
`Database` and `DatabaseRole` plus an encrypted password Secret per application;
do not share `platform_owner` with workloads.

## Scaling

When Longhorn has at least three storage nodes, increase `instances` and use a
replicated Longhorn StorageClass. Test point-in-time recovery from SeaweedFS.

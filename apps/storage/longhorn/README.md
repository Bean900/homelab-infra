# Longhorn

This deployment installs Longhorn as the cluster's non-default persistent-volume
provider. `longhorn-single` deliberately creates one replica while the cluster
has only one storage node. It does not provide high availability until additional
nodes and replicas are configured.

## Before the first Argo CD sync

1. Build or select a Talos installer image containing `siderolabs/iscsi-tools`
   and `siderolabs/util-linux-tools`, then upgrade every node that can run
   Longhorn. Longhorn's V1 engine requires iSCSI on Talos.
2. Ensure `/var/lib/longhorn` is on persistent local storage. Prefer a dedicated
   disk/user volume rather than the Talos system disk.
3. Create a SeaweedFS bucket dedicated to Longhorn backups and an S3 account
   restricted to that bucket.
4. Replace all `REPLACE_WITH_...` values in `bootstrap/secret-seaweedfs.enc.yaml`
   and `cluster/longhorn-app.yaml`. The secret is already SOPS-encrypted; edit it
   through SOPS:

   ```sh
   sops apps/storage/longhorn/bootstrap/secret-seaweedfs.enc.yaml
   ```

   SeaweedFS S3 normally uses port `8333`; adapt it if your NAS publishes a
   different HTTPS endpoint. The endpoint must be reachable from every
   Kubernetes node.

## Use

Set `storageClassName: longhorn-single` on a PVC. The storage class is not made
the cluster default, so existing workloads are unchanged. All volumes created
through this class receive the `daily-backup` job.

## Scaling later

After adding storage nodes, add a `longhorn-replicated` StorageClass with two or
three replicas. A StorageClass change affects only new volumes; change the
replica count on each existing Longhorn volume to trigger a replica rebuild.

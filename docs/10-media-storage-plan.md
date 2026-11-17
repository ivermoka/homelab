# 10. Media storage for the \*arr stack (plan)

Status: **plan, nothing applied yet.** Scope: give the \*arr stack (qBittorrent, Radarr/Sonarr, Prowlarr, Jellyfin) one shared filesystem on the 4 TB HDD. No NFS, no Samba: apps mount the volume directly. Samba/File Browser can be added later as an independent app on the same PVC.

## Context

- The node runs Talos. `talos/patches/40-volumes.yaml` already defines a `media` user volume on the SATA disk, mounted at `/var/mnt/media`.
- `infra/local-path` runs local-path-provisioner with all PVCs under `/var/mnt/local-path` (SSD). Its namespace is `privileged` (helper pods use hostPath).
- The `apps` AppProject forbids cluster-scoped resources except Namespace. StorageClass and PV are cluster-scoped, so the new StorageClass lives in `infra/`.
- `apps/media/` exists but is empty. Folder name = namespace `media`.

## Mental model

```
HDD (sda) -> Talos UserVolume "media" -> /var/mnt/media   (one filesystem)
                                              |
            StorageClass local-path-hdd (nodePath=/var/mnt/media)
                                              |
                         PVC media/data (RWO, single node, 1 volume)
                                              |
      qbittorrent, radarr, sonarr, prowlarr, jellyfin: all mount it at /data
```

Why one PVC: hardlinks and atomic moves only work inside **one filesystem**. Two PVCs (even on the same disk) are two mounts and force Radarr to copy instead of hardlink. RWO is enough on one node: it limits *nodes*, not pods.

## Decision (ADR)

**Context:** one node, one HDD, \*arr needs one shared volume; `apps` project cannot create PVs.
**Options:**

| Option | Pros | Cons |
|---|---|---|
| A. Second local-path StorageClass on `/var/mnt/media` (chosen) | No PV needed, hardlinks work, no network, simple | Node-bound, not replicated |
| B. NFS PV | Multi-node later | PV forbidden in `apps`, adds server pod + network + auth, no gain on one node |
| C. hostPath | Trivial | Violates PSA, bypasses storage model |

**Decision:** A. **Consequences:** data survives pod/Argo changes only if `reclaimPolicy: Retain` and the path really is the HDD (see failure modes). Revisit B when the ThinkPad becomes an agent node.

## Steps

### 1. Prepare the HDD (destructive, no data to keep)

The disk still has `sda1`; Talos only provisions into free space. Wipe it (`talosctl wipe disk`; confirm syntax in the Talos 1.14 docs), then apply `40-volumes.yaml`.

Verify:
```bash
talosctl get volumestatus        # u-media  ready
talosctl get discoveredvolumes   # sda shows the media partition, not the old ext4 sda1
```

### 2. Second StorageClass (`infra/local-path`)

local-path-provisioner picks a random path if a node lists several. Use `storageClassConfigs` (supported in v0.0.37) so each class has its own path, and set `nodePathMap` to `[]` (they are mutually exclusive):

```json
{
  "nodePathMap": [],
  "storageClassConfigs": {
    "local-path":     { "nodePathMap": [{ "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES", "paths": ["/var/mnt/local-path"] }] },
    "local-path-hdd": { "nodePathMap": [{ "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES", "paths": ["/var/mnt/media"] }] }
  }
}
```

Add to the kustomization:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-hdd
provisioner: rancher.io/local-path
parameters:
  pathPattern: "{{ .PVC.Namespace }}/{{ .PVC.Name }}/"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```
Keep the existing `local-path` class as the default. (Doing this changes the existing ConfigMap patch, so existing PVCs keep working only if the `local-path` entry above matches the old path.)

Verify with a throwaway test before real use:
```bash
kubectl -n media apply -f test-pvc-and-pod.yaml   # pod writes /data/probe
talosctl ls /var/mnt/media/media/<pvc-name>        # file must be on the HDD, NOT under /var/mnt/local-path
```
Delete the test PVC; with `Retain` the directory stays, remove it manually.

### 3. Shared PVC and layout (`apps/media/templates/`)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-hdd
  resources:
    requests:
      storage: 3Ti        # local-path does not enforce this; informational
```

Layout (TRaSH convention), identical mount `/data` in every pod:
```
/data/torrents/{movies,tv,incomplete}
/data/media/{movies,tv}
```
Apps: qBittorrent saves to `/data/torrents`; Radarr root folder `/data/media/movies`; Sonarr `/data/media/tv`; Jellyfin mounts `/data/media` read-only. Settings -> Media Management: enable **Use Hardlinks instead of Copy**.

### 4. App conventions (when the apps are added)

- Helm chart with an `apps:` map in `values.yaml`, looped in templates; pinned image tags (never `latest`).
- Deployments with `strategy: Recreate` (RWO + single replica).
- Same `PUID/PGID` (e.g. 1000/1000) and `TZ=Europe/Oslo` on every pod; `fsGroup: 1000` where the image allows it. UID mismatch is the usual cause of "import failed".
- linuxserver images start as root (s6) and cannot satisfy `restricted`; set the namespace PSA to `baseline` via `managedNamespaceMetadata` and document it.
- qBittorrent traffic through a Gluetun VPN sidecar with kill switch (separate step; lawful use only, unlicensed downloading is illegal in Norway). Credentials in Sealed Secrets.
- Ingress via Traefik at `<app>.home.lan` (covered by the AdGuard wildcard). Enable each app's built-in auth.
- Config lives in each app's own small `local-path` PVC (SSD); these are not in git, so back them up.

## Verification (end to end)

```bash
kubectl -n argocd get app media local-path          # Synced / Healthy
kubectl -n media get pvc data                        # Bound
kubectl -n media exec deploy/radarr -- stat -c %d /data/torrents /data/media
# expected: the same device number twice (one filesystem -> hardlinks work)
kubectl -n media exec deploy/radarr -- ls -li /data/torrents/movies/<f> /data/media/movies/<f>/<f>
# after an import: same inode number, link count 2
```

## Failure modes

- `media` volume missing: old `sda1` still present, wipe first.
- Data lands on the SSD: StorageClass path wrong or class not selected; the SSD ephemeral partition is lost on a Talos reset. Run the step 2 probe.
- Deleting the PVC with `Retain` leaves the directory; a new PVC does **not** reuse it automatically.
- Radarr copies instead of hardlinks: torrents and media are on different PVCs/mounts, or the hardlink setting is off.
- Permission errors on import: PUID/PGID differ between qBittorrent and Radarr.
- Argo reverts manual edits (`selfHeal`); change git, not the cluster.

## Risks accepted

Single HDD, no redundancy, no backup of media (replaceable). The app config PVCs and anything irreplaceable still need a separate backup (restic CronJob is the roadmap item).

## Later (not now)

Samba or File Browser for human access: an independent Deployment mounting the same PVC, LB VIP from the Cilium pool, LAN-only netpol, credentials in a SealedSecret.

## Sources

- local-path-provisioner v0.0.37 README (nodePath, storageClassConfigs, pathPattern): https://github.com/rancher/local-path-provisioner/tree/v0.0.37
- Talos user volumes: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user
- Talos local storage guide: https://docs.siderolabs.com/kubernetes-guides/csi/local-storage
- TRaSH Guides, folder structure and hardlinks: https://trash-guides.info/File-and-Folder-Structure/
- Kubernetes PV reclaim policy: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming

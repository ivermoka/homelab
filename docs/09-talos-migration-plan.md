# 09 - Migration plan: Ubuntu Server + k3s -> Talos Linux

Status: planned. Target: Talos v1.14.x, single node (`server-box`), bare metal, no Proxmox.

## Why

- **Git-managed everything.** Talos has no SSH/shell/apt. The whole node (disks, network, firewall, extensions, k8s version) is one machine config in git. This replaces ufw, netplan, sysctl, sshd and the planned Ansible layer.
- **Security.** Immutable OS, API-only (mutual TLS), minimal packages, Pod Security `baseline` enforced by default.
- **Scaling.** New node = boot ISO + `apply-config`, not a per-machine Ubuntu setup.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Hypervisor | None (bare metal) | One 16 GB machine; the GPU and HDD are needed directly; Proxmox adds RAM cost and a non-git layer. |
| Config tool | **talstomize** (+ plain `talosctl`) | talhelper is archived. talstomize supports Talos 1.14, is a thin wrapper over `talosctl` (you learn the real commands), declares Image Factory schematics in git, has `diff` against the live node, takes the secrets bundle from a local file. topf is more featureful but is currently built against Talos 1.13 only. Both emit plain Talos configs, so switching tools later is cheap. |
| Secrets in git | **Sealed Secrets** for all Kubernetes secrets. **SOPS + age only for the Talos secrets bundle**, committed encrypted. | Sealed Secrets runs inside the cluster, so it cannot protect the Talos PKI that must exist before the cluster does. SOPS covers that one file and keeps it git-managed; nothing else uses it. |
| CNI | **Cilium**, `kubeProxyReplacement=true`, `ipam.mode=kubernetes` | Enforces NetworkPolicy (Talos default Flannel does not). KubePrism on `localhost:7445` for the API. |
| LoadBalancer | Cilium **LB-IPAM + L2 announcements** | Replaces k3s ServiceLB. L2 announcements is Beta and requires kube-proxy replacement. No node failover benefit on one node, but it is the same setup used later with more nodes. |
| Ingress | Traefik (Argo-managed Helm chart) | Keeps existing `ingressClassName: traefik` manifests unchanged. |
| Storage | local-path-provisioner on a Talos **user volume** (`/var/mnt/local-path`) | Keeps existing `local-path` PVCs working. Not replicated: backups are required. |
| Firewall | Talos ingress firewall (`NetworkDefaultActionConfig` = block) | Replaces ufw, in git. |
| Node DNS | `ResolverConfig` with explicit upstreams (DoT) | Node must never depend on AdGuard (image pulls need DNS). |
| AdGuard | Stays `hostNetwork` | IPv6 DNS without dual-stack. Needs a namespace PSA exception (see Phase 2, step 6). |

## What k3s gave for free and must now come from git

Traefik, ServiceLB, local-path-provisioner, kube-router NetworkPolicy, kube-proxy. Replacements: Traefik chart, Cilium LB-IPAM/L2, local-path-provisioner, Cilium, Cilium kube-proxy replacement.

## How the pieces fit (read this first)

```
talosctl gen secrets  ──►  secrets.yaml (cluster CA, tokens)  ──sops──►  secrets.sops.yaml  (in git)
                                         │
talstomize.yaml  (cluster name, endpoint, versions, extensions, nodes, patch list)
        │   patches/*.yaml (small YAML files, one concern each)
        ▼
talstomize build  ──►  _out/server-box.yaml  (full machine config, NOT committed)  + _out/talosconfig
        │
talstomize apply  ──►  talosctl apply-config  ──►  node (port 50000, mutual TLS)
```

- **Machine config** = the single YAML that fully describes a node (disk, network, extensions, kubelet, firewall...). Talos has no shell, so this is the *only* way to configure it.
- **talstomize** is a small Go program with four jobs ([README](https://github.com/mirceanton/talstomize)): (1) calls the same code as `talosctl gen config` to make a base config from your secrets bundle; (2) layers your patches on top; (3) validates the result (same checks as `talosctl validate`); (4) shells out to `talosctl` for `apply` and `diff`. It never generates secrets and never runs `upgrade`. Docs are only the README plus `examples/simple`, which is why this plan spells things out.
- **Patch order is the list order in `talstomize.yaml`**, not the file name. Implicit hostname + install image first, then `patches` (all nodes), then `controlplanePatches`, then the node's own `patches`; later overrides earlier. The `00-`, `10-` prefixes are only for humans.
- **Patch types:** a patch file is either a *strategic merge* (a partial config / a whole config document with `kind:`) or JSON6902. In Talos 1.14 most settings are standalone documents (`kind: HostnameConfig`, `UserVolumeConfig`, ...). To delete a default document, patch `$patch: delete`.
- **`${VAR}` in `talstomize.yaml` and patches is expanded from the environment**, and an unset variable fails the build. A literal `${...}` anywhere, comments included, triggers this.
- **Secrets split:** Talos bundle (before the cluster exists) = SOPS. Everything inside Kubernetes = Sealed Secrets.

## Repo layout (new)

```
talos/
  talstomize.yaml
  secrets.yaml               # SOPS-encrypted talosctl secrets bundle (talstomize detects this automatically)
  .sops.yaml                 # age recipient rule for secrets.yaml
  patches/
    00-install.yaml          # install disk
    10-scheduling.yaml       # run workloads on the control plane
    20-cni.yaml              # remove Flannel + kube-proxy (Cilium replaces both)
    30-dns.yaml              # node resolver
    40-volumes.yaml          # user volumes on SSD + HDD
    50-firewall.yaml         # ingress firewall (added to talstomize.yaml LAST)
    60-cilium-inline.yaml    # GENERATED by talos/gen-cilium.sh, committed
  gen-cilium.sh
  _out/                      # build output, gitignored
infra/cilium/values.yaml     # single source of Cilium values (Talos inline bootstrap AND Argo)
infra/traefik/  infra/local-path/
```

`.gitignore` (create before generating anything): `talos/_out/`, `talos/*.plain.yaml`, `talosconfig`, `kubeconfig`.

## Phase 0 - Prepare (laptop + router)

| # | Do | Why / fact | Verify |
|---|---|---|---|
| 1 | Install `talosctl`, `talstomize` (release binary or `go install github.com/mirceanton/talstomize/cmd/talstomize@latest`), `sops`, `age`, `helm`. `kubeseal` is already installed. | `talstomize` shells out to `talosctl` and `sops`; both must be on `PATH`. | `talosctl version --client`, `talstomize --help`, `sops --version` |
| 2 | `age-keygen -o ~/.config/sops/age/keys.txt`; copy the file to your password manager and a USB stick. Note the `age1...` public key. | The private key is the only way to decrypt `secrets.yaml`. Lost key = cluster must be rebuilt. sops finds it via `SOPS_AGE_KEY_FILE` or that default path. | `grep "public key" ~/.config/sops/age/keys.txt` |
| 3 | Confirm the Sealed Secrets key backup (`sealed-secrets-key.backup.yaml`) exists in two offline places. | You restore it after the rebuild or every SealedSecret in git is garbage. | file exists, not in git: `git check-ignore -v` |
| 4 | Router: shrink the DHCP pool (`.3-.254`) to `.3-.199`. `.200-.220` becomes Cilium's LoadBalancer range. | A LoadBalancer IP is announced by the cluster via ARP. If DHCP also hands it out, two devices fight over one address. | After renewal, `ip -4 neigh` shows no device in `.200-.220` |
| 5 | Confirm `server-box` DHCP reservation = `192.168.0.162`. | It is the API endpoint in the config; Talos will use DHCP unless told otherwise. | Router UI |
| 6 | Router DHCP DNS = `1.1.1.1` + `9.9.9.9` (temporary, until step 9 of Phase 4). | Nothing resolves via AdGuard while the node is down. Lease is 1 h, so it spreads gradually. | `resolvectl status` on the laptop after reconnecting |

Read once: [What is Talos](https://docs.siderolabs.com/talos/v1.14/overview/what-is-talos), [Getting started](https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started) (the manual version of what talstomize automates), [talosctl](https://docs.siderolabs.com/talos/v1.14/getting-started/talosctl).

## Phase 1 - Rehearse in Docker (no risk, learning only)

Goal: see every step once on a throw-away cluster before touching the server.

1. `talosctl cluster create docker` ([Quickstart](https://docs.siderolabs.com/talos/v1.14/getting-started/quickstart)). Explore: `talosctl dashboard`, `talosctl get members`, `talosctl logs kubelet`, `talosctl dmesg`, `talosctl read /etc/os-release`, `talosctl get machineconfig -o yaml`. Expect a Ready node with Flannel.
2. Do the **manual** flow from the guide once on a second Docker cluster (`gen config`, `apply-config`, `bootstrap`, `kubeconfig`) to see what talstomize wraps. Add the Cilium inline manifest patch (Phase 2, step 7) and watch the node sit `NotReady` until Cilium starts. That is normal.
3. Install Argo CD, restore a *test* Sealed Secrets key, sync `apps/portfolio`.
4. Test NetworkPolicy (default-deny + allow): a pod must be blocked. This proves Cilium enforces it, which Flannel did not.
5. `talosctl cluster destroy`.

Not testable in Docker: GPU, real disks / user volumes, L2 ARP announcements, the firewall on a real NIC. These are verified on the server in Phase 4.

## Phase 2 - Build the config in git (no server contact)

All commands run from `~/projects/homelab`. Nothing here touches the server until Phase 4.

**Step 1. Create the secrets bundle once**
```bash
cd talos
talosctl gen secrets -o secrets.plain.yaml     # already gitignored
cat > .sops.yaml <<'EOF'
creation_rules:
  - path_regex: secrets\.yaml$
    age: age1REPLACE_WITH_YOUR_PUBLIC_KEY
EOF
sops --encrypt secrets.plain.yaml > secrets.yaml
shred -u secrets.plain.yaml
```
What it is: the cluster's identity (root CAs for Talos API, Kubernetes, etcd, plus tokens). Every rebuild of the config must reuse it, or the cluster gets a new identity. Verify: `head -3 secrets.yaml` shows `sops:` metadata / `ENC[...]`; `sops -d secrets.yaml | head -3` shows `cluster:`.

**Step 2. Find the real disks (needs the server booted into maintenance mode, so do this in Phase 4 step 3 and come back to fill the patch).** Until then use a placeholder in `00-install.yaml` and finish it later; `talstomize build` will validate the placeholder but cannot see the disk.

**Step 3. Write `talos/talstomize.yaml`**
```yaml
apiVersion: config.talstomize.dev/v1alpha1
kind: Talstomize

clusterName: homelab
controlPlaneEndpoint: https://192.168.0.162:6443
secrets: ./secrets.yaml
talosVersion: v1.14.x            # pin to the latest 1.14 patch release you checked
kubernetesVersion: v1.xx.x       # a version supported by that Talos release (see its support matrix)

installer:
  schematic:
    customization:
      systemExtensions:
        officialExtensions:
          - siderolabs/amdgpu          # RX480 driver
          - siderolabs/intel-ucode     # CPU microcode (Intel). Verify names in factory.talos.dev for your Talos version.

nodes:
  server-box:
    ip: 192.168.0.162
    kind: controlplane
    patches:
      - ./patches/00-install.yaml

controlplanePatches:
  - ./patches/10-scheduling.yaml

patches:
  - ./patches/20-cni.yaml
  - ./patches/30-dns.yaml
  - ./patches/40-volumes.yaml
  - ./patches/60-cilium-inline.yaml
  # - ./patches/50-firewall.yaml    # enable only after everything else works (Phase 4, step 10)
```
Facts about these fields (README config reference):
- `nodes.<name>` is the **node name**; talstomize writes it as the hostname automatically (`HostnameConfig`), so no hostname patch is needed.
- `installer.schematic` is posted to the Image Factory at build time, so `build` needs internet. It returns a schematic ID, which becomes the installer image `factory.talos.dev/metal-installer/<id>:<talosVersion>`. The **same schematic ID** is what you use to download the install ISO.
- `controlPlaneEndpoint` is the URL clients and kubelets use for the API. With one node it is the node itself. When you add control-plane nodes you would move this to a VIP or load balancer.
- A secrets path ending in an encrypted file just works: no `sops` setting is needed in `talstomize.yaml`.

**Step 4. Write the patches** (one document per file). Each shows what it does and where it comes from.

`patches/00-install.yaml`, where Talos installs ([Disk management](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management)):
```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: disk.transport == 'nvme'     # the 512 GB Intel NVMe SSD. Never /dev/sda: on this machine that is the HDD.
```
The installer image is set by talstomize inside this same document (README: *Install image placement*), so don't set it yourself. Talos 1.14 rejects a config that sets install settings both here and in the old `machine.install` block.

`patches/10-scheduling.yaml`, allow normal workloads on the control-plane node (from talstomize's own example, Talos 1.14 `KubeNodeConfig`):
```yaml
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
```
Why: control-plane nodes carry a `NoSchedule` taint by default. Without this, your pods are `Pending` forever on a single-node cluster. Verify later: `kubectl describe node server-box | grep Taints` shows `<none>`.

`patches/20-cni.yaml`, remove the defaults that Cilium replaces ([Talos Cilium guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)):
```yaml
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```
Why: with Flannel deleted the node has no pod network until Cilium runs (node `NotReady`, by design). With kube-proxy disabled, Cilium implements Services in eBPF (`kubeProxyReplacement=true`). This file has two documents; if `talstomize build` rejects multi-document patch files, split it into `20-flannel.yaml` and `21-kubeproxy.yaml`.

`patches/30-dns.yaml`, node resolver that must never depend on AdGuard ([Host DNS](https://docs.siderolabs.com/talos/v1.14/networking/host-dns)). Check the exact `ResolverConfig` fields in the [reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/resolverconfig) before writing: upstream servers `1.1.1.1` and `9.9.9.9`, DoT with `tlsServerName` (`cloudflare-dns.com`, `dns.quad9.net`). Why: image pulls need DNS before AdGuard exists; this is the bootstrap-loop trap.

`patches/40-volumes.yaml`, persistent storage ([User volumes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user)):
```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path
provisioning:
  diskSelector:
    match: disk.transport == 'nvme'   # the 512 GB Intel NVMe SSD (also the system disk)
  minSize: 50GB
  maxSize: 150GB
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: media
provisioning:
  diskSelector:
    match: disk.transport == 'sata'   # the 4 TB Seagate HDD (the only SATA disk; excludes the USB installer)
  minSize: 1TB
```
Facts: a volume `local-path` is mounted at `/var/mnt/local-path` and labelled `u-local-path`; local-path-provisioner will use that path, so use `/var/mnt/local-path` (not the longer name from earlier drafts). The `EPHEMERAL` partition (container images, logs, etcd data) takes the rest of the system disk, so `maxSize` here shrinks what is left for it. Check against the [Disk layout](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/layout) page. Verify after apply: `talosctl get volumestatus` shows `u-local-path` `ready`.

`patches/50-firewall.yaml`, **write it now, enable it last** ([Ingress firewall](https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall)):
```yaml
apiVersion: v1alpha1
kind: NetworkDefaultActionConfig
ingress: block
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: apid-ingress
portSelector: { ports: [50000], protocol: tcp }
ingress:
  - subnet: 192.168.0.0/24
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kubernetes-api-ingress
portSelector: { ports: [6443], protocol: tcp }
ingress:
  - subnet: 192.168.0.0/24
# add: trustd 50001, kubelet 10250 (self/cluster only), etcd 2379-2380 (self), HTTP/S 80+443 (LAN), DNS 53 tcp+udp (LAN + ULA fdaa:bbcc:ddee::/64), AdGuard UI port 4444, Tailscale if the node joins it
```
Facts from the docs: `block` mode still allows loopback, and pod/service subnet traffic; ICMP is rate-limited; **a wrong rule can lock you out of the Talos API**, so apply with `--mode=try`, which reverts automatically after a minute if you can't confirm. Open question: does it apply to traffic to the Cilium LoadBalancer VIP on 80/443? Test it in Phase 4 before relying on it.

**Step 5. `infra/cilium/values.yaml`** (single source for both the bootstrap manifest and the Argo app):
```yaml
ipam: { mode: kubernetes }
kubeProxyReplacement: true
k8sServiceHost: localhost       # KubePrism, the node-local API endpoint
k8sServicePort: 7445
securityContext:
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
cgroup:
  autoMount: { enabled: false }
  hostRoot: /sys/fs/cgroup
l2announcements: { enabled: true }
# client rate limits: size per https://docs.cilium.io/en/stable/network/l2-announcements/ (otherwise leader election can flap)
```
Why each: `ipam: kubernetes` takes pod CIDRs from the Node object Talos creates. `localhost:7445` is KubePrism, which exists before any Service does (chicken and egg otherwise). No `SYS_MODULE` and no cgroup auto-mount, because Talos forbids loading modules and already mounts cgroups. `l2announcements` lets Cilium answer ARP for LoadBalancer IPs.

**Step 6. Generate the Cilium bootstrap manifest** with `talos/gen-cilium.sh` (re-run it on every Cilium version bump, and commit the output):
```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: gen-cilium.sh <cilium-chart-version>}"
cd "$(dirname "$0")"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
{
  printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: cilium\nmanifest: |\n'
  helm template cilium cilium/cilium --version "$VERSION" --namespace kube-system \
    -f ../infra/cilium/values.yaml | sed 's/^/  /'
} > patches/60-cilium-inline.yaml
grep -c '\${' patches/60-cilium-inline.yaml || true   # must be 0: talstomize expands ${VAR}
```
What happens: Talos applies this manifest itself during bootstrap, so the node gets a CNI without kubectl. **Talos only creates missing objects from inline manifests; it never updates or deletes them** ([guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)). After bootstrap, Argo should adopt Cilium through the same chart + values (`infra/cilium`) so that upgrades are git-driven. Use the same chart version in both places. If the `grep` count is not 0, `talstomize build` will fail on the unset variable; then ask me and we pick a workaround.

**Step 7. Cilium pool and L2 policy as an Argo app** (`infra/cilium-config/`, synced after Cilium is up) ([LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/), [L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)):
- `CiliumLoadBalancerIPPool` with block `192.168.0.200` - `192.168.0.220`.
- `CiliumL2AnnouncementPolicy` selecting the node's NIC (`eno1`; verify the name with `talosctl get links` in Phase 4) and `loadBalancerIPs: true`.
Fact: LB-IPAM does nothing until a pool exists; editing a pool later can reassign IPs, so give Traefik a fixed address (annotation `lbipam.cilium.io/ips: 192.168.0.200`).

**Step 8. Repo changes that replace k3s built-ins**
- `infra/traefik`: Argo app (Helm), Service `type: LoadBalancer`, annotation above. Keeps every existing `ingressClassName: traefik` untouched.
- `infra/local-path`: Argo app; node path `/var/mnt/local-path` ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage)); StorageClass named `local-path` so existing PVC manifests still match.
- `clusters/home/apps/projects.yaml`: add the Cilium, Traefik and local-path Helm repos to the `infra` AppProject `sourceRepos`.
- `application-set.yaml`: AdGuard's namespace needs `pod-security.kubernetes.io/enforce: privileged` (Talos enforces `baseline`, and `hostNetwork` violates it) via `managedNamespaceMetadata` ([Pod Security](https://docs.siderolabs.com/kubernetes-guides/security/pod-security)).
- Delete `apps/adguard/templates/service.yaml` (DNS LoadBalancer conflicts with hostNetwork).

**Step 9. Render and validate**
```bash
cd talos && ./gen-cilium.sh <cilium-chart-version>
talstomize build .                 # writes ./_out/server-box.yaml and ./_out/talosconfig
```
Expect no errors (it runs `talosctl validate --mode metal` equivalents, and writes nothing if any node fails). Inspect `_out/server-box.yaml`: you should see `HostnameConfig` `server-box`, your documents, and an installer image URL under `factory.talos.dev`. Then secret scan and commit:
```bash
git status    # _out/, plaintext secrets must NOT appear
grep -rnE "BEGIN .*PRIVATE|token:|password" talos/ | grep -v "ENC\["
```

## Phase 3 - Backups (cheap insurance)

1. Sealed Secrets key: apply-able copy `sealed-secrets-key.backup.yaml` in two offline places.
2. AdGuard: copy `AdGuardHome.yaml` out of the PVC to the laptop (holds a password hash; never into git).
3. Rollback artefact: `sudo k3s etcd-snapshot save`, copy it off the server.
4. Anything in `docs/07-host-state.md` you still want: it dies with the wipe, and the Talos config replaces it.
5. Note the server's NIC name and disks for later: `ip -br link`, `lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA`.

## Phase 4 - Cutover (one session, ~1-2 h; nothing important is hosted, downtime accepted)

Each step shows the command, what happens, and the expected result.

1. **Make the install USB.** In [Image Factory](https://factory.talos.dev): pick the Talos version from `talstomize.yaml`, the same extensions (amdgpu, intel-ucode), platform `metal`, arch `amd64`. Download the ISO and `sudo dd if=talos.iso of=/dev/sdX bs=4M status=progress conv=fsync`. The schematic ID shown must equal the one in the installer image in `_out/server-box.yaml`.
2. **Boot `server-box` from the USB.** It runs entirely from RAM; your Ubuntu is untouched until step 4. The console dashboard shows an IP (should be `.162` via the DHCP reservation). The node is now in *maintenance mode*: its API is open **without authentication**, so only do this on your own LAN.
3. **Inspect disks and NIC** (without credentials, hence `--insecure`):
   ```bash
   talosctl get disks --insecure -n 192.168.0.162 -o yaml
   talosctl get links --insecure -n 192.168.0.162
   ```
   Confirm the selectors match what Talos reports: `00-install.yaml` and the `local-path` volume use `disk.transport == 'nvme'` (512 GB Intel SSD), the `media` volume uses `disk.transport == 'sata'` (4 TB Seagate HDD). Confirm the NIC name for the L2 policy (`eno1` on Ubuntu). **The HDD already has a partition (`sda1`) filling the disk; Talos only provisions a user volume in free space, so copy off anything you need and wipe the disk before applying (`talosctl wipe disk`, check its syntax in the 1.14 docs), or the `media` volume will not be created.** Re-run `./gen-cilium.sh` only if Cilium values changed, then `talstomize build .` and commit.
4. **Apply the config** (this installs Talos to the SSD, **wipes Ubuntu**, and reboots from disk):
   ```bash
   talstomize apply -f . -- --insecure
   ```
   Passes `--insecure` through to `talosctl apply-config`. Expected: the node reboots; the console shows a Talos dashboard with `booting` → `running`. After this, the API requires your credentials (`_out/talosconfig`).
5. **Set credentials, then bootstrap etcd once:**
   ```bash
   export TALOSCONFIG=$PWD/_out/talosconfig
   talosctl config endpoints 192.168.0.162 && talosctl config nodes 192.168.0.162
   talosctl bootstrap
   talosctl kubeconfig ~/.kube/homelab.yaml     # replaces the k3s kubeconfig
   ```
   `bootstrap` initialises etcd on the first control-plane node, runs **once per cluster** ever. Running it again later is a mistake.
6. **Wait for Cilium.** The node stays `NotReady` until Cilium (the inline manifest) starts; allow up to ~10 minutes. Verify: `talosctl health`, `kubectl get nodes` → `Ready`, `kubectl -n kube-system get pods` → `cilium-*` Running, `cilium-operator` Running.
7. **Install Argo CD, restore the Sealed Secrets key, hand over to git:**
   ```bash
   helm install argocd argo/argo-cd -n argocd --create-namespace -f infra/argocd/values.yaml --version <same as git>
   kubectl apply -f sealed-secrets-key.backup.yaml          # needs the namespace to exist first
   kubectl apply -f clusters/home/root-app.yaml
   ```
   Everything else syncs from git (Cilium config, Traefik, local-path, apps). Verify: `kubectl -n argocd get app` all `Synced/Healthy`; `kubectl get svc -n traefik` shows `EXTERNAL-IP 192.168.0.200`; `arping -I <laptop-nic> 192.168.0.200` answers.
8. **Restore AdGuard.** Copy `AdGuardHome.yaml` into its PVC (scale the Deployment to 0, copy via a helper pod or node path under `/var/mnt/local-path`, scale up). Update the DNS rewrite `*.home.lan` → **Traefik VIP `192.168.0.200`** (not `.162`, Traefik no longer shares the node IP). Verify: `dig @192.168.0.162 argocd.home.lan` → `192.168.0.200`.
9. **Router:** DHCP DNS back to `192.168.0.162` only. IPv6 Static DNS: re-read the node's ULA (Talos may generate a different SLAAC address than Ubuntu): `talosctl get addresses | grep fdaa`; update the router and `dns.bind_hosts` in `AdGuardHome.yaml` if it changed. Devices keep the fallback until their lease renews; reconnect to force it.
10. **Enable the firewall.** Add `./patches/50-firewall.yaml` to `talstomize.yaml`, then:
    ```bash
    talstomize build .
    talstomize apply -f . -- --mode=try
    ```
    `--mode=try` applies the config and automatically **rolls it back after 1 minute** unless confirmed. While it is active, prove you still have access (`talosctl version`), that DNS works (`dig @192.168.0.162 example.com`), and that `https://argocd.home.lan` loads. If all is fine, run the same `apply` without `--mode=try` to make it permanent. If something breaks, just wait for the rollback.

## Phase 5 - Verify

- `talosctl health`, `talosctl get extensions` (amdgpu present), `talosctl get volumestatus`.
- `kubectl get nodes,pods -A`, Argo apps all Synced/Healthy.
- `dig @192.168.0.162 example.com` and over the ULA, `https://argocd.home.lan`, `portfolio.home.lan`.
- NetworkPolicy deny test pod -> blocked.
- From outside the LAN subnet (e.g. tailnet): Talos API 50000 should not be reachable unless allowed.
- `cd talos && talstomize diff -f .` exits 0 (live node equals git).

## Phase 6 - Cleanup and docs

- Remove: `/etc/rancher` expectations, ufw docs, planned Ansible; mark `docs/07-host-state.md` as historical.
- Update: `docs/` (new 10-talos-operations: upgrade, add node, recover), the `homelab-devops` skill environment section.
- Pin portfolio `image.tag` to a full SHA (still pending).

## Day-2 operations (learn these)

| Task | Command | Note |
|---|---|---|
| Change config | edit patch -> `talstomize diff` -> `talstomize apply` | `--mode=try` for risky changes. |
| Upgrade Talos | `talosctl upgrade` with the new installer image | A-B rollback; one minor at a time, via latest patch. |
| Upgrade k8s | `talosctl upgrade-k8s --to <v>` | Then update `kubernetesVersion` in git. |
| etcd backup | `talosctl etcd snapshot db.snapshot` | Do before every upgrade; schedule later (Phase E of the roadmap). |
| Debug | `talosctl dashboard/logs/dmesg/read/pcap`, `kubectl debug node` | No shell. |
| Add node | boot ISO, add to `talstomize.yaml`, apply | Needs wired Ethernet (no Wi-Fi). |

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Locked out by firewall | Apply with `--mode=try`; keep the ISO USB. |
| Lost age key or Sealed Secrets key | Offline copies; without them the cluster must be rebuilt. |
| DNS down during cutover | Phase 4 step 1. |
| Cilium L2 (Beta) or hostNetwork surprises | Fallback: Traefik `hostPort` on the node IP. |
| RX480/amdgpu issues | Verify in Phase 4; GPU is not needed until the media phase. |
| Disk layout mistakes (wipes data) | Check `diskSelector` against `talosctl get disks`; `wipe` stays false for user volumes. |
| Full rollback | Reinstall Ubuntu + k3s from `docs/01-08`, restore snapshot or let Argo re-sync from git. |

## Open items to verify during rehearsal

- Whether `ResolverConfig`, the `UserVolumeConfig` CEL expression for the HDD, and multi-document patch files all pass `talstomize build` (it validates; fix what it reports).
- Whether the rendered Cilium manifest contains `${` (talstomize would expand it as an env var).
- Intel microcode and amdgpu extension names in the Image Factory for the chosen Talos version.
- Whether Talos' nftables ingress firewall affects traffic to the Cilium LB VIP on 80/443 (the docs say Cilium host firewall may take precedence; test with the firewall in `block` mode).
- EPHEMERAL size and the user volume on the same SSD ([Disk layout](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/layout)).
- Argo adopting Cilium after the inline bootstrap (Talos only creates missing inline-manifest resources and never updates them; later upgrades go via Argo with the same `values.yaml`).
- Jellyfin GPU access later: the Talos AMD guide uses the ROCm GPU Operator for compute; Jellyfin VAAPI needs `/dev/dri` in the pod, decide then.

## Sources

- Talos: [What is Talos](https://docs.siderolabs.com/talos/v1.14/overview/what-is-talos), [Quickstart](https://docs.siderolabs.com/talos/v1.14/getting-started/quickstart), [Getting started](https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started), [Production notes](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes), [System requirements](https://docs.siderolabs.com/talos/v1.14/getting-started/system-requirements), [Editing config](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration), [Upgrading](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos), [Disaster recovery](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery), [Ingress firewall](https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall), [Host DNS](https://docs.siderolabs.com/talos/v1.14/networking/host-dns), [AMD GPU](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/hardware-and-drivers/amd-gpu).
- Guides: [Cilium on Talos](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium), [Local storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage), [Argo CD on Talos](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/deploy-argocd), [Pod Security](https://docs.siderolabs.com/kubernetes-guides/security/pod-security).
- Cilium: [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/), [L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/).
- Tools: [talstomize](https://github.com/mirceanton/talstomize), [topf](https://github.com/postfinance/topf) (considered), [talhelper](https://github.com/budimanjojo/talhelper) (archived).

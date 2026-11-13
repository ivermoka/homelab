## ufw
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp (OpenSSH)           ALLOW IN    Anywhere                  
80/tcp                     ALLOW IN    Anywhere                  
443/tcp                    ALLOW IN    Anywhere                  
Anywhere                   ALLOW IN    10.42.0.0/16              
Anywhere                   ALLOW IN    10.43.0.0/16              
6443/tcp                   ALLOW IN    192.168.0.0/24            
22/tcp (OpenSSH (v6))      ALLOW IN    Anywhere (v6)             
80/tcp (v6)                ALLOW IN    Anywhere (v6)             
443/tcp (v6)               ALLOW IN    Anywhere (v6)             

## fstab
/dev/disk/by-uuid/bbb0ab5e-71a8-4987-8e11-b6a80f7c864b / ext4 defaults 0 1
/dev/disk/by-uuid/87AE-D036 /boot/efi vfat defaults 0 1
/dev/disk/by-uuid/20775374-1d99-4872-bf8c-abab0d5ea1ac /srv/media ext4 defaults 0 1
/swap.img	none	swap	sw	0	0
## mounts
TARGET     SOURCE    FSTYPE OPTIONS
/srv/media /dev/sda1 ext4   rw,relatime
## k3s config
cluster-init: true
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10
## k3s service
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s \
    server \

## sshd
permitrootlogin without-password
pubkeyauthentication yes
passwordauthentication no
## tailscale
tailscale: command not found
## packages
## enabled units
UNIT FILE                              STATE   PRESET
apparmor.service                       enabled enabled
apport.service                         enabled enabled
blk-availability.service               enabled enabled
cloud-config.service                   enabled enabled
cloud-final.service                    enabled enabled
cloud-init-local.service               enabled enabled
cloud-init.service                     enabled enabled
console-setup.service                  enabled enabled
cron.service                           enabled enabled
dmesg.service                          enabled enabled
e2scrub_reap.service                   enabled enabled
finalrd.service                        enabled enabled
gpu-manager.service                    enabled enabled
grub-common.service                    enabled enabled
grub-initrd-fallback.service           enabled enabled
k3s.service                            enabled enabled
keyboard-setup.service                 enabled enabled
lvm2-monitor.service                   enabled enabled
ModemManager.service                   enabled enabled
multipathd.service                     enabled enabled
networkd-dispatcher.service            enabled enabled
open-iscsi.service                     enabled enabled
open-vm-tools.service                  enabled enabled
pollinate.service                      enabled enabled
rsyslog.service                        enabled enabled
secureboot-db.service                  enabled enabled
setvtrgb.service                       enabled enabled
sysstat.service                        enabled enabled
thermald.service                       enabled enabled
ua-reboot-cmds.service                 enabled enabled
ubuntu-advantage.service               enabled enabled
udisks2.service                        enabled enabled
ufw.service                            enabled enabled
unattended-upgrades.service            enabled enabled
vgauth.service                         enabled enabled

48 unit files listed.

## sysctl
/etc/ssh/sshd_config.d/:
50-cloud-init.conf

/etc/sysctl.d/:
10-bufferbloat.conf
10-console-messages.conf
10-ipv6-privacy.conf
10-kernel-hardening.conf
10-magic-sysrq.conf
10-map-count.conf
10-network-security.conf
10-ptrace.conf
10-zeropage.conf
99-sysctl.conf
README.sysctl

## history
sudo apt update && sudo apt upgrade
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH        # or: sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp       # Kubernetes API
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
sudo ufw allow from 10.42.0.0/16 to any   # pods
sudo ufw allow from 10.43.0.0/16 to any   # services
 sudo ufw allow from 192.168.0.0/24 to any port 6443 proto tcp
sudo ufw allow from 192.168.0.0/24 to any port 6443 proto tcp
ufw
ufw show ARG
ufw show
ufw status verbose
sudo ufw status verbose
ufw show
ufw route delete 6443/tcp (v6)
ufw route delete allow 6443/tcp
sudo ufw route delete allow 6443/tcp
sudo ufw delete allow 6443/tcp
sudo ufw allow from 192.168.0.0/24 to any port 6443 proto tcp
sudo ufw status verbose
sudo apt install ethtool
sudo apt install ethtool
curl -sfL https://get.k3s.io | sh - 
curl -sfL https://get.k3s.io | sh 
sudo k3s
sudo k3s kubectl get nodes
cat /etc/rancher/k3s/k3s.yaml
sudo cat /etc/rancher/k3s/k3s.yaml
vim  /etc/rancher/k3s/k3s.yaml
sudo vim  /etc/rancher/k3s/k3s.yaml
sudo cp /etc/rancher/k3s/k3s.yaml ~/k3s.yaml && sudo chown ivermk ~/k3s.yaml

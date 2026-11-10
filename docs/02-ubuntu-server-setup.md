# Setup for Ubuntu Server 24.04 (node/worker) on shitbox

Just go through normal setup.

Notary stuff:

- Sometimes selecting Grub2 on Ventoy boot screen will fix issue(s) installing
- OpenSSH ON
- SSH passkeys from GitHub w/ username
- Be sure to select `Custom` on partition screen, if you have multiple disks!


---

# Configure UFW

Need to configure ufw rules for later k3s.

Run
```
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
```

Press `Y` on everything. 


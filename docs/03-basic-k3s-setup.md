# This is just osme basic commands / setup for k3s.


## To install k3s on server:
`curl -sfL https://get.k3s.io | sh -`
This will install k3s and setup its init yaml files in your system. For example `/etc/rancher/k3s/k3s.yaml`

## Copy `/etc/rancher/k3s/k3s.yaml` to main machine (outside server)
You have to add the contents of `k3s.yaml` to your local `~/.kube/config` file. This is to be able to run `kubectl`, with the server's cluster defined. 

In server:
`sudo cp /etc/rancher/k3s/k3s.yaml ~/k3s.yaml && sudo chown ivermk ~/k3
s.yaml`

On laptop:
`scp ivermk@192.168.0.162:k3s.yaml ~/.kube/homelab.yaml
k3s.yaml
sed -i 's/127.0.0.1/192.168.0.162/; s/: default$/: homelab/' ~/.kube/homelab.yaml
chmod 600 ~/.kube/homelab.yaml`
This grabs the `k3s.yaml` file to local machine, to `homelab.yaml`. Then replaces local `127.....` addresses to network address of server `192.168.0.162`. Then adds permissions.

In my case, as I have work clusters defined there as well, I am creating a new file `~/.kube/homelab.yaml`, with the `k3s.yaml`'s contents. 

## Differentiate work / homelab

The file contains cluster definition (server address ++), contexts, config for users (client-certificate). I.e. stuff kubectl needs to know where to apply its commands. 

---

My first thoughts on managing multiple different servers (work / homelab), is to add an alias for kubectl, with `homelab.yaml` specified. I.e., something like `klh` or something. 

`alias kh='kubectl --kubeconfig ~/.kube/homelab.yaml'`
Then you can do `kh get pods` etc. 




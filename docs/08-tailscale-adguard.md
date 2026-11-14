

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --accept-dns=false
```

Login and go to console

## Configuring tailscale

Setup AdGuard Home Instance to Advertise Routes
If you followed along, you know we used the --accept-dns=false flag when we authenticated our Raspberry Pi with Tailscale to start it up.

Now along with that we are going to use the --advertise-routes flag.

Quick Note for Linux Users

For Linux users, before typing the tailscale command, you need to enable IP forwarding. We will add these following line in /etc/sysctl.d/99-tailscale.conf file.

Open the file in your preferred editor and add the following lines.

```
Terminal window
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

After this you need to reload the sysctl settings.


sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

Once the above configuration is done (in case you are using linux), you can start up the tailscale instance with the following command.

```
ivermk@server-box:~$ sudo tailscale up --accept-dns=false --advertise-routes=192.168.0.0/24
Warning: UDP GRO forwarding is suboptimally configured on eno1, UDP forwarding throughput capability will increase with a configuration change.
See https://tailscale.com/s/ethtool-config-udp-gro
ivermk@server-box:~$ tailscale ip -4
```


Add a rule for ufw to allot tailscale0 interface:
```
ivermk@server-box:~$ sudo ufw allow in on tailscale0
Rule added
Rule added (v6)
```

## On laptop

Install tailscale

Login with same account

`sudo tailscale up --accept-dns=false`

`ssh ivermk@<server tailnet ip>` # found in tailscale gui

Follow
https://jmcglock.substack.com/p/running-adguard-home-on-kubernetes


## Troubleshooting  based on what i experienced

In the adguard pod i kept getting this error:

```
PullImage from image service failed" err="rpc error: code = Unknown desc = fai
led to pull and unpack image \"docker.io/adguard/adguardhome:v0.107.80\"
```

The fix was to point /etc/resolv.conf at the real upstream servers that systemd-resolved already knows (in server)
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf


## Configure adguard

Click throught the wizard menu.

Open router settings and add your server static IP to primary DNS, 1.1.1.1 as fallback (in case primary is down. I.e. server)

Also had to change `ufw` setting on server to allow connections from `192.168....` to port 53:
`sudo ufw allow from 192.168.0.0/24 to any port 53`


## Falling back to secondary DNS server

This was an issue I experienced, where pretty much all clients seemed to fall back to secondary DNS server (1.1.1.1). 
This results in AdGuard not processing the requests -> adblock doesnt work, `*.home.lan` becomes unresolved. 

So my fix was to just remove the secondary DNS server. I'll follow the logs to make sure this doesnt screw things up..


## Clients preferring ISP ipv6 server (without adguard)

This seemed to happen on all clients, including my laptop. So the fix would either be to change ALL clients to use my ipv4 adguard DNS server, disable ipv6 completely, or have adguard expose another DNS server for ipv6.

I went with the last option. 

The steps i did:

```
      dnsPolicy: ClusterFirstWithHostNet
      hostNetwork: true
```
Add these lines to `apps/adguard/templates/deployment.yaml`.
This makes Adguard Home pods use the node's network direclty. As in the servers interfaces (192.168.0.162, in addition to the other UFW we set up on server).

But the issue with this, is that `192.168.0.162:53` is already used by systemd-resolved's stub. Therefore we also had to change the webport to be `4444` (just something unused).

Also had to change the pod's pvc settings direclty in the server.

```
kh -n adguard exec deploy/adguard-deployment -- grep -n -A3 -E "^http:|^dns:|bind_hosts" /opt/adguardhome/conf/AdGuardHome.yaml
sudo find /var/lib/rancher/k3s/storage -name AdGuardHome.yaml
```
This makes the running Adguard pod use basic adguard yaml config.
Then we find the config for active pod.

Use the returned path to edit the file and change to the below:

```
http:
  address: 0.0.0.0:4444
dns:
  bind_hosts:
    - 192.168.0.162
    - fdaa:bbcc:ddee:0:692:26ff:fed4:a8dd
  - DO NOT CHANGE PORT UNDER BIND_HOSTS
```

Then push to main. !DO NOT PUSH BEFORE YOU HAVE DONE THIS ABOVE!

Also add ufw rule for allow on port 53 for the newly defined ipv6 address:

`53                         ALLOW       fdaa:bbcc:ddee::/64`

Then go into router webpage and specify the IPv6 Static DNS to the set ipv6 address:
`fdaa:bbcc:ddee:0:692:26ff:fed4:a8dd`

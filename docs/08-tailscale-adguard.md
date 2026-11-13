

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

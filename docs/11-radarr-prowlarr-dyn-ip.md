Since prowlarr is running through vpn tunnel, it cannot reach the local address for radarr when defining the app n PROWLARR settings. 

This ill probably fix later. But for now, when radarr pod rotates / restarts, clusterIP gets rotated as well.

So if stuff stops working, its either this or VPN expiring. 

Run 
`kh -n media get svc radarr -o jsonpath='{.spec.clusterIP}'; echo`

Use this IP in PROWLARR when defining app connection to RADARR. Should work.

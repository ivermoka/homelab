# This is docs to DHCP reservation & finding default gateway

Run `ip route show` / `ip r s` to check the routing table.

Can find the default gateway as `default via <xxxx>`


Enter it, `home` + `home` (user/pass) usually


HOME -> My Homebox -> LAN -> DHCP -> DHCP Reservation

Enter the MAC address of the device you want to reserve an IP for, and assign it a specific IP address within your network range.
(This can be found on the device itself or in its network settings.)
I.e. the node / worker's MAC adress

This is to not have workers / nodes change IP addresses when they reboot or reconnect to the network, which can cause issues with communication and management.


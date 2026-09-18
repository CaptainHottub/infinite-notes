# Nearby server discovery

Start the server normally on the laptop hotspot, or with `--no-hotspot` on the
desktop. On the iPad, open **Settings → Connection → Nearby servers**, allow
Local Network access if prompted, and tap the computer you want to use. No IP
address needs to be typed. If both computers are available, each is listed.

The selected `.local` hostname and port are saved in the existing address
setting and used on the next app launch. Discovery never switches servers
automatically while you are working. To move between computers, select the
other computer in Nearby servers. This selects a server; it does not transfer
notebooks between computers.

## Updating existing installations

Install the updated dependencies on each computer:

```sh
computer/.venv/bin/python -m pip install -r computer/requirements.txt
```

Restart the server with your usual command. The laptop continues to use
`./scripts/run-computer.sh`; the desktop continues to use
`./scripts/run-computer.sh --no-hotspot`. Build/install the updated iPad app
with the existing `./scripts/build-ipad.sh` workflow.

If discovery finds nothing, check that the iPad and computer are on the same
network and the server is running, then tap **Refresh**. Local firewalls need
to allow mDNS (UDP 5353) and the server's TCP port (normally 8000). Some campus
networks block multicast discovery. Manual addresses remain available:
`http://10.42.0.1:8000` for the laptop hotspot and `http://10.0.0.81:8000` for
the current desktop LAN setup.

## Implementation and limits

The Python launcher advertises `_infinite-notes._tcp.local.` with its actual
port and IPv4 interface addresses. A specific `--host` restricts advertised
addresses to that binding; loopback-only servers are not advertised. Registration
and withdrawal run off the server event loop. Discovery failure leaves ordinary
HTTP/WebSocket access available. Direct `uvicorn server:app` launches do not
advertise because their port is not known to the application.

The iPad uses NetServiceBrowser and resolves services to local hostnames. The
app declares its Bonjour service type and local-network purpose in Info.plist.
Browsing stops when the Connection tab closes. Server interfaces are collected
at startup; restart the server after changing its network interfaces or IP
addresses. IPv6-only discovery is not implemented.

## Validation (2026-09-17)

- `timeout 240 ./scripts/test-all.sh`: 160 Python tests passed, plus iPad
  package validation and all three native Swift test programs.
- `xtool dev build` from `ipad/`: built the app against the iOS SDK successfully.
- A real temporary server with a dynamically selected port was discovered
  through multicast, resolved, fetched over HTTP, and withdrawn on shutdown.

Device acceptance remains: install the app, select each computer from Nearby
servers, confirm the notebook loads, and check manual entry still works. The
build has not been installed on an iPad by this validation.

API references: [python-zeroconf](https://python-zeroconf.readthedocs.io/en/latest/api.html)
and [Apple Bonjour discovery](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/Discovering,Browsing,AndAdvertisingNetworkServices/Discovering,Browsing,AndAdvertisingNetworkServices.html).

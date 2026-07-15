# Rethink

Rethink replaces LG ThinQ's cloud endpoint with a server on your local network and publishes compatible appliances to Home Assistant through MQTT discovery. This add-on is based on [anszom/rethink](https://github.com/anszom/rethink), pinned to upstream commit `3f24361871d102183daa68d37120e3897b7b7036`.

It is experimental. Do not install it until you have a recovery plan for each appliance's Wi-Fi settings.

## What this add-on does

- Runs the Rethink ThinQ server entirely on Home Assistant OS.
- Obtains MQTT connection details from the Supervisor MQTT service; no MQTT password is entered in add-on configuration.
- Stores its generated TLS certificate and configuration in the persistent add-on data volume.
- Leaves Rethink's optional bridge-to-LG-cloud mode disabled.

## What it does not do

- It cannot configure the AC's Wi-Fi from Home Assistant. A laptop with Wi-Fi must join the appliance's temporary setup network and run Rethink's provisioning utility.
- It cannot create the DNS override or port redirection required during provisioning. Configure those in the network layer.
- It does not block appliance Internet access. Apply a firewall policy on the IoT network after provisioning so the appliance can reach only Home Assistant and local DNS.

## Network requirements

Choose a stable local DNS name, such as `rethink.lan`, and set it as `hostname` here. It must resolve to the Home Assistant IP address for the AC.

During initial provisioning, Rethink requires `common.lgthinq.com` to resolve to Home Assistant. This add-on listens on TCP port 443 directly, so no router-level destination-port translation is required for HTTPS. Scope the temporary DNS record to the pilot window and remove it when provisioning succeeds unless Rethink's upstream instructions say it is still needed for that appliance generation.

The add-on exposes these appliance-facing ports:

| Port | Purpose |
|---|---|
| 443/TCP | ThinQ2 HTTPS |
| 8890/TCP | ThinQ2 secure MQTT listener on HAOS and the port Rethink advertises to the appliance. |
| 46030/TCP | ThinQ1 HTTPS, legacy devices only |
| 47878/TCP | ThinQ1 secure MQTT, legacy devices only |

Keep these reachable only from the AC/IoT network. Do not publish them through a Cloudflare tunnel or expose them to the Internet.

No destination-NAT rule is needed: Rethink advertises TCP port `8890` directly. Keep this port reachable only from the AC/IoT network and leave Home Assistant Mosquitto's host port `8883` unchanged.

Some ThinQ2 firmware, including the tested LP1021BSSM, sends its first `req_timesync` before (and without) `completeProvisioning_ack`. This add-on carries a narrow upstream patch that accepts that request as the provisioning completion signal, then returns the required time response.

## Setup

1. Install and start the Mosquitto broker app, then make sure Home Assistant's MQTT integration has discovery enabled.
2. Install and start Rethink. Confirm its log says `HA mqtt connection established`.
3. Configure the scoped DNS above.
4. Put one AC into LG Wi-Fi setup mode, connect a laptop to the AC's temporary Wi-Fi network, then run the upstream `rethink-setup` tool from that laptop.
5. Confirm the appliance appears as a Home Assistant MQTT-discovered device and validate controls before repeating for the second AC.
6. Block WAN egress for the AC at the network gateway and verify that local control survives a restart.

## Configuration

| Option | Default | Purpose |
|---|---|---|
| `hostname` | `rethink.lan` | Local DNS hostname presented to the LG appliance. It must not be an IP address. |
| `discovery_prefix` | `homeassistant` | MQTT discovery prefix used by Home Assistant. |
| `rethink_prefix` | `rethink` | Prefix for Rethink's MQTT state and command topics. |
| `debug` | `false` | Enables detailed appliance and MQTT protocol logging. Enable only while troubleshooting. |

## Compatibility

Upstream lists LG portable model LP1022FVSM as mostly working. The LP1021BSSM is not yet listed, so treat the first unit as a protocol-validation pilot.

## Recovery

Reset the AC's Wi-Fi configuration and use LG's ordinary setup process if you decide to revert. This add-on does not modify the appliance firmware.

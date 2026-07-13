#!/usr/bin/with-contenv bashio

set -euo pipefail

HOSTNAME=$(bashio::config 'hostname')
DISCOVERY_PREFIX=$(bashio::config 'discovery_prefix')
RETHINK_PREFIX=$(bashio::config 'rethink_prefix')
DEBUG=$(bashio::config 'debug')

MQTT_HOST=$(bashio::services mqtt 'host')
MQTT_PORT=$(bashio::services mqtt 'port')
MQTT_USER=$(bashio::services mqtt 'username')
MQTT_PASSWORD=$(bashio::services mqtt 'password')

if bashio::var.is_empty "${HOSTNAME}"; then
    bashio::exit.nok "hostname is required"
fi

if bashio::var.is_empty "${MQTT_HOST}" || bashio::var.is_empty "${MQTT_PORT}"; then
    bashio::exit.nok "A Home Assistant MQTT service is required"
fi

if bashio::var.true "${DEBUG}"; then
    LOG_FILTER='["status","incoming","HTTPS","publish"]'
else
    LOG_FILTER='["status"]'
fi

mkdir -p /data

node -e '
const fs = require("node:fs")
const [target, hostname, mqttHost, mqttPort, mqttUser, mqttPass, discoveryPrefix, rethinkPrefix, log] = process.argv.slice(1)
fs.writeFileSync(target, JSON.stringify({
  hostname,
  homeassistant: {
    mqtt_url: `mqtt://${mqttHost}:${mqttPort}`,
    discovery_prefix: discoveryPrefix,
    rethink_prefix: rethinkPrefix,
    mqtt_user: mqttUser,
    mqtt_pass: mqttPass,
  },
  ca_key_file: "ca.key",
  ca_cert_file: "ca.cert",
  https_port: 4433,
  mqtts_port: 8884,
  mqtt_port: 1884,
  thinq1_https_port: 46030,
  thinq1_port: 47878,
  log: JSON.parse(log),
}, null, 2))
' /data/config.json "${HOSTNAME}" "${MQTT_HOST}" "${MQTT_PORT}" "${MQTT_USER}" "${MQTT_PASSWORD}" "${DISCOVERY_PREFIX}" "${RETHINK_PREFIX}" "${LOG_FILTER}"

bashio::log.info "Starting local-only Rethink server for ${HOSTNAME}"
bashio::log.info "Home Assistant MQTT discovery prefix: ${DISCOVERY_PREFIX}"
bashio::log.info "Rethink MQTT prefix: ${RETHINK_PREFIX}"
bashio::log.warning "Configure DNS and port redirection before provisioning an appliance; this add-on never enables Rethink bridge mode."

exec node /app/dist/rethink-cloud.js /data/config.json

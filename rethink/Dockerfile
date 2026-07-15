ARG BUILD_ARCH=amd64

FROM node:22-bookworm-slim AS build

ARG RETHINK_REF=3f24361871d102183daa68d37120e3897b7b7036

COPY patches/thinq2-accept-timesync-without-provisioning-ack.patch /tmp/
COPY patches/thinq2-control-diagnostics.patch /tmp/
COPY patches/thinq2-post-command-state-refresh.patch /tmp/
COPY patches/thinq2-poll-physical-panel-state.patch /tmp/

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/anszom/rethink.git /src \
    && cd /src \
    && git checkout "${RETHINK_REF}" \
    && test "$(git rev-parse HEAD)" = "${RETHINK_REF}" \
    && git apply --check /tmp/thinq2-accept-timesync-without-provisioning-ack.patch \
    && git apply /tmp/thinq2-accept-timesync-without-provisioning-ack.patch \
    && git apply --check /tmp/thinq2-control-diagnostics.patch \
    && git apply /tmp/thinq2-control-diagnostics.patch \
    && git apply --check /tmp/thinq2-post-command-state-refresh.patch \
    && git apply /tmp/thinq2-post-command-state-refresh.patch \
    && git apply --check /tmp/thinq2-poll-physical-panel-state.patch \
    && git apply /tmp/thinq2-poll-physical-panel-state.patch

WORKDIR /src

RUN npm ci --ignore-scripts \
    && npm run build \
    && npm prune --omit=dev

FROM ghcr.io/home-assistant/${BUILD_ARCH}-base-debian:bookworm

LABEL \
    io.hass.type="addon" \
    io.hass.arch="aarch64|amd64" \
    org.opencontainers.image.source="https://github.com/alexlmiller/ha-addons"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/node /usr/local/bin/node
COPY --from=build /src/node_modules /app/node_modules
COPY --from=build /src/dist /app/dist
COPY rootfs/ /

RUN chmod a+x /run.sh

CMD ["/run.sh"]

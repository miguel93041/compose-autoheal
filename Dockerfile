# Only the Docker CLI and the script. The base is pinned so it changes when this file does;
# there is no RUN step, so both platforms build without emulation.
FROM docker:29-cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d
COPY autoheal.sh /usr/local/bin/autoheal
# The script marks every pass; raise this window when AUTOHEAL_INTERVAL goes above a few minutes.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD find /state/alive -mmin -5 | grep -q .
ENTRYPOINT ["/bin/sh", "/usr/local/bin/autoheal"]

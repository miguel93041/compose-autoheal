#!/bin/sh
# Restarts unhealthy containers labelled autoheal=true, unless a service they require is not healthy
# itself, and at most AUTOHEAL_MAX_RESTARTS times per AUTOHEAL_WINDOW seconds each.
set -eu
interval="${AUTOHEAL_INTERVAL:-60}"
max="${AUTOHEAL_MAX_RESTARTS:-3}"
window="${AUTOHEAL_WINDOW:-3600}"
stop_timeout="${AUTOHEAL_STOP_TIMEOUT:-60}"
state="${AUTOHEAL_STATE:-/state}"

now() { date -u +%FT%TZ; }
label() { docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1"; }
# A container without a health check counts as healthy while it runs.
health() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"; }

# Logs why a container is left alone once, not on every pass.
note() {
    [ "$(cat "$state/$1.note" 2>/dev/null || true)" != "$2" ] || return 0
    echo "$2" > "$state/$1.note"
    echo "$(now) $1: $2"
}

pass() {
    rm -f "$state"/*.seen
    for id in $(docker ps -q --filter health=unhealthy --filter label=autoheal=true $scope); do
        name="$(docker inspect --format '{{.Name}}' "$id" | cut -c2-)"
        touch "$state/$name.seen"

        # A required service that is not healthy explains the failure, and a restart would not fix it.
        waiting=''
        for service in $(label "$id" autoheal.requires); do
            required="$(docker ps -aq --filter "label=com.docker.compose.project=$(label "$id" com.docker.compose.project)" \
                --filter "label=com.docker.compose.service=$service" | head -1)"
            status=missing
            [ -z "$required" ] || status="$(health "$required")"
            case "$status" in
                healthy|running) ;;
                *) waiting="$waiting $service ($status)" ;;
            esac
        done
        if [ -n "$waiting" ]; then
            note "$name" "unhealthy, not restarted: waiting for$waiting"
            continue
        fi

        # One line per restart; only those inside the window count.
        seconds="$(date +%s)"
        touch "$state/$name.restarts"
        awk -v since="$((seconds - window))" '$1 > since' "$state/$name.restarts" > "$state/$name.tmp"
        mv "$state/$name.tmp" "$state/$name.restarts"
        if [ "$(wc -l < "$state/$name.restarts")" -ge "$max" ]; then
            note "$name" "unhealthy, not restarted: $max restarts in the last $window seconds did not fix it"
            continue
        fi
        echo "$seconds" >> "$state/$name.restarts"
        rm -f "$state/$name.note"
        echo "$(now) $name: unhealthy, restarting"
        docker restart -t "$stop_timeout" "$id" > /dev/null || echo "$(now) $name: restart failed"
    done
    # A container that recovered gets its reason logged again the next time it fails.
    for file in "$state"/*.note; do
        [ -e "$file" ] || continue
        [ -e "${file%.note}.seen" ] || rm -f "$file"
    done
}

mkdir -p "$state"
# Only the Compose project this container belongs to; every labelled container when run outside Compose.
project="$(label "$(hostname)" com.docker.compose.project 2>/dev/null || true)"
scope=''
[ -z "$project" ] || scope="--filter label=com.docker.compose.project=$project"
echo "$(now) watching ${project:-every project} every $interval seconds"

trap 'exit 0' TERM INT
while :; do
    pass || echo "$(now) pass failed; retrying on the next one"
    # Read by the image's health check.
    touch "$state/alive"
    sleep "$interval" &
    wait "$!"
done

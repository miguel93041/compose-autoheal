#!/bin/sh
# Restarts unhealthy containers labelled autoheal=true, unless a service they require is not healthy
# itself, and at most AUTOHEAL_MAX_RESTARTS times per AUTOHEAL_WINDOW seconds each. A container with
# required services is restarted only when a second pass still finds it unhealthy.
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
            rm -f "$state/$name.due"
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

        # A required service may have only just come back. Docker keeps the container unhealthy until
        # its next check passes, so it gets one more pass to reconnect by itself before a restart.
        if [ -n "$(label "$id" autoheal.requires)" ] && [ ! -e "$state/$name.due" ]; then
            touch "$state/$name.due"
            note "$name" "unhealthy with its required services healthy: restarting on the next pass unless it recovers"
            continue
        fi
        echo "$seconds" >> "$state/$name.restarts"
        rm -f "$state/$name.note" "$state/$name.due"
        echo "$(now) $name: unhealthy, restarting"
        docker restart -t "$stop_timeout" "$id" > /dev/null || echo "$(now) $name: restart failed"
    done
    # A container that recovered starts afresh the next time it fails: its reason is logged again and
    # it gets its extra pass again.
    for file in "$state"/*.note "$state"/*.due; do
        [ -e "$file" ] || continue
        [ -e "${file%.*}.seen" ] || rm -f "$file"
    done
}

mkdir -p "$state"
# Only the Compose project this container belongs to, unless AUTOHEAL_ALL_PROJECTS says otherwise;
# every labelled container when run outside Compose.
project="$(label "$(hostname)" com.docker.compose.project 2>/dev/null || true)"
case "${AUTOHEAL_ALL_PROJECTS:-false}" in
    true) project='' ;;
    false) ;;
    *) echo 'AUTOHEAL_ALL_PROJECTS must be true or false.' >&2; exit 1 ;;
esac
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

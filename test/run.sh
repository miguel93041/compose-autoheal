#!/bin/sh
# Builds the image and checks the three rules against containers that turn unhealthy on purpose.
set -eu
cd "$(dirname "$0")"
dc() { docker compose "$@"; }
trap 'dc down --volumes --timeout 1 > /dev/null 2>&1' EXIT

starts() { dc exec -T "$1" sh -c 'wc -l < /starts' | tr -d ' '; }
health() { docker inspect --format '{{.State.Health.Status}}' "$(dc ps -q "$1")"; }
fail() { echo "FAIL: $1" >&2; dc logs autoheal >&2; exit 1; }
# wait_for <seconds> <description> <command...>
wait_for() {
    limit="$1"; what="$2"; shift 2
    while [ "$limit" -gt 0 ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        sleep 1
        limit=$((limit - 1))
    done
    fail "$what"
}
started() { [ "$(starts "$1")" = "$2" ]; }
healthy() { [ "$(health "$1")" = healthy ]; }
unhealthy() { [ "$(health "$1")" = unhealthy ]; }

dc up --detach --build --quiet-pull
for service in hung unlabelled database dependent; do
    wait_for 30 "$service never became healthy" healthy "$service"
done

echo '1. An unhealthy labelled container is restarted and recovers'
dc exec -T hung rm /tmp/ok
wait_for 30 'hung was not restarted' started hung 2
wait_for 30 'hung did not recover' healthy hung

echo '2. A container without the label is left alone'
dc exec -T unlabelled rm /tmp/ok
wait_for 30 'unlabelled never became unhealthy' unhealthy unlabelled
sleep 8
started unlabelled 1 || fail 'unlabelled was restarted'

echo '3. Nothing is restarted while a required service is unhealthy'
dc exec -T database rm /tmp/ok
dc exec -T dependent rm /tmp/ok
wait_for 30 'dependent never became unhealthy' unhealthy dependent
sleep 8
started dependent 1 || fail 'dependent was restarted while database was unhealthy'
started database 1 || fail 'database was restarted'
dc logs autoheal | grep -q 'dependent-1: unhealthy, not restarted: waiting for database (unhealthy)' \
    || fail 'the reason for waiting was not logged'

echo '4. Once the required service is healthy again, the container is restarted'
dc exec -T database touch /tmp/ok
wait_for 30 'dependent was not restarted after database recovered' started dependent 2
wait_for 30 'dependent did not recover' healthy dependent

echo '5. A container that restarting does not fix is restarted three times, then left alone'
wait_for 60 'broken did not reach its restart limit' started broken 4
sleep 8
started broken 4 || fail 'broken was restarted beyond the limit'
dc logs autoheal | grep -q 'broken-1: unhealthy, not restarted: 3 restarts' || fail 'the restart limit was not logged'

echo '6. Stopping takes effect at once'
before="$(date +%s)"
dc stop --timeout 10 autoheal > /dev/null 2>&1
[ "$(( $(date +%s) - before ))" -lt 5 ] || fail 'autoheal ignored the stop signal'

echo 'All checks passed.'

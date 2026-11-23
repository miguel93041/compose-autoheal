#!/bin/sh
# Builds the image and checks its rules against containers that turn unhealthy on purpose.
set -eu
cd "$(dirname "$0")"
dc() { docker compose "$@"; }
other() { docker compose --file other.compose.yaml "$@"; }
trap 'dc down --volumes --timeout 1 > /dev/null 2>&1; other down --volumes --timeout 1 > /dev/null 2>&1' EXIT

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
logged() { dc logs autoheal | grep -q "$1"; }
outsider_starts() { other exec -T outsider sh -c 'wc -l < /starts' | tr -d ' '; }
outsider_started() { [ "$(outsider_starts)" = "$1" ]; }
outsider_is() { [ "$(docker inspect --format '{{.State.Health.Status}}' "$(other ps -q outsider)")" = "$1" ]; }
# Longer than two passes (AUTOHEAL_INTERVAL is 6 here), so "nothing happened" really had its chance.
two_passes=14

dc up --detach --build --quiet-pull
other up --detach --quiet-pull
for service in hung unlabelled database dependent; do
    wait_for 30 "$service never became healthy" healthy "$service"
done
wait_for 30 'outsider never became healthy' outsider_is healthy

echo '1. An unhealthy labelled container is restarted and recovers'
dc exec -T hung rm /tmp/ok
wait_for 30 'hung was not restarted' started hung 2
wait_for 30 'hung did not recover' healthy hung

echo '2. A container without the label is left alone'
dc exec -T unlabelled rm /tmp/ok
wait_for 30 'unlabelled never became unhealthy' unhealthy unlabelled
sleep "$two_passes"
started unlabelled 1 || fail 'unlabelled was restarted'

echo '3. Nothing is restarted while a required service is unhealthy'
dc exec -T database rm /tmp/ok
dc exec -T dependent rm /tmp/ok
wait_for 30 'dependent never became unhealthy' unhealthy dependent
sleep "$two_passes"
started dependent 1 || fail 'dependent was restarted while database was unhealthy'
started database 1 || fail 'database was restarted'
logged 'dependent-1: unhealthy, not restarted: waiting for database (unhealthy)' \
    || fail 'the reason for waiting was not logged'

echo '4. A container that recovers by itself once its required service is back is not restarted'
dc exec -T database touch /tmp/ok
wait_for 30 'dependent was not given its extra pass' \
    logged 'dependent-1: unhealthy with its required services healthy: restarting on the next pass unless it recovers'
dc exec -T dependent touch /tmp/ok
wait_for 30 'dependent did not recover by itself' healthy dependent
sleep "$two_passes"
started dependent 1 || fail 'dependent was restarted although it recovered by itself'
! logged 'dependent-1: unhealthy, restarting' || fail 'a restart of dependent was logged'

echo '5. One that stays unhealthy with its required service healthy is restarted on the following pass'
dc exec -T dependent rm /tmp/ok
wait_for 30 'dependent was not restarted' started dependent 2
wait_for 30 'dependent did not recover' healthy dependent

echo '6. A container that restarting does not fix is restarted three times, then left alone'
wait_for 60 'broken did not reach its restart limit' started broken 4
sleep "$two_passes"
started broken 4 || fail 'broken was restarted beyond the limit'
logged 'broken-1: unhealthy, not restarted: 3 restarts' || fail 'the restart limit was not logged'

echo '7. A labelled container of another Compose project is left alone'
other exec -T outsider rm /tmp/ok
wait_for 30 'outsider never became unhealthy' outsider_is unhealthy
sleep "$two_passes"
outsider_started 1 || fail 'a container of another project was restarted'

echo '8. With AUTOHEAL_ALL_PROJECTS=true it is restarted too'
AUTOHEAL_ALL_PROJECTS=true dc up --detach autoheal > /dev/null 2>&1
wait_for 30 'the scope was not logged' logged 'watching every project'
wait_for 30 'outsider was not restarted' outsider_started 2
wait_for 30 'outsider did not recover' outsider_is healthy

echo '9. Stopping takes effect at once'
before="$(date +%s)"
dc stop --timeout 10 autoheal > /dev/null 2>&1
[ "$(( $(date +%s) - before ))" -lt 5 ] || fail 'autoheal ignored the stop signal'

echo 'All checks passed.'

# compose-autoheal

Restarts Docker Compose containers that Docker reports as unhealthy. Docker itself only marks them.

It differs from the usual autoheal images in two rules that stop restart loops:

- **Required services.** A container is not restarted while a service it depends on is unhealthy.
  If the database goes down and the API's health check fails because of it, restarting the API
  would not help; the API is left alone and recovers on its own when the database returns.
- **A limit.** A container is restarted at most three times an hour. One that restarting does not
  fix is then left as it is, for a person to look at.

## Use

Add the service to a Compose file and label the containers it may restart:

```yaml
services:
  autoheal:
    image: ghcr.io/miguel93041/compose-autoheal:1.0.0
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    network_mode: none
    read_only: true
    tmpfs: [/state]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 128m
    pids_limit: 64

  api:
    labels:
      autoheal: "true"
      autoheal.requires: db

  web:
    labels:
      autoheal: "true"

  db: {} # No label: never restarted.
```

| Label | Meaning |
| --- | --- |
| `autoheal: "true"` | This container may be restarted when it is unhealthy. It needs a health check. |
| `autoheal.requires` | Compose service names, separated by spaces. The container is not restarted unless all of them are healthy (or running, when they define no health check). |

Only containers of the same Compose project are watched. Run outside Compose, it watches every
labelled container on the host.

Do not label containers that hold data (databases, queues, object storage). An unhealthy data
store needs a person, not a blind restart.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTOHEAL_INTERVAL` | `60` | Seconds between passes. |
| `AUTOHEAL_MAX_RESTARTS` | `3` | Restarts allowed per container inside the window. |
| `AUTOHEAL_WINDOW` | `3600` | Length of that window, in seconds. |
| `AUTOHEAL_STOP_TIMEOUT` | `60` | Seconds a container gets to stop before it is killed. |

The count of restarts lives in `/state` (a tmpfs above), so recreating this container resets it.

## What it logs

```text
2026-11-21T16:32:50Z watching smm every 60 seconds
2026-11-21T16:40:02Z smm-api-1: unhealthy, restarting
2026-11-21T17:05:01Z smm-api-1: unhealthy, not restarted: waiting for db (unhealthy)
2026-11-21T18:10:03Z smm-web-1: unhealthy, not restarted: 3 restarts in the last 3600 seconds did not fix it
```

The reason a container is left alone is logged once, not on every pass.

## Security

The Docker socket gives this container full control of the host's Docker, which is equivalent to
root on that host. That is why the service above has no network, a read-only file system and no
capabilities, and why the image holds only the Docker CLI and one shell script. The base image is
pinned by digest in the `Dockerfile`; update it deliberately.

## Build

Every push runs `test/run.sh`, which starts containers that turn unhealthy on purpose and checks
each rule, and then publishes the image to `ghcr.io` for `linux/amd64` and `linux/arm64`:

| Push | Image tag |
| --- | --- |
| `main` | `main` and `sha-<commit>` |
| a tag `v1.2.3` | `1.2.3` and `sha-<commit>` |

Run the same check locally with `sh test/run.sh` (it needs Docker with Compose).

# Self-Hosted Runner — Complete Deep Dive

> A complete walkthrough of every file, every step, and how to test everything
> end-to-end on your local machine before ever touching an EC2 instance.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [File-by-File Breakdown](#2-file-by-file-breakdown)
3. [Dockerfile — Layer by Layer](#3-dockerfile--layer-by-layer)
4. [entrypoint.sh — Step by Step](#4-entrypointsh--step-by-step)
5. [docker-compose.yaml — Deep Dive](#5-docker-composeyaml--deep-dive)
6. [The DooD Pattern (Docker-outside-of-Docker)](#6-the-dood-pattern-docker-outside-of-docker)
7. [Local End-to-End Testing Guide](#7-local-end-to-end-testing-guide)
8. [What Happens When a Workflow Fires](#8-what-happens-when-a-workflow-fires)
9. [Debugging Cheatsheet](#9-debugging-cheatsheet)
10. [Before Going to EC2](#10-before-going-to-ec2)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Your machine (or EC2 instance)  — HOST                          │
│                                                                  │
│  Docker daemon (/var/run/docker.sock)                            │
│       │                                                          │
│       ├─── runner container  (this image)                        │
│       │         • mounts host's docker.sock                      │
│       │         • entrypoint.sh → registers with GitHub          │
│       │         • runs ONE job  →  exits                         │
│       │         • restart: unless-stopped → loops                │
│       │                                                          │
│       ├─── test containers  (SIBLINGS, not children)             │
│       │    created by the runner job via `docker compose`        │
│       │    on the HOST daemon directly                           │
│       │                                                          │
│       └─── redis container                                       │
│            started by lib/lib-global-services.sh                 │
└──────────────────────────────────────────────────────────────────┘
              │  registers / polls
              ▼
       GitHub Actions API
       github.com/libp2p/unified-testing/settings/actions/runners
```

**Key insight:** The runner container does NOT run Docker-in-Docker (DinD). It
mounts the host's `/var/run/docker.sock` so every `docker` or `docker compose`
command inside the runner actually talks to the **host** daemon. All test
containers are siblings of the runner container, which means they share the
host network and filesystem path space.

---

## 2. File-by-File Breakdown

| File | Role |
|------|------|
| `Dockerfile` | Defines what goes INTO the image — OS, tools, runner binary |
| `entrypoint.sh` | Runs at container startup — registers the runner with GitHub, then hands off to `run.sh` |
| `docker-compose.yaml` | Describes HOW to run the container — env vars, volumes, restart policy |
| `env` | Template for secrets — copy to `.env`, never commit |
| `README.md` | Human-readable quickstart |

---

## 3. Dockerfile — Layer by Layer

```
FROM debian:13-slim          ← tiny Debian "trixie" base (~30 MB)
```

### Layer 1 — Environment variables

```dockerfile
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=1
```

- `DEBIAN_FRONTEND=noninteractive` — stops apt from pausing for keyboard input
  during `apt-get install`.
- `RUNNER_ALLOW_RUNASROOT=1` — GitHub's runner binary normally refuses to run
  as root. This env var overrides that behaviour. Needed because the container
  runs as root by default.

---

### Layer 2 — Tool installation (the big RUN block)

This is a single chained `RUN` command (= a single Docker layer) to keep the
image small.

**Phase 1: Bootstrap tools**
```
ca-certificates  curl  gnupg
```
These are needed only to download and verify the Docker and GitHub CLI GPG
keys. They are installed first so the keys can be added.

**Phase 2: Add external apt repositories**

```
Docker official:   https://download.docker.com/linux/debian   (trixie/stable)
GitHub CLI:        https://cli.github.com/packages             (stable)
```

Both repos publish signed packages. Their GPG keys are stored under
`/etc/apt/keyrings/` — the modern, per-repo location (replaces the old
`/etc/apt/trusted.gpg.d/` pattern).

**Phase 3: Final tool list**

| Package | Why it's needed |
|---------|-----------------|
| `docker-ce` + `docker-ce-cli` | Full Docker CLI so the runner can run `docker build` / `docker compose` |
| `docker-buildx-plugin` | BuildKit-powered multi-platform builds (`docker buildx`) |
| `docker-compose-plugin` | `docker compose` v2 (runs as a plugin, not standalone binary) |
| `containerd.io` | Low-level container runtime that Docker CE needs |
| `gh` | GitHub CLI — used by some workflow steps for releases, PRs, etc. |
| `git` | Clone repos inside jobs |
| `jq` | JSON parsing — used heavily in the test framework shell scripts |
| `yq` | YAML parsing — see separate install step below |
| `gnuplot` | Generates performance graphs |
| `pandoc` | Converts markdown reports to other formats |
| `bc` | Floating-point arithmetic in bash scripts |
| `openssh-client` | SSH to other hosts from workflow steps |
| `aws-cli` (separate step) | Upload results to S3 |
| `libssl3`, `libicu76`, etc. | Runtime libraries the GitHub runner binary itself needs |

**BuildKit default**

```dockerfile
RUN mkdir -p /root/.docker && \
    echo '{ "features": { "buildkit": "true" } }' > /root/.docker/config.json
```

Without this, `docker build` uses the legacy builder. This file forces BuildKit
for every `docker build` invocation without needing `DOCKER_BUILDKIT=1` in
front of every command.

---

### Layer 3 — yq (YAML processor)

```dockerfile
ENV YQ_VERSION=v4.49.2
RUN arch=$(dpkg --print-architecture) && \
    curl -L --fail -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" && \
    chmod +x /usr/local/bin/yq
```

`yq` is a single static binary (Go). It reads the `images.yaml` and
`test-matrix.yaml` files in the test framework. `arch=$(dpkg --print-architecture)`
makes this work on both `amd64` and `arm64` hosts automatically.

---

### Layer 4 — AWS CLI v2

```dockerfile
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ...
```

Used by the `daily-full-interop.yml` workflow to upload results bundles to S3.
Note: currently hardcoded to `x86_64`. If you need ARM support you'd need to
change this URL.

---

### Layer 5 — GitHub Actions runner binary

```dockerfile
ARG RUNNER_VERSION=2.330.0
WORKDIR /actions-runner
RUN curl -L -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/..." && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz && \
    ./bin/installdependencies.sh
```

- `ARG RUNNER_VERSION` — lets you override the version at build time:
  `docker build --build-arg RUNNER_VERSION=2.331.0 .`
- `./bin/installdependencies.sh` — official script that installs any remaining
  OS dependencies the runner binary needs (ICU, lttng, etc.).
- After this step `/actions-runner/` contains the full runner: `config.sh`,
  `run.sh`, `bin/`, `externals/`, etc.

---

### Layer 6 — Entrypoint

```dockerfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

Using `ENTRYPOINT` in exec form (JSON array) means the shell does NOT wrap the
command. PID 1 is `/entrypoint.sh` directly, so Docker signals (`SIGTERM` on
`docker stop`) reach the script cleanly.

---

## 4. entrypoint.sh — Step by Step

This script runs **every time the container starts** (including after each
restart). Here is exactly what happens:

```
Container starts
      │
      ▼
Step 1: Print banner (cosmetic)
      │
      ▼
Step 2: Validate environment variables
        ─ REPO_URL  OR  (ORG_NAME + RUNNER_SCOPE=org)  must be set
        ─ ACCESS_TOKEN must be set
        If either check fails → exit 1 → container exits → Docker restarts it
        (Docker will keep restarting until the env vars are provided)
      │
      ▼
Step 3: Build the GitHub API URL
        if REPO_URL is set:
          owner = 2nd-to-last path segment of URL
          repo  = last path segment of URL
          TOKEN_API = https://api.github.com/repos/{owner}/{repo}/actions/runners/registration-token
          RUNNER_URL = REPO_URL

        if RUNNER_SCOPE=org and ORG_NAME is set:
          TOKEN_API = https://api.github.com/orgs/{ORG_NAME}/actions/runners/registration-token
          RUNNER_URL = https://github.com/{ORG_NAME}
      │
      ▼
Step 4: Exchange PAT for short-lived registration token
        curl -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" ${TOKEN_API}
        → returns a one-time token valid for ~1 hour
        This token is stored in $reg_token
        (Your PAT never touches the runner config — it is only used here)
      │
      ▼
Step 5: Configure the runner
        ./config.sh \
          --url  ${RUNNER_URL}   ← which repo/org to register with
          --token ${reg_token}   ← the short-lived token
          --name  ${name}        ← "ephemeral-<hostname>-<random>" by default
          --ephemeral            ← runner deregisters after ONE job
          --unattended           ← no interactive prompts
          --replace              ← if a stale runner with same name exists, replace it
          --disableupdate        ← don't let the runner self-update (version is pinned in Dockerfile)
          --labels "${LABELS}"   ← optional, e.g. "self-hosted,linux,x64,ephemeral"
      │
      ▼
Step 6: Start the runner
        exec ./run.sh
        ← exec replaces the shell process. run.sh becomes PID 1's child.
        ← The runner polls GitHub for a job.
        ← When a job arrives, it runs it.
        ← When the job finishes, run.sh exits (because --ephemeral).
        ← The container exits.
        ← Docker restarts it (restart: unless-stopped).
        ← entrypoint.sh runs again from Step 1.
```

### Why `--ephemeral`?

Without `--ephemeral`, the runner stays registered after the job and picks up
the next one. That sounds convenient but causes problems:

- Leftover files, docker images, and env state bleed into the next job.
- Secrets set as env vars in one job can leak to the next.
- The runner binary can decide to auto-update itself, breaking the pinned version.

With `--ephemeral`, every job gets a factory-fresh container. The slight
overhead (a few seconds for re-registration) is worth the isolation.

### Why `--disableupdate`?

The runner binary can self-update from GitHub. If it does, your pinned version
(`RUNNER_VERSION=2.330.0`) is overwritten. By disabling updates you keep
deterministic behaviour. To upgrade: bump `RUNNER_VERSION` in the Dockerfile
and rebuild.

---

## 5. docker-compose.yaml — Deep Dive

```yaml
services:
  runner-unified-testing:
    image: ghcr.io/<username>/libp2p-gh-runner:latest
```

This is the image you pushed to GitHub Container Registry. You can also use a
local image tag (e.g. `libp2p-gh-runner:local`) for local testing.

---

```yaml
    restart: unless-stopped
```

| Value | Meaning |
|-------|---------|
| `no` | Never restart |
| `always` | Restart even after `docker compose down` + `up` |
| `on-failure` | Restart only on non-zero exit |
| **`unless-stopped`** | Restart on any exit **unless** you explicitly ran `docker compose down` |

`unless-stopped` is the correct choice here: it keeps the runner alive through
crashes and job completions, but doesn't start automatically on boot unless you
set `docker compose` to start on boot yourself.

---

```yaml
    container_name: ${RUNNER_NAME}-unified-testing
```

Names the container. Useful for `docker logs <name>`, `docker exec <name> bash`
without needing to look up the container ID.

---

```yaml
    environment:
      RUNNER_ALLOW_RUNASROOT: true
      EPHEMERAL: true
      DISABLE_AUTO_UPDATE: true
      REPO_URL: https://github.com/libp2p/unified-testing
      RUNNER_NAME: ${RUNNER_NAME}-unified-testing
      ACCESS_TOKEN: ${ACCESS_TOKEN}
      RUNNER_SCOPE: 'repo'
      LABELS: 'self-hosted,linux,x64,ephemeral'
```

| Variable | Used by | Purpose |
|----------|---------|---------|
| `RUNNER_ALLOW_RUNASROOT` | runner binary | Allow running as root |
| `EPHEMERAL` | entrypoint (informational) | Documents intent; actual flag is `--ephemeral` in config.sh |
| `DISABLE_AUTO_UPDATE` | entrypoint (informational) | Actual flag is `--disableupdate` in config.sh |
| `REPO_URL` | entrypoint.sh | Which repo to register with |
| `RUNNER_NAME` | entrypoint.sh | Display name in GitHub UI |
| `ACCESS_TOKEN` | entrypoint.sh | PAT for getting registration token |
| `RUNNER_SCOPE` | entrypoint.sh | `repo` or `org` |
| `LABELS` | entrypoint.sh | Labels the runner advertises (workflows use `runs-on` to select) |

`${RUNNER_NAME}` and `${ACCESS_TOKEN}` are substituted from the `.env` file
that Docker Compose loads automatically if it exists in the same directory.

---

```yaml
    security_opt:
      - label:disable
```

On SELinux-enabled hosts (RHEL, Fedora, Amazon Linux 2023), the container
sandbox policy prevents a container from accessing the host's Docker socket.
`label:disable` turns off the SELinux label enforcement for this container,
allowing the `docker.sock` mount to work. On non-SELinux hosts (Ubuntu, Debian)
this line is harmless.

---

```yaml
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
      - "/srv/cache:/srv/cache"
```

**`/var/run/docker.sock`** — The DooD mount. Without this, `docker` commands
inside the runner fail because there is no daemon to talk to. With it, the
runner's Docker CLI sends commands through the socket to the **host** daemon.

**`/srv/cache`** — The test framework caches built images, test matrices, and
results here. By mounting it from the host, the cache persists across container
restarts and is shared between runner containers if you scale to multiple
runners.

---

## 6. The DooD Pattern (Docker-outside-of-Docker)

```
┌─────────────────────────────────────────────────────┐
│  Host                                               │
│  /var/run/docker.sock  ◄────────────────┐           │
│  Docker daemon                          │ socket    │
│                                         │           │
│  ┌────────────────────────────────────┐ │           │
│  │  runner container                  │ │           │
│  │  /var/run/docker.sock ─────────────┘ │           │
│  │                                      │           │
│  │  $ docker build ...   ─► HOST daemon │           │
│  │  $ docker compose up  ─► HOST daemon │           │
│  └────────────────────────────────────┘            │
│                                                     │
│  test containers (started by runner, run on host)   │
└─────────────────────────────────────────────────────┘
```

**Implications you must understand:**

1. **Paths are host paths.** When the runner does
   `docker run -v /srv/cache:/cache ...`, the `/srv/cache` refers to the
   **host's** `/srv/cache`, not the runner container's. This is why the compose
   file mounts `/srv/cache` — so that path exists identically on both the host
   and inside the runner.

2. **Networks are host networks.** Test containers join networks on the host
   daemon, not inside the runner. They can reach each other and the host
   loopback directly.

3. **Image layers are shared.** Images built by the runner land in the host's
   image store and are reused across jobs (great for caching).

4. **Security.** Whoever can write to the Docker socket effectively has root on
   the host. This is intentional for a CI runner, but don't expose this in a
   multi-tenant environment.

---

## 7. Local End-to-End Testing Guide

This section walks you through running a self-hosted runner on your **local
macOS machine**, registering it with GitHub, and triggering a real workflow.

### Prerequisites

- Docker Desktop for Mac (running)
- A GitHub account with a fork or personal copy of `libp2p/unified-testing`
  (or any repo you control)
- A GitHub Personal Access Token (PAT)

---

### Step 1 — Create a GitHub PAT

1. Go to <https://github.com/settings/tokens?type=beta>
2. **Generate new token**
3. Set **Repository access** → select your test repo
4. Set **Repository permissions → Administration → Read and write**
5. Copy the token — you will put it in `.env`

> For a classic token: go to <https://github.com/settings/tokens>,
> generate with **`repo`** scope.

---

### Step 2 — Build the image locally

```bash
cd self-hosted-runner

docker build \
  -t libp2p-gh-runner:local \
  .
```

This will take a few minutes on first build (downloads runner binary, AWS CLI,
etc.). Subsequent builds are fast due to layer caching.

What you will see in the build log, layer by layer:

```
[1/6] FROM debian:13-slim
[2/6] RUN apt-get update ... (installs Docker CLI, gh, jq, git, etc.)
[3/6] RUN ... yq install
[4/6] RUN ... AWS CLI install
[5/6] RUN ... GitHub runner binary download + tar + ./bin/installdependencies.sh
[6/6] COPY entrypoint.sh + chmod
```

Verify the image exists:
```bash
docker images libp2p-gh-runner:local
```

---

### Step 3 — Set up environment

```bash
cp env .env
```

Edit `.env`:
```
RUNNER_NAME=local-mac-test
ACCESS_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

### Step 4 — Edit docker-compose.yaml for local use

You built the image locally as `libp2p-gh-runner:local`. Update the image
reference and the `REPO_URL` to point to your own repo:

```yaml
services:
  runner-unified-testing:
    image: libp2p-gh-runner:local          # ← local image
    restart: unless-stopped
    container_name: ${RUNNER_NAME}-unified-testing
    environment:
      RUNNER_ALLOW_RUNASROOT: true
      EPHEMERAL: true
      DISABLE_AUTO_UPDATE: true
      REPO_URL: https://github.com/YOUR-USERNAME/YOUR-REPO   # ← your repo
      RUNNER_NAME: ${RUNNER_NAME}-unified-testing
      ACCESS_TOKEN: ${ACCESS_TOKEN}
      RUNNER_SCOPE: 'repo'
      LABELS: 'self-hosted,linux,x64,ephemeral'
    security_opt:
      - label:disable
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
      - "/tmp/cache:/srv/cache"    # ← use /tmp/cache locally (no sudo needed)
```

> **macOS note on the Docker socket:**
> Docker Desktop on Mac runs Docker inside a Linux VM. The socket at
> `/var/run/docker.sock` is a proxy that Docker Desktop creates for you.
> DooD works fine on macOS with Docker Desktop.

---

### Step 5 — Start the runner

```bash
docker compose up
```

(Run without `-d` first so you can see the logs directly.)

**What you will see in the terminal:**

```
runner-unified-testing-1  |
runner-unified-testing-1  |                        ╔╦╦╗  ╔═╗
runner-unified-testing-1  |  ▁▁▁▁▁▁▁▁▁▁ ║╠╣╚╦═╬╝╠═╗ ▁▁▁▁▁▁▁▁▁▁
runner-unified-testing-1  |  ...banner...
runner-unified-testing-1  |
runner-unified-testing-1  |  Requesting registration token from GitHub...
runner-unified-testing-1  |  Successfully obtained registration token.
runner-unified-testing-1  |
runner-unified-testing-1  |  Registering runner:
runner-unified-testing-1  |    Name:   local-mac-test-unified-testing
runner-unified-testing-1  |    URL:    https://github.com/YOUR-USERNAME/YOUR-REPO
runner-unified-testing-1  |    Labels: self-hosted,linux,x64,ephemeral
runner-unified-testing-1  |
runner-unified-testing-1  |  √ Connected to GitHub
runner-unified-testing-1  |  √ Runner successfully added
runner-unified-testing-1  |  √ Runner connection is good
runner-unified-testing-1  |
runner-unified-testing-1  |  Runner configured successfully. Launching... 🚀
runner-unified-testing-1  |
runner-unified-testing-1  |  √ Settings Saved.
runner-unified-testing-1  |  Listening for Jobs
```

The runner is now **idle**, waiting for a job.

---

### Step 6 — Verify in GitHub UI

Open your browser:

```
https://github.com/YOUR-USERNAME/YOUR-REPO/settings/actions/runners
```

You should see:

```
local-mac-test-unified-testing    ● Idle    Labels: self-hosted linux x64 ephemeral
```

Or via CLI:
```bash
gh api repos/YOUR-USERNAME/YOUR-REPO/actions/runners \
  --jq '.runners[] | "\(.name)  \(.status)  \(.labels | map(.name) | join(","))"'
```

---

### Step 7 — Create a test workflow

In your repo, create `.github/workflows/test-runner.yml`:

```yaml
name: Test Self-Hosted Runner

on:
  workflow_dispatch:   # manual trigger from GitHub UI

jobs:
  hello:
    runs-on: [self-hosted, linux, x64]
    steps:
      - name: Print system info
        run: |
          echo "Hello from self-hosted runner!"
          uname -a
          docker --version
          docker buildx version
          docker compose version
          gh --version
          yq --version
          aws --version
          jq --version

      - name: Test Docker access (DooD)
        run: |
          docker run --rm alpine echo "Alpine container ran successfully on host daemon"

      - name: Show host Docker images
        run: docker images
```

Commit and push this file to your repo.

---

### Step 8 — Trigger the workflow

1. Go to your repo on GitHub
2. Click **Actions** tab
3. Click **Test Self-Hosted Runner** workflow
4. Click **Run workflow** → **Run workflow**

---

### Step 9 — Watch it happen

Back in your terminal (where `docker compose up` is running):

```
runner-unified-testing-1  |  2026-04-24 10:15:00Z: Running job: hello
runner-unified-testing-1  |  ...job output...
runner-unified-testing-1  |  2026-04-24 10:15:30Z: Job hello completed with result: Succeeded
runner-unified-testing-1  |  2026-04-24 10:15:30Z: Shutting down...    ← ephemeral exit
runner-unified-testing-1 exited with code 0
runner-unified-testing-1  |                                             ← Docker restarts
runner-unified-testing-1  |   ╔╦╦╗  ╔═╗  ...banner again...            ← new registration
runner-unified-testing-1  |  Requesting registration token from GitHub...
runner-unified-testing-1  |  Listening for Jobs                         ← ready for next job
```

This is the full loop. The runner:
1. Got a job
2. Ran it
3. Exited (ephemeral)
4. Docker restarted the container
5. Registered again with a fresh token
6. Is now idle, ready for the next job

---

### Step 10 — Inspect job output in GitHub

In GitHub Actions UI you will see the job log output from all the `echo`
commands, `docker --version`, etc. The Docker container that ran via DooD
(`alpine`) will show its output too.

---

### Cleanup

```bash
# Stop the runner (container exits, does NOT restart because of "unless-stopped")
docker compose down

# Remove the local image
docker rmi libp2p-gh-runner:local

# Remove cache dir
rm -rf /tmp/cache
```

The runner will automatically **deregister** itself from GitHub when the
container stops cleanly (it sends a deregistration request during shutdown).

---

## 8. What Happens When a Workflow Fires

Here is the complete sequence from "developer pushes code" to "runner executes job":

```
Developer pushes to repo
        │
        ▼
GitHub evaluates workflow files
        │ finds `runs-on: [self-hosted, linux, x64]`
        ▼
GitHub queues the job
        │
        ▼
Runner container (polling GitHub every ~2s via HTTPS long-poll)
        │ receives job assignment
        ▼
runner process (run.sh) downloads job definition + secrets
        │
        ▼
Runner executes each step in the job:
  - `uses: actions/checkout@v4`  → git clone into /actions-runner/_work/
  - `run: docker build ...`      → Docker CLI → host daemon (via DooD)
  - `run: docker compose up ...` → spins up test stack on host daemon
  - `run: ...test commands...`   → shells out, reads /srv/cache, writes results
        │
        ▼
Job completes → runner reports result to GitHub
        │
        ▼
run.sh exits (ephemeral mode)
        │
        ▼
entrypoint.sh exits → container exits with code 0
        │
        ▼
Docker daemon sees exit → restart: unless-stopped → restarts container
        │
        ▼
entrypoint.sh runs again → requests new token → registers → "Listening for Jobs"
```

---

## 9. Debugging Cheatsheet

### Runner doesn't appear in GitHub UI

```bash
# Check container logs
docker compose logs -f

# Common causes:
# 1. ACCESS_TOKEN is wrong or expired → look for "401 Unauthorized" in logs
# 2. PAT doesn't have Administration:write permission → "403 Forbidden"
# 3. REPO_URL has a typo → "404 Not Found"
# 4. Network issue (Docker Desktop not connected) → "Could not resolve host"
```

### Job is stuck in "Queued" state

```bash
# Runner labels must EXACTLY match the workflow's runs-on array
# Workflow:  runs-on: [self-hosted, linux, x64]
# Runner labels: self-hosted,linux,x64,ephemeral  ← subset match works

# Check what labels the runner advertised:
gh api repos/OWNER/REPO/actions/runners \
  --jq '.runners[] | {name: .name, labels: [.labels[].name]}'
```

### `docker: command not found` inside runner

```bash
# The Docker socket must be mounted. Check:
docker compose exec runner-unified-testing-1 docker ps

# If it fails with "Cannot connect to the Docker daemon":
# → /var/run/docker.sock is not mounted or has wrong permissions
# Check your volumes section in docker-compose.yaml
```

### Permission denied on `/var/run/docker.sock`

```bash
# On Linux, the socket is owned by the 'docker' group.
# The runner runs as root, which should be fine.
# If still failing, check socket permissions on host:
ls -la /var/run/docker.sock
# Should show: srw-rw---- 1 root docker ...

# Quick fix:
sudo chmod 666 /var/run/docker.sock   # (less secure, only for local testing)
```

### Cache permission errors

```bash
# Make sure /srv/cache (or /tmp/cache locally) exists and is writable:
mkdir -p /tmp/cache
chmod 777 /tmp/cache
```

### Runner keeps restarting without registering

```bash
# The validation in entrypoint.sh exits 1 if env vars are missing.
# Docker restarts it immediately → fast restart loop.
# Fix: check your .env file has both RUNNER_NAME and ACCESS_TOKEN filled in.
docker compose logs runner-unified-testing | head -20
```

### Rebuild after Dockerfile change

```bash
docker compose up -d --build
# This rebuilds the image AND restarts the container.
```

---

## 10. Before Going to EC2

Once local testing works, here is what changes for EC2:

| Concern | Local (macOS) | EC2 (Linux) |
|---------|--------------|-------------|
| Docker socket path | `/var/run/docker.sock` | Same |
| Cache dir | `/tmp/cache` | `/srv/cache` (create with `sudo mkdir -p`) |
| Image source | `libp2p-gh-runner:local` | `ghcr.io/<username>/libp2p-gh-runner:latest` |
| SELinux | Not present on macOS | May be present on Amazon Linux — `label:disable` handles it |
| Autostart on boot | Manual | Add to systemd or use `restart: always` |
| Multiple runners | One compose file | Scale with `docker compose up --scale runner-unified-testing=3` |

**EC2 checklist:**

```bash
# 1. Install Docker Engine (NOT Docker Desktop)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# 2. Install Docker Compose plugin
sudo apt-get install docker-compose-plugin   # Debian/Ubuntu
# or
sudo yum install docker-compose-plugin       # Amazon Linux

# 3. Create cache dir
sudo mkdir -p /srv/cache
sudo chown "$(id -u):$(id -g)" /srv/cache

# 4. Pull image from GHCR
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <username> --password-stdin
docker pull ghcr.io/<username>/libp2p-gh-runner:latest

# 5. Set up .env
cp env .env
# edit .env with RUNNER_NAME and ACCESS_TOKEN

# 6. Revert docker-compose.yaml image to ghcr.io reference
# And revert REPO_URL to https://github.com/libp2p/unified-testing

# 7. Start
docker compose up -d

# 8. Enable on boot (optional)
sudo systemctl enable docker
# Then add docker compose as a systemd service or use --restart=always
```

---

## Quick Reference Card

```
BUILD IMAGE:
  docker build -t libp2p-gh-runner:local .

RUN LOCALLY:
  cp env .env && vim .env     # fill in RUNNER_NAME and ACCESS_TOKEN
  docker compose up           # watch logs

CHECK REGISTRATION:
  gh api repos/OWNER/REPO/actions/runners \
    --jq '.runners[].name'

TRIGGER TEST JOB:
  gh workflow run test-runner.yml --repo OWNER/REPO

VIEW LOGS:
  docker compose logs -f

STOP:
  docker compose down

REBUILD + RESTART:
  docker compose up -d --build
```

#!/usr/bin/env bash
# Run the playbook against a throwaway Arch container. Nothing touches this
# machine: the repo is copied into the container, never bind-mounted rw.
#
#   test/run.sh                      # lint + syntax only (seconds)
#   test/run.sh --check              # playbook in check mode inside the container
#   test/run.sh --full               # real run: installs everything (GBs, ~20 min)
#   test/run.sh --full --idempotence # real run twice, second must report changed=0
#   test/run.sh --full -- --tags packages,shell   # anything after -- goes to ansible-playbook
#
#   --keep-image                     # leave the prepared image on disk for the next run
#
# Disk: every container is removed when the run ends, including on Ctrl-C. The
# prepared image (~1.7 GB) and the arch base image go with it unless
# --keep-image is given, which leaves them in place so the next run starts in
# seconds instead of re-downloading ansible and the base layer. The image is
# built with pull + commit rather than `docker build` on purpose: a build would
# strand its layers in BuildKit's shared cache, where they can only be reclaimed
# by a global prune that would also throw away every other project's cache.
#
# The docker role is skipped by default: it enables docker.service, and there
# is no systemd inside the container to enable it with.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=dotfiles-ansible-test
BASE_IMAGE=archlinux:base-devel
PREP_CONTAINER=dotfiles-ansible-test-prep
CONTAINER=dotfiles-ansible-test-run
MODE=lint
IDEMPOTENCE=0
KEEP_IMAGE=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        MODE=check ;;
    --full)         MODE=full ;;
    --idempotence)  IDEMPOTENCE=1 ;;
    --keep-image)   KEEP_IMAGE=1 ;;
    --)             shift; EXTRA_ARGS=("$@"); break ;;
    *)              echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# Only reclaim what this run actually created.
BASE_PRESENT=0
IMAGE_PRESENT=0
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && BASE_PRESENT=1
docker image inspect "$IMAGE"      >/dev/null 2>&1 && IMAGE_PRESENT=1

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  docker rm -f "$CONTAINER" "$PREP_CONTAINER" >/dev/null 2>&1 || true
  if [[ $KEEP_IMAGE -eq 1 ]]; then
    echo "==> keeping $IMAGE (drop --keep-image to reclaim ~1.7 GB)"
  else
    if [[ $IMAGE_PRESENT -eq 0 ]]; then
      echo "==> removing $IMAGE"
      docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
    fi
    if [[ $BASE_PRESENT -eq 0 ]]; then
      docker image rm -f "$BASE_IMAGE" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

if [[ $IMAGE_PRESENT -eq 1 ]]; then
  echo "==> reusing $IMAGE"
else
  if [[ $BASE_PRESENT -eq 0 ]]; then
    echo "==> pulling $BASE_IMAGE"
    docker pull -q "$BASE_IMAGE" >/dev/null
  fi
  echo "==> preparing $IMAGE"
  docker rm -f "$PREP_CONTAINER" >/dev/null 2>&1 || true
  docker run --name "$PREP_CONTAINER" -v "$REPO_ROOT/test":/test:ro \
    "$BASE_IMAGE" bash /test/prepare.sh
  docker commit \
    -c 'USER tester' -c 'WORKDIR /home/tester' -c 'ENV HOME=/home/tester' \
    "$PREP_CONTAINER" "$IMAGE" >/dev/null
  docker rm "$PREP_CONTAINER" >/dev/null
fi

# Re-quote the pass-through args so they survive the trip through `bash -lc`
# inside the container: without this, anything containing quotes or spaces
# (`-e '{"k":["a","b"]}'`) arrives mangled and ansible-playbook prints usage.
EXTRA=""
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  EXTRA="$(printf ' %q' "${EXTRA_ARGS[@]}")"
fi

# Shared preamble: copy the working tree in (minus .git) and pull the
# collections the playbook needs.
read -r -d '' SETUP <<'SH' || true
set -euo pipefail
cp -r /repo/. ~/work/
cd ~/work
rm -rf .git .ansible
ansible-galaxy collection install -r requirements.yml >/dev/null
SH

run_in_container() {
  docker run --rm -i --name "$CONTAINER" \
    -v "$REPO_ROOT":/repo:ro \
    -e ANSIBLE_BECOME_ASK_PASS=False \
    -e ANSIBLE_FORCE_COLOR=1 \
    "$IMAGE" bash -lc "mkdir -p ~/work && $SETUP
$1"
}

case "$MODE" in
  lint)
    run_in_container '
      echo "== syntax check ==";  ansible-playbook site.yml --syntax-check
      echo "== ansible-lint ==";  ansible-lint
    '
    ;;
  check)
    run_in_container "ansible-playbook site.yml --check --diff --skip-tags docker ${EXTRA}"
    ;;
  full)
    if [[ $IDEMPOTENCE -eq 1 ]]; then
      run_in_container "
        ansible-playbook site.yml --skip-tags docker ${EXTRA}
        echo; echo '===== SECOND RUN (idempotence) ====='
        ansible-playbook site.yml --skip-tags docker ${EXTRA} | tee /tmp/second.log
        # ANSIBLE_FORCE_COLOR wraps the recap in escape codes, so strip them
        # before reading the counter.
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/second.log \
          | grep -qE 'localhost[[:space:]]+:.*changed=0[[:space:]]' \
          && echo 'IDEMPOTENT: second run changed nothing' \
          || { echo 'NOT IDEMPOTENT: second run reported changes'; exit 1; }
      "
    else
      run_in_container "ansible-playbook site.yml --skip-tags docker ${EXTRA}"
    fi
    ;;
esac

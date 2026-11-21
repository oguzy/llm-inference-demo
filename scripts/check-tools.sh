#!/usr/bin/env bash
# Fails with install hints if a required tool is missing.
set -euo pipefail

missing=0
for t in docker kind kubectl helm curl jq; do
  if ! command -v "$t" >/dev/null; then
    echo "missing: $t"
    missing=1
  fi
done

if [[ $missing -eq 1 ]]; then
  cat <<'EOF'

Install on Arch:
  sudo pacman -S docker kubectl helm jq kind     # kind may need the AUR (kind-bin)
  sudo systemctl enable --now docker
  sudo usermod -aG docker $USER                  # then log out and back in
EOF
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but not reachable. Is the daemon running and are you in the docker group?"
  exit 1
fi

echo "tools ok"

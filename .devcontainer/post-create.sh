#!/usr/bin/env bash
# Install lab CLIs inside the Codespace. Linux-only: Docker Desktop on macOS

set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  jq curl default-mysql-client python3-pip python3-venv

python3 -m pip install --user --upgrade pip
python3 -m pip install --user \
  localstack \
  terraform-local \
  awscli-local

# gitleaks
GL_VER="8.21.2"
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL_VER}/gitleaks_${GL_VER}_linux_x64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin gitleaks

# zizmor (GitHub Actions scanner)
python3 -m pip install --user zizmor

# tflint
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

export PATH="${HOME}/.local/bin:${PATH}"
grep -q '.local/bin' "${HOME}/.bashrc" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"

echo ">> post-create done. Next: export LOCALSTACK_AUTH_TOKEN=... && make help"
localstack --version || true
tflocal --version || true
gitleaks version || true
zizmor --version || true

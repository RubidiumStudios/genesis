
#!/bin/bash
set -e

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Linux*)   PLATFORM=linux ;;
  Darwin*)  PLATFORM=darwin ;;
  *)        echo "Unsupported OS: $OS"; exit 1 ;;
esac

# Set install dir
INSTALL_DIR="/usr/local/bin"

# Set PERL5LIB in shell profile (bash/zsh)
if [ "$PLATFORM" = "darwin" ]; then
  PROFILE_FILE="$HOME/.zshrc"
else
  PROFILE_FILE="$HOME/.bashrc"
fi
if ! grep -q 'export PERL5LIB=' "$PROFILE_FILE" 2>/dev/null; then
  echo 'export PERL5LIB="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null || pwd)" && pwd)/lib"' >> "$PROFILE_FILE"
  echo "PERL5LIB will be set automatically in future shell sessions."
fi


# jq
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  if [ "$PLATFORM" = "linux" ]; then
    wget -O jq https://github.com/stedolan/jq/releases/latest/download/jq-linux64
  else
    wget -O jq https://github.com/stedolan/jq/releases/latest/download/jq-osx-amd64
  fi
  chmod +x jq
  sudo mv jq $INSTALL_DIR/jq
else
  echo "jq already installed."
fi


# spruce
if ! command -v spruce &>/dev/null; then
  echo "Installing spruce..."
  if [ "$PLATFORM" = "linux" ]; then
    wget -O spruce https://github.com/geofffranks/spruce/releases/latest/download/spruce-linux-amd64
  else
    wget -O spruce https://github.com/geofffranks/spruce/releases/latest/download/spruce-darwin-amd64
  fi
  chmod +x spruce
  sudo mv spruce $INSTALL_DIR/spruce
else
  echo "spruce already installed."
fi


# safe
if ! command -v safe &>/dev/null; then
  echo "Installing safe..."
  if [ "$PLATFORM" = "linux" ]; then
    wget -O safe https://github.com/starkandwayne/safe/releases/latest/download/safe-linux-amd64
  else
    wget -O safe https://github.com/starkandwayne/safe/releases/latest/download/safe-darwin-amd64
  fi
  chmod +x safe
  sudo mv safe $INSTALL_DIR/safe
else
  echo "safe already installed."
fi


# vault
if ! command -v vault &>/dev/null; then
  echo "Installing vault..."
  VAULT_VER=$(curl -s https://api.github.com/repos/hashicorp/vault/releases/latest | grep tag_name | cut -d '"' -f 4)
  if [ "$PLATFORM" = "linux" ]; then
    VAULT_PKG="vault_${VAULT_VER#v}_linux_amd64.zip"
  else
    VAULT_PKG="vault_${VAULT_VER#v}_darwin_amd64.zip"
  fi
  wget -O vault.zip "https://releases.hashicorp.com/vault/${VAULT_VER#v}/$VAULT_PKG"
  unzip vault.zip
  chmod +x vault
  sudo mv vault $INSTALL_DIR/vault
  rm vault.zip
else
  echo "vault already installed."
fi


# credhub
if ! command -v credhub &>/dev/null; then
  echo "Installing credhub..."
  if [ "$PLATFORM" = "linux" ]; then
    CREDHUB_URL=$(curl -s https://api.github.com/repos/cloudfoundry/credhub-cli/releases/latest \
      | grep "browser_download_url" \
      | grep "linux-amd64" \
      | grep ".tgz" \
      | cut -d '"' -f 4)
  else
    CREDHUB_URL=$(curl -s https://api.github.com/repos/cloudfoundry/credhub-cli/releases/latest \
      | grep "browser_download_url" \
      | grep "darwin-amd64" \
      | grep ".tgz" \
      | cut -d '"' -f 4)
  fi
  if [ -z "$CREDHUB_URL" ]; then
    echo "Failed to find credhub download URL. Please check your network or GitHub API rate limits."
    exit 1
  fi
  wget -O credhub.tgz "$CREDHUB_URL"
  tar -xzf credhub.tgz
  chmod +x credhub
  sudo mv credhub /usr/local/bin/credhub
  rm credhub.tgz
else
  echo "credhub already installed."
fi


# bosh
if ! command -v bosh &>/dev/null; then
  echo "Installing bosh..."
  if [ "$PLATFORM" = "linux" ]; then
    BOSH_URL=$(curl -s https://api.github.com/repos/cloudfoundry/bosh-cli/releases/latest \
      | grep "browser_download_url" \
      | grep "linux-amd64" \
      | grep -v ".sha1" \
      | cut -d '"' -f 4)
  else
    BOSH_URL=$(curl -s https://api.github.com/repos/cloudfoundry/bosh-cli/releases/latest \
      | grep "browser_download_url" \
      | grep "darwin-amd64" \
      | grep -v ".sha1" \
      | cut -d '"' -f 4)
  fi
  if [ -z "$BOSH_URL" ]; then
    echo "Failed to find bosh download URL. Please check your network or GitHub API rate limits."
    exit 1
  fi
  wget -O bosh "$BOSH_URL"
  chmod +x bosh
  sudo mv bosh /usr/local/bin/bosh
else
  echo "bosh already installed."
fi

echo "All tools installed!"
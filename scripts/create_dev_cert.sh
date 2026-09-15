#!/usr/bin/env bash
# Creates a self-signed code-signing identity "VibeStudio Dev" in the LOGIN
# keychain. Run once per machine: afterwards macOS permission grants (Screen
# Recording, Mic, Camera, Input Monitoring) survive rebuilds, because TCC
# binds to the stable certificate instead of the per-build ad-hoc cdhash.
#
# Keys land in .signing/ (gitignored) — never commit them.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="VibeStudio Dev"
DIR=".signing"
KEY="$DIR/vibestudio-dev.key"
CRT="$DIR/vibestudio-dev.crt"
P12="$DIR/vibestudio-dev.p12"
P12PASS="vibestudio"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists in a keychain:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$KEY" -out "$CRT"

openssl pkcs12 -export -legacy -out "$P12" -inkey "$KEY" -in "$CRT" \
  -passout "pass:$P12PASS" -name "$NAME"

security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$P12PASS" -T /usr/bin/codesign

echo
echo "Verifying:"
security find-identity -v -p codesigning | grep "$NAME" \
  && echo "OK — '$NAME' is available for codesigning. ./scripts/build.sh will pick it up automatically."

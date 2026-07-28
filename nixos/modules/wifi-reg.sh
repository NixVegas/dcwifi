#!/usr/bin/env bash

set -euo pipefail

# Generates a random password (base64 string with only alphanumerics)
# between 'min' ($1) and 'max' ($2) characters.
randomPassword() {
  local min="$1"
  local max="$2"

  if [ -z "$max" ]; then
    max="$min"
  fi

  if [ -z "$min" ] || [ -z "$max" ] || ! [ "$min" -gt 0 ] || ! [ "$max" -gt 0 ]; then
    echo "Minimum and maximum length must be positive" >&2
    return 1
  fi

  if [ "$min" -gt "$max" ]; then
    echo "Minimum length was greater than maximum" >&2
    return 2
  fi

  # Pick the length using the insecure RNG seeded with the current nanosecond count
  RANDOM="$(date +%N)"
  local length=$(((RANDOM % (max - min + 1)) + min))

  # Make sure the password uses the OpenSSL RNG
  local iters=0
  local limit=10
  while [ "${#replacement}" -lt "$length" ] && [ $iters -lt $limit ]; do
    # We will always generate more base64 characters than input bytes so can just sample,
    # until we get a string that works
    replacement="$(openssl rand -base64 "$length" | tr -dc '0-9A-Za-z' | head -c "$length")"
    iters=$((iters+1))
  done

  if [ "${#replacement}" -lt "$length" ]; then
    echo "Could not generate random password: result too short" >&2
    return 3
  fi

  echo -n "$replacement"
}

# Substitutes all tokens in the given template ($1).
# Requires a minimum of $2 substitutions (default 1).
substituteTemplate() {
  local template="$1"
  local min="${2:-1}"

  local result=""
  local found=0
  while [[ "$template" =~ ^([^<]*)\<(random):([^<>]+)\>(.*)$ ]]; do
    local prefix="${BASH_REMATCH[1]}"
    local suffix="${BASH_REMATCH[4]}"
    local replacement=""
    case "${BASH_REMATCH[2]}" in
      random)
        if [[ "${BASH_REMATCH[3]}" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
          replacement="$(randomPassword "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}")"
          if [ -n "$replacement" ]; then
            found=$((found+1))
          else
            echo "Unable to generate random password" >&2
            return 1
          fi
        else
          echo "Invalid syntax for <random:[range or length]>" >&2
          return 2
        fi
        ;;
      *)
        echo "Invalid template '${BASH_REMATCH[2]}'" >&2
        return 3
        ;;
    esac
    result="$result$prefix$replacement"
    template="$suffix"
  done
  result="$result$template"

  if [ "$found" -lt "$min" ] || [ -z "$result" ]; then
    echo "Not enough replacements made with template '$1'" >&2
    return 4
  fi

  echo -n "$result"
}

for var in \
  WIFIREG_USERNAME \
  WIFIREG_PASSWORD_TEMPLATE \
  WIFIREG_SECRETS_FILE \
  WIFIREG_SECRET_NAME \
  WIFIREG_BACKEND \
  WIFIREG_WPA_CTRL \
  WIFIREG_NM_PROFILE \
  WIFIREG_BASE; do
  if [[ ! -v $var ]]; then
    echo "$var must be set" >&2
    exit 1
  fi
done

if [ ! -f "$WIFIREG_SECRETS_FILE" ] \
  || ! grep -q "^${WIFIREG_SECRET_NAME}=" "$WIFIREG_SECRETS_FILE"; then
  password="$(substituteTemplate "$WIFIREG_PASSWORD_TEMPLATE")"

  curl --silent --show-error --fail -LX POST --data-raw \
    "username=${WIFIREG_USERNAME}&password=${password}&password2=${password}&submit=REGISTER" \
    "$WIFIREG_BASE" || exit $?

  if [ ! -f "$WIFIREG_SECRETS_FILE" ]; then
    touch "$WIFIREG_SECRETS_FILE"
  fi
  # The service runs as the backend's user (wpa_supplicant or root), so the
  # secret is owned by that user; keep it readable only by the owner.
  chmod 0600 "$WIFIREG_SECRETS_FILE"

  echo "Wifi registration is up, registered user '$WIFIREG_USERNAME'" >&2
  echo "# added by nixVegas.dcWifi" >> "$WIFIREG_SECRETS_FILE"
  echo "${WIFIREG_SECRET_NAME}=$password" >> "$WIFIREG_SECRETS_FILE"

  # Nudge the active backend to pick up the new secret.
  case "$WIFIREG_BACKEND" in
    wpa_supplicant)
      # The file: ext_password backend re-reads the secret on every lookup, so a
      # reconfigure is enough (no privileged service restart, no root).
      if [ -d "$WIFIREG_WPA_CTRL" ]; then
        for sock in "$WIFIREG_WPA_CTRL"/*; do
          [ -S "$sock" ] || continue
          iface="$(basename "$sock")"
          # Skip the P2P device control socket; reconfigure on it just hangs.
          case "$iface" in p2p-dev-*) continue ;; esac
          wpa_cli -p "$WIFIREG_WPA_CTRL" -i "$iface" reconfigure || true
        done
      fi
      ;;
    networkmanager)
      # Re-run the declarative profile generator (it re-substitutes the secret
      # via envsubst and reloads NetworkManager), then (re)activate the profile.
      /run/current-system/systemd/bin/systemctl restart NetworkManager-ensure-profiles.service || true
      nmcli connection up "$WIFIREG_NM_PROFILE" || true
      ;;
    *)
      echo "Unknown WIFIREG_BACKEND '$WIFIREG_BACKEND'" >&2
      exit 1
      ;;
  esac
fi

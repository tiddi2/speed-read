#!/bin/bash
# Create and maintain the local "sr-dev" code-signing identity.
#
# Why this exists: macOS keys the Accessibility (TCC) grant and a Keychain
# item's ACL on an app's *code signature*, not on its path. With no signing
# certificate `codesign` signs ad-hoc, and an ad-hoc identity is the binary's
# own hash — so every rebuild is a brand-new app as far as the system is
# concerned: the Accessibility grant is forgotten and the Keychain asks for
# your password again. Signing with a real certificate gives a stable
# designated requirement (`identifier "com.patrickellis.sr" and certificate
# leaf = H"…"`) that does not change when the binary does. Grant once, keep it
# across every `make update`.
#
# The certificate is self-signed and local: it makes sr recognizable to *this*
# Mac and means nothing on any other. Phase 3 replaces it with a Developer ID.
#
# The key lives in its own keychain (~/Library/Keychains/sr-dev.keychain-db)
# whose password is generated here and kept in ~/.config/sr, so builds unlock
# it without prompting. That is the trade-off for "no password on every
# update": a local self-signed signing key readable by anything running as
# you. It signs nothing but your own sr builds, and `--remove` undoes all of
# it. Keeping the key in the login keychain instead is the stricter option —
# see README > Development.
set -euo pipefail

IDENTITY_NAME="sr-dev"
STATE_DIR="${SR_SIGNING_STATE_DIR:-$HOME/.config/sr}"
PASS_FILE="$STATE_DIR/sr-dev-keychain-password"
KEYCHAIN_DB="$HOME/Library/Keychains/sr-dev.keychain-db"
KEYCHAIN_LEGACY="$HOME/Library/Keychains/sr-dev.keychain"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL="${SR_OPENSSL:-/usr/bin/openssl}"

usage() {
  cat <<'USAGE'
scripts/setup-signing.sh — local code-signing identity for sr

  (no flags)      ensure the sr-dev identity exists; create it if missing
  --check         ensure it exists, then prove it can sign
  --print-env     emit SR_SIGN_IDENTITY / SR_SIGN_KEYCHAIN for build-app.sh
  --force         discard and recreate it (costs the current grants once)
  --fix-prompts   stop codesign asking for the login password, for an
                  sr-dev key that lives in the login keychain
  --remove        delete the identity and its keychain
USAGE
}

MODE="ensure"
QUIET=0
case "${1:-}" in
  "")            MODE="ensure" ;;
  --check)       MODE="check" ;;
  --print-env)   MODE="print-env"; QUIET=1 ;;
  --force)       MODE="force" ;;
  --fix-prompts) MODE="fix-prompts" ;;
  --remove)      MODE="remove" ;;
  -h|--help)     usage; exit 0 ;;
  *)             echo "setup-signing.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
esac

# Everything human-readable goes to stderr, so --print-env's stdout stays
# machine-readable.
log()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }

[ "$(uname -s)" = "Darwin" ] || { log "setup-signing.sh: macOS only — nothing to do."; exit 0; }

TMP_ROOT=""
cleanup() { [ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"; return 0; }
trap cleanup EXIT

# Sets SCRATCH to a fresh directory under one root the EXIT trap removes.
# It assigns rather than prints, because a command substitution would create
# the root in a subshell where the trap cannot see it.
SCRATCH=""
scratch() {
  [ -n "$TMP_ROOT" ] || TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sr-signing.XXXXXX")"
  SCRATCH="$(mktemp -d "$TMP_ROOT/step.XXXXXX")"
}

# The file is .keychain-db on every macOS sr supports; resolve both spellings
# rather than assume.
keychain_path() {
  if [ -f "$KEYCHAIN_DB" ]; then printf '%s' "$KEYCHAIN_DB"
  elif [ -f "$KEYCHAIN_LEGACY" ]; then printf '%s' "$KEYCHAIN_LEGACY"
  fi
}

# SHA-1 of the sr-dev signing identity in one keychain, or (with no argument)
# anywhere in the user's search list. Empty when there is no such identity.
identity_hash() {
  if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    security find-identity -v -p codesigning "$1" 2>/dev/null
  else
    security find-identity -v -p codesigning 2>/dev/null
  fi | awk -v want="\"$IDENTITY_NAME\"" 'index($0, want) { print $2; exit }'
}

# Same lookup, but ignoring whether macOS currently considers the identity
# *valid*. A self-signed certificate is not valid for code signing until it is
# trusted, and `find-identity -v` hides exactly that state — which is how
# "imported but untrusted" gets told apart from "never imported at all".
any_identity_hash() {
  if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    security find-identity "$1" 2>/dev/null
  else
    security find-identity 2>/dev/null
  fi | awk -v want="\"$IDENTITY_NAME\"" 'index($0, want) { print $2; exit }'
}

# Keychain holding an sr-dev certificate made some other way — by hand in
# Keychain Access, as the README used to instruct.
foreign_keychain() {
  security find-certificate -c "$IDENTITY_NAME" -a 2>/dev/null \
    | sed -n 's/^keychain: "\(.*\)"$/\1/p' | head -n 1
}

# Read the user's keychain search list into the global SEARCH_LIST array,
# minus $1 when given. (An array, because a home directory may contain spaces;
# global, because bash 3.2 — which is what macOS ships — has no local arrays
# worth the trouble here.)
read_search_list() {
  local skip="${1:-}" entry
  SEARCH_LIST=()
  while IFS= read -r entry; do
    entry="${entry#*\"}"; entry="${entry%\"*}"
    [ -n "$entry" ] || continue
    [ "$entry" = "$skip" ] && continue
    SEARCH_LIST+=("$entry")
  done < <(security list-keychains -d user 2>/dev/null)
}

# codesign searches the user's keychain list, and `security create-keychain`
# does not join it.
add_to_search_list() {
  local target="$1" entry
  read_search_list
  for entry in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
    [ "$entry" = "$target" ] && return 0
  done
  security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} "$target" >/dev/null
}

create_identity() {
  local kc pass tmp import_log
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

  # A leftover sr-dev keychain we have no password for cannot be signed with
  # and would make `create-keychain` fail; it only ever held this certificate.
  if [ -n "$(keychain_path)" ]; then
    log "Replacing an unusable sr-dev keychain."
    remove_identity
  fi

  pass="$("$OPENSSL" rand -hex 24)"
  printf '%s\n' "$pass" > "$PASS_FILE"; chmod 600 "$PASS_FILE"

  # Short name, not a path: macOS creates it in ~/Library/Keychains and picks
  # the suffix (.keychain-db on every current release).
  security create-keychain -p "$pass" "sr-dev.keychain" >/dev/null
  kc="$(keychain_path)"
  [ -n "$kc" ] || { warn "setup-signing.sh: could not create $KEYCHAIN_DB"; return 1; }

  # No auto-lock timeout, no lock on sleep: a keychain that relocks itself puts
  # the password prompt straight back.
  security set-keychain-settings "$kc" >/dev/null
  security unlock-keychain -p "$pass" "$kc"
  add_to_search_list "$kc"

  scratch; tmp="$SCRATCH"

  # A config file rather than -addext, which the LibreSSL macOS ships does not
  # accept. codeSigning EKU is what makes the certificate usable by codesign.
  cat > "$tmp/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = codesign

[ dn ]
CN = sr-dev

[ codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

  if ! "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
         -config "$tmp/openssl.cnf" \
         -keyout "$tmp/sr-dev.key" -out "$tmp/sr-dev.crt" >/dev/null 2>&1; then
    warn "setup-signing.sh: $OPENSSL could not generate the certificate."
    return 1
  fi

  # -T grants codesign use of the key; the partition list below is the second
  # half of the same permission on modern macOS. Without both, every build
  # raises a "codesign wants to access key sr-dev" password dialog.
  #
  # Both import routes are judged by what they leave in the keychain rather
  # than by their exit status: a PKCS#12 that macOS accepts without pairing
  # the key to the certificate exits 0 and still yields no identity, and the
  # old `p12 || separate` form never retried in that case. Their output is
  # kept so a failure below can show it instead of a bare "could not create".
  import_log="$tmp/import.log"
  : > "$import_log"

  if "$OPENSSL" pkcs12 -export -name "$IDENTITY_NAME" \
       -inkey "$tmp/sr-dev.key" -in "$tmp/sr-dev.crt" \
       -out "$tmp/sr-dev.p12" -passout "pass:$pass" >>"$import_log" 2>&1; then
    security import "$tmp/sr-dev.p12" -k "$kc" -P "$pass" -f pkcs12 \
      -T /usr/bin/codesign -T /usr/bin/security >>"$import_log" 2>&1 || true
  fi

  # Some openssl builds write a PKCS#12 macOS will not parse, or parses
  # without forming an identity. Importing the key and the certificate
  # separately yields the same identity.
  if [ -z "$(any_identity_hash "$kc")" ]; then
    security import "$tmp/sr-dev.key" -k "$kc" -f openssl -t priv \
      -T /usr/bin/codesign -T /usr/bin/security >>"$import_log" 2>&1 || true
    security import "$tmp/sr-dev.crt" -k "$kc" -f openssl -t cert \
      -T /usr/bin/codesign -T /usr/bin/security >>"$import_log" 2>&1 || true
  fi

  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$pass" "$kc" >/dev/null 2>&1 || true

  # A self-signed certificate is not valid for code signing until something
  # trusts it, and the check below lists only valid identities. Trust it here
  # rather than after the fact: the caller's trust_certificate() runs only
  # once this function has already returned success, so it could never rescue
  # the case where this is what failed.
  if [ -z "$(identity_hash "$kc")" ] && [ -n "$(any_identity_hash "$kc")" ]; then
    log "Trusting the $IDENTITY_NAME certificate for code signing."
    log "(macOS may ask to authorize this once.)"
    trust_certificate "$kc" || true
  fi

  [ -z "$(identity_hash "$kc")" ] || return 0

  # Still nothing. Say which half is missing, so this is diagnosable on the
  # first failure rather than the second.
  if [ -n "$(any_identity_hash "$kc")" ]; then
    warn "setup-signing.sh: the $IDENTITY_NAME key and certificate imported, but"
    warn "macOS does not accept the certificate for code signing. Trusting it"
    warn "failed or was declined; re-run and approve the authorization prompt."
  else
    warn "setup-signing.sh: no $IDENTITY_NAME key/certificate pair was formed in"
    warn "$kc. Import output:"
    sed 's/^/    /' "$import_log" >&2 || true
  fi
  return 1
}

# A self-signed certificate has no chain to a trusted root. Signing normally
# works regardless; if this macOS refuses, trusting the certificate for code
# signing fixes it — one authorization prompt, once ever.
trust_certificate() {
  local kc="$1" tmp
  scratch; tmp="$SCRATCH"
  security find-certificate -c "$IDENTITY_NAME" -p "$kc" > "$tmp/sr-dev.crt" 2>/dev/null || return 1
  security add-trusted-cert -r trustRoot -p codeSign -k "$kc" "$tmp/sr-dev.crt" >/dev/null 2>&1
}

# Sign a throwaway bundle, so a build never discovers the identity is broken.
test_sign() {
  local hash="$1" kc="${2:-}" tmp probe
  scratch; tmp="$SCRATCH"
  probe="$tmp/probe.app"
  mkdir -p "$probe/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$probe/Contents/MacOS/probe"
  chmod +x "$probe/Contents/MacOS/probe"
  cat > "$probe/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.patrickellis.sr.signing-probe</string>
    <key>CFBundleExecutable</key><string>probe</string>
    <key>CFBundleName</key>      <string>probe</string>
</dict>
</plist>
PLIST
  KEYCHAIN_ARG=()
  [ -n "$kc" ] && KEYCHAIN_ARG=(--keychain "$kc")
  codesign --force --timestamp=none ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} \
    --sign "$hash" "$probe" >/dev/null 2>&1 \
    && codesign --verify "$probe" >/dev/null 2>&1
}

remove_identity() {
  local kc
  kc="$(keychain_path)"
  if [ -n "$kc" ]; then
    read_search_list "$kc"
    if [ "${#SEARCH_LIST[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${SEARCH_LIST[@]}" >/dev/null
    fi
    security delete-keychain "$kc" >/dev/null 2>&1 || true
  fi
  rm -f "$PASS_FILE"
}

case "$MODE" in
  remove)
    remove_identity
    log "Removed the sr-dev signing identity. Builds are ad-hoc signed again, so"
    log "macOS treats every rebuild as a new app and re-asks for Accessibility."
    exit 0
    ;;
  fix-prompts)
    # For an sr-dev key in the login keychain, made by hand before this script
    # existed: tell that keychain codesign may use the key unattended. Needs
    # the login password once, and never again.
    fix_kc="$(foreign_keychain)"
    [ -n "$fix_kc" ] || fix_kc="$LOGIN_KEYCHAIN"
    printf 'Login keychain password (not echoed, used once, not stored): ' >&2
    read -rs login_pass; printf '\n' >&2
    if security set-key-partition-list -S apple-tool:,apple:,codesign: \
         -s -l "$IDENTITY_NAME" -k "$login_pass" "$fix_kc" >/dev/null 2>&1; then
      unset login_pass
      log "Done — codesign can use the sr-dev key without prompting."
      exit 0
    fi
    unset login_pass
    warn "Could not update that keychain's partition list. Check the password, or"
    warn "run scripts/setup-signing.sh --force to keep the key in its own keychain."
    exit 1
    ;;
  force)
    remove_identity
    ;;
esac

KEYCHAIN="$(keychain_path)"
HASH=""

if [ -n "$KEYCHAIN" ] && [ -f "$PASS_FILE" ]; then
  security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN" 2>/dev/null || true
  add_to_search_list "$KEYCHAIN"
  HASH="$(identity_hash "$KEYCHAIN")"
fi

# --force is the escape hatch for an identity that no longer works, so it skips
# adoption and mints a new one even if some other sr-dev identity is around.
if [ -z "$HASH" ] && [ "$MODE" != "force" ]; then
  # Adopt an sr-dev identity created some other way instead of minting a second
  # one: a new certificate is a new designated requirement, which would cost
  # whatever grants the existing identity already holds.
  HASH="$(identity_hash)"
  if [ -n "$HASH" ]; then
    KEYCHAIN="$(foreign_keychain)"
    log "Using the existing \"$IDENTITY_NAME\" identity in ${KEYCHAIN:-your keychain}."
    case "$KEYCHAIN" in
      "$LOGIN_KEYCHAIN"|"$HOME/Library/Keychains/login.keychain")
        log "If codesign asks for your login password on every build, run once:"
        log "  scripts/setup-signing.sh --fix-prompts"
        ;;
    esac
  fi
fi

if [ -z "$HASH" ]; then
  log "Creating a local \"$IDENTITY_NAME\" code-signing identity (one time)."
  log "It gives sr a stable identity, so the Accessibility grant and the Keychain"
  log "ACL survive rebuilds instead of resetting on every update."
  if ! create_identity; then
    warn "setup-signing.sh: could not create the $IDENTITY_NAME identity."
    warn "Builds stay ad-hoc signed, and Accessibility will reset on each update."
    exit 1
  fi
  KEYCHAIN="$(keychain_path)"
  HASH="$(identity_hash "$KEYCHAIN")"
  if ! test_sign "$HASH" "$KEYCHAIN"; then
    trust_certificate "$KEYCHAIN" || true
    if ! test_sign "$HASH" "$KEYCHAIN"; then
      warn "setup-signing.sh: the $IDENTITY_NAME identity exists but cannot sign."
      warn "Run scripts/setup-signing.sh --check for the error, or --remove to undo."
      exit 1
    fi
  fi
  log ""
  log "Done. sr's identity is stable from here on. Clear the stale grants once:"
  log "  make reset-permissions"
fi

case "$MODE" in
  print-env)
    printf 'SR_SIGN_IDENTITY=%s\n' "$HASH"
    printf 'SR_SIGN_KEYCHAIN=%s\n' "${KEYCHAIN:-}"
    ;;
  check)
    if test_sign "$HASH" "$KEYCHAIN"; then
      log "Signing identity \"$IDENTITY_NAME\" ($HASH) is usable."
      log "Keychain: ${KEYCHAIN:-default search list}"
    else
      warn "Signing identity \"$IDENTITY_NAME\" ($HASH) exists but a test sign failed."
      warn "Try: scripts/setup-signing.sh --force"
      exit 1
    fi
    ;;
esac

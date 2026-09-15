#!/bin/bash
# Print the Swift pins for the Norwegian voice you actually have installed.
#
# Kokoro's revision and file hashes are compiled into the app because they
# could be resolved when the code was written. The Norwegian model is a
# community fine-tune with no stable revision, so its install resolves one and
# records it in ~/Library/Application Support/sr/f5/manifest.json instead.
#
# Once you are happy with an install, run this and paste the output into
# Sources/SRCore/F5/F5Installer.swift. Every later install then fetches that
# exact commit and refuses anything else — the same guarantee Kokoro has.
set -euo pipefail

MANIFEST="${1:-$HOME/Library/Application Support/sr/f5/manifest.json}"

if [ ! -f "$MANIFEST" ]; then
  echo "No install manifest at: $MANIFEST" >&2
  echo "Install the Norwegian voice first (Settings → General), or pass a path." >&2
  exit 1
fi

python3 - "$MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
print("// Resolved from an install on %s." % manifest["installedAt"])
print('public static let modelRepo = "%s"' % manifest["modelRepo"])
print('public static let modelRevision: String? = "%s"' % manifest["modelRevision"])
print()
print("// For reference — verified at install and re-checked on every launch:")
print("//   checkpoint: %s" % manifest["weightsSource"])
print("//   sha256:     %s" % manifest["weightsSHA256"])
print("//   vocab:      %s" % manifest["vocabSHA256"])
print("//   vocoder:    %s" % manifest["vocoderSHA256"])
source = manifest.get("archSource") or "sr's default"
print("//   architecture from %s: %s"
      % (source, json.dumps(manifest["arch"], sort_keys=True)))
PY

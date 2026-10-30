#!/usr/bin/env bash
#
# Publish the toolkit scripts as PUBLIC GitHub gists and print pinned raw URLs.
#
# Why public: a secret gist is only "unlisted" - anyone with the URL can read it, so
# secret buys nothing for a support script while making it harder to find. Public gists
# are indexed, which is fine for code you would hand to a colleague anyway. Note that
# gist visibility cannot be changed after creation: flipping a secret gist to public
# means creating a new one.
#
# Idempotent: scripts/gists.json records the gist id per file. Re-running updates the
# content of those gists and prints fresh pinned URLs; missing ids are created.
#
# Requires: bash, gh (authenticated), jq.
#
# Usage:
#   scripts/publish-gists.sh            # publish/update everything
#   scripts/publish-gists.sh --dry-run  # show what would happen

set -euo pipefail

GH="${GH:-gh}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

command -v "$GH" >/dev/null 2>&1 || { echo "ERROR: gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "ERROR: jq not found." >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated. Run: $GH auth login" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/scripts/gists.json"
[[ -f "$MANIFEST" ]] || echo '{}' > "$MANIFEST"

USER_LOGIN="$("$GH" api user --jq .login)"

# file|description
ENTRIES=(
  "Printer-Setup-Paste.ps1|Printer setup for the logged-on user - paste-ready, ScreenConnect Commands tab ready"
  "Printer-Check.ps1|Read-only report of the logged-on user's printers - paste-ready"
  "Add-PrinterAsUser.ps1|Add / remove / verify a network printer connection as the logged-on user"
  "Reset-OneDriveLink-2.ps1|Unlink and re-link OneDrive for the logged-on user"
)

printf '%-28s %-9s %s\n' "FILE" "ACTION" "PINNED RAW URL"
printf '%-28s %-9s %s\n' "----" "------" "--------------"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for entry in "${ENTRIES[@]}"; do
  file="${entry%%|*}"
  desc="${entry#*|}"
  path="$ROOT/$file"

  if [[ ! -f "$path" ]]; then
    printf '%-28s %-9s %s\n' "$file" "MISSING" "not in repo"
    continue
  fi

  id="$(jq -r --arg f "$file" '.[$f].id // empty' "$MANIFEST")"
  body="$TMP/body.json"
  jq -n --arg f "$file" --arg d "$desc" --rawfile c "$path" \
     '{description: $d, public: true, files: {($f): {content: $c}}}' > "$body"

  if [[ -z "$id" ]]; then
    action="CREATE"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '%-28s %-9s %s\n' "$file" "$action" "(dry run)"
      continue
    fi
    url="$("$GH" api -X POST /gists --input "$body" --jq .html_url)"
    id="${url##*/}"
  else
    action="UPDATE"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '%-28s %-9s %s\n' "$file" "$action" "(dry run, id $id)"
      continue
    fi
    # Note: the API cannot change gist visibility, only description and files.
    "$GH" api -X PATCH "/gists/$id" --input "$body" >/dev/null
  fi

  version="$("$GH" api "/gists/$id" --jq '.history[0].version')"
  pinned="https://gist.githubusercontent.com/${USER_LOGIN}/${id}/raw/${version}/${file}"

  # record id + last published version so the next run is a no-op if nothing changed
  tmp_manifest="$TMP/manifest.json"
  jq --arg f "$file" --arg i "$id" --arg v "$version" --arg d "$desc" \
     '.[$f] = {id: $i, version: $v, description: $d}' "$MANIFEST" > "$tmp_manifest"
  mv "$tmp_manifest" "$MANIFEST"

  printf '%-28s %-9s %s\n' "$file" "$action" "$pinned"
done

echo
echo "Manifest: $MANIFEST"
echo "Paste forms:"
echo "  paste-ready (Printer-*.ps1 - runs in memory, nothing lands on disk):"
echo "      irm <pinned-url> | iex"
echo "  file-based (Add-PrinterAsUser / Reset-OneDriveLink - they re-invoke themselves,"
echo "  so they need a real file path):"
echo "      \$f=\"\$env:TEMP\\tool.ps1\"; irm <pinned-url> -OutFile \$f; & \$f -PrinterPath '\\\\srv\\queue'"

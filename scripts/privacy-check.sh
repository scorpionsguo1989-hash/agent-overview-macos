#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

forbidden_paths=$(find . -type f \( \
  -name '.env*' -o -name '*.db' -o -name '*.sqlite*' -o -name '*.jsonl' \
  -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
  -o -name '*receipt*.json' -o -path '*/Tests/Artifacts/*' \
\) -not -path './.git/*' -print)
if [[ -n "$forbidden_paths" ]]; then
  echo "Forbidden private artifacts found:" >&2
  echo "$forbidden_paths" >&2
  exit 1
fi

unexpected_public_images=$(find . -type f \( \
  -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \
\) -not -path './.git/*' -not -path './docs/assets/agent-overview-demo.png' -print)
if [[ -n "$unexpected_public_images" ]]; then
  echo "Unexpected public image found; documentation images must come from synthetic fixtures:" >&2
  echo "$unexpected_public_images" >&2
  exit 1
fi

absolute_home_pattern='/''Users/[^/[:space:]\"]+'
if rg -n --hidden --glob '!.git/**' "$absolute_home_pattern" .; then
  echo "Absolute user path found" >&2
  exit 1
fi

if rg -n --hidden --glob '!.git/**' \
  '(-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' .; then
  echo "High-confidence credential shape found" >&2
  exit 1
fi

if rg -n --hidden --glob '!.git/**' --glob '!scripts/privacy-check.sh' \
  '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)' .; then
  echo "Phone-number-shaped value found" >&2
  exit 1
fi

if rg -n --hidden --glob '!.git/**' --glob '!scripts/privacy-check.sh' \
  '(^|[^0-9])[1-9][0-9]{5}(18|19|20)[0-9]{2}(0[1-9]|1[0-2])([0-2][1-9]|3[01])[0-9]{3}[0-9Xx]([^0-9Xx]|$)' .; then
  echo "Government-ID-shaped value found" >&2
  exit 1
fi

echo "Privacy check: PASS"

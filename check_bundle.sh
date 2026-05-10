#!/bin/sh
# Find the USE_PROXY value baked into the Next.js bundle
for f in /app/.next/static/chunks/*.js; do
  if grep -q 'USE_PROXY' "$f" 2>/dev/null; then
    echo "Found in: $f"
    grep -o 'USE_PROXY[^,;)]*' "$f" | head -5
    echo "---"
    # Also check tracker URL
    grep -o 'TRACKER_API_BASE_URL[^,;)]*' "$f" | head -3
    break
  fi
done
echo "=== Looking for direct api.coachify.tn references ==="
grep -rl 'api.coachify.tn' /app/.next/static/chunks/ 2>/dev/null | head -5

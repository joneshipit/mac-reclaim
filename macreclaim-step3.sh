#!/bin/bash
# Back-compat: step 3 is now the one-shot reclaim (auto-detects Data / Data 1).
echo "MacReclaim is one step now. Fetching macreclaim.sh..."
curl -L "https://raw.githubusercontent.com/joneshipit/mac-reclaim/main/macreclaim.sh?$(date +%s)" -o /tmp/macreclaim.sh || exit 1
chmod +x /tmp/macreclaim.sh
exec /tmp/macreclaim.sh

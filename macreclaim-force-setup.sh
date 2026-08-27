#!/bin/bash
# Back-compat: force-setup is now the one-shot reclaim.
echo "MacReclaim is one step now. Fetching macreclaim.sh..."
curl -L "https://raw.githubusercontent.com/joneshipit/mac-reclaim/main/macreclaim.sh?$(date +%s)" -o /tmp/macreclaim.sh || exit 1
chmod +x /tmp/macreclaim.sh
exec /tmp/macreclaim.sh

#!/bin/bash
# Enable USER_PASSWORD_AUTH flow for Cognito client

USER_POOL_ID="us-east-2_LosMWvc1G"
USER_POOL_CLIENT_ID="5rf86mbjntnhesmd9lb04g6kmp"
REGION="us-east-2"

echo "Enabling USER_PASSWORD_AUTH flow for Cognito client..."

aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$USER_POOL_CLIENT_ID" \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region "$REGION"

if [ $? -eq 0 ]; then
  echo "✓ USER_PASSWORD_AUTH flow enabled successfully"
  echo ""
  echo "You can now run ./loginToGetToken.sh to get your authentication token"
else
  echo "✗ Failed to enable USER_PASSWORD_AUTH flow"
  exit 1
fi

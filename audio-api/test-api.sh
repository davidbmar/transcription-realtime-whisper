#!/bin/bash

# Audio API Test Script
# Tests all endpoints with cURL

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Configuration
API_URL="${AUDIO_API_ENDPOINT}"
TOKEN="${ID_TOKEN:-placeholder_token}"

echo -e "${YELLOW}=== Audio API Test Suite ===${NC}"
echo ""
echo "API URL: $API_URL"
echo "Token: ${TOKEN:0:20}..."
echo ""

# Helper function to print test results
print_result() {
  if [ $1 -eq 0 ]; then
    echo -e "${GREEN}✓ $2${NC}"
  else
    echo -e "${RED}✗ $2${NC}"
  fi
}

# Helper function to make authenticated requests
api_request() {
  local method=$1
  local path=$2
  local data=$3

  if [ -z "$data" ]; then
    curl -s -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      "${API_URL}${path}"
  else
    curl -s -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "${API_URL}${path}"
  fi
}

echo -e "${YELLOW}=== Test 1: Create Session ===${NC}"
CREATE_SESSION_RESPONSE=$(api_request POST "/api/audio/sessions" '{
  "codec": "webm/opus",
  "sampleRate": 48000,
  "chunkSeconds": 5,
  "deviceInfo": {
    "userAgent": "test-script/1.0"
  }
}')

echo "$CREATE_SESSION_RESPONSE" | jq .
SESSION_ID=$(echo "$CREATE_SESSION_RESPONSE" | jq -r '.sessionId')
print_result $? "Create Session"
echo ""

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" == "null" ]; then
  echo -e "${RED}Failed to create session. Exiting.${NC}"
  exit 1
fi

echo -e "${YELLOW}=== Test 2: Presign Chunk ===${NC}"
PRESIGN_RESPONSE=$(api_request POST "/api/audio/sessions/${SESSION_ID}/chunks/presign" '{
  "seq": 1,
  "tStartMs": 0,
  "tEndMs": 5000,
  "ext": "webm",
  "sizeBytes": 412340,
  "contentType": "audio/webm"
}')

echo "$PRESIGN_RESPONSE" | jq .
PRESIGNED_URL=$(echo "$PRESIGN_RESPONSE" | jq -r '.putUrl')
OBJECT_KEY=$(echo "$PRESIGN_RESPONSE" | jq -r '.objectKey')
print_result $? "Presign Chunk"
echo ""

echo -e "${YELLOW}=== Test 3: Upload to Presigned URL (Simulated) ===${NC}"
# Create a dummy audio file for testing
TEST_FILE="/tmp/test-audio-chunk.webm"
dd if=/dev/urandom of="$TEST_FILE" bs=1024 count=400 2>/dev/null

# Upload to S3 using presigned URL
if [ -n "$PRESIGNED_URL" ] && [ "$PRESIGNED_URL" != "null" ]; then
  curl -s -X PUT \
    -H "Content-Type: audio/webm" \
    -H "x-amz-meta-user-id: test-user" \
    -H "x-amz-meta-session-id: $SESSION_ID" \
    -H "x-amz-meta-seq: 1" \
    --data-binary "@$TEST_FILE" \
    "$PRESIGNED_URL"

  print_result $? "Upload to S3"
  echo ""
else
  echo -e "${RED}No presigned URL available${NC}"
  echo ""
fi

echo -e "${YELLOW}=== Test 4: Complete Chunk ===${NC}"
COMPLETE_RESPONSE=$(api_request POST "/api/audio/sessions/${SESSION_ID}/chunks/complete" '{
  "seq": 1,
  "objectKey": "'"$OBJECT_KEY"'",
  "bytes": 409600,
  "tStartMs": 0,
  "tEndMs": 5000,
  "md5": "abc123",
  "sha256": "def456"
}')

echo "$COMPLETE_RESPONSE" | jq .
print_result $? "Complete Chunk"
echo ""

echo -e "${YELLOW}=== Test 5: Upsert Manifest ===${NC}"
MANIFEST_RESPONSE=$(api_request PUT "/api/audio/sessions/${SESSION_ID}/manifest" '{
  "sessionId": "'"$SESSION_ID"'",
  "codec": "webm/opus",
  "sampleRate": 48000,
  "chunks": [
    {
      "seq": 1,
      "key": "'"$OBJECT_KEY"'",
      "tStartMs": 0,
      "tEndMs": 5000,
      "bytes": 409600
    }
  ],
  "final": false
}')

echo "$MANIFEST_RESPONSE" | jq .
print_result $? "Upsert Manifest"
echo ""

echo -e "${YELLOW}=== Test 6: Finalize Session ===${NC}"
FINALIZE_RESPONSE=$(api_request POST "/api/audio/sessions/${SESSION_ID}/finalize" '{
  "durationMs": 5000,
  "final": true
}')

echo "$FINALIZE_RESPONSE" | jq .
print_result $? "Finalize Session"
echo ""

# Cleanup
rm -f "$TEST_FILE"

echo -e "${GREEN}=== All Tests Complete ===${NC}"
echo ""
echo "Session ID: $SESSION_ID"
echo "Object Key: $OBJECT_KEY"
echo ""
echo "To verify in S3:"
echo "  aws s3 ls s3://${S3_BUCKET_NAME}/users/ --recursive | grep $SESSION_ID"

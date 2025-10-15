#!/bin/bash
# Test Audio API endpoints with Cognito authentication

API_URL="https://1avw7l3k1b.execute-api.us-east-2.amazonaws.com"
ID_TOKEN="eyJraWQiOiJ6OFIrRTVhWXFsMXU3Sk1MdXluWEg0dXljKzh6UGNIYnhJQUM2WTZ6bG9RPSIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiI2MTdiNzU3MC0zMGExLTcwYTctMDkzMS05NDc2MzQ4YzU3ZWEiLCJpc3MiOiJodHRwczpcL1wvY29nbml0by1pZHAudXMtZWFzdC0yLmFtYXpvbmF3cy5jb21cL3VzLWVhc3QtMl9Mb3NNV3ZjMUciLCJjb2duaXRvOnVzZXJuYW1lIjoiNjE3Yjc1NzAtMzBhMS03MGE3LTA5MzEtOTQ3NjM0OGM1N2VhIiwib3JpZ2luX2p0aSI6IjRkMDI1YmI5LTE1YWEtNDExZC05NTdkLTlmM2EwY2VkYTViYSIsImF1ZCI6IjVyZjg2bWJqbnRuaGVzbWQ5bGIwNGc2a21wIiwiZXZlbnRfaWQiOiIxNWEzYTg2Mi1iNGZhLTQ3MGUtODQyMi0wYmRiNTRkOTAxYTAiLCJ0b2tlbl91c2UiOiJpZCIsImF1dGhfdGltZSI6MTc2MDUwMTM3MiwiZXhwIjoxNzYwNTA0OTcyLCJpYXQiOjE3NjA1MDEzNzIsImp0aSI6IjVkZmI4NjA0LTYxM2UtNDhmZS1iODY5LTRiOWY4YTUyZDNjMyIsImVtYWlsIjoiZG1hckBjYXBzdWxlLmNvbSJ9.fzudnAxTsQw-xW0T70jpK0O1JM48vxEZX1-gs77eHpVqNG2ZKjBJXv1_gXFP9D9qR9ZA8G7vmJipt0S9LotEuddNVoTHysbVsV4XMIZeFAWh5Aoxp1VcvoavLufSFc6rlHo51uo6IwRhbpx19eu1Q-CecsDapPNpoXxwEbb6UtzAZ99IIzISByRIoYWlAxDw8xw0Hx-KnYnRh5usB-V2e0F82DXxzKs2HrAmTAtSGQ64Iiw9HCtH2s8ZOOtbCib18iE8VUuFKBLWybUeYciQtGGNOsxsUnppYkwZLfHMzQkFKxdopqIJ20USRkg20t4UDrgike76YZ1JwCiFnPDGAg"

echo "============================================"
echo "Audio API Test Suite"
echo "============================================"
echo "API URL: $API_URL"
echo "Token: ${ID_TOKEN:0:50}..."
echo ""

# Test 1: Create Session
echo "=== Test 1: Create Session ==="
SESSION_RESPONSE=$(curl -s -X POST \
  "${API_URL}/api/audio/sessions" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "codec": "webm",
    "sampleRate": 48000
  }')

echo "$SESSION_RESPONSE" | jq '.'

# Extract sessionId from response
SESSION_ID=$(echo "$SESSION_RESPONSE" | jq -r '.sessionId')

if [ "$SESSION_ID" == "null" ] || [ -z "$SESSION_ID" ]; then
  echo "❌ Failed to create session"
  exit 1
fi

echo "✓ Session created: $SESSION_ID"
echo ""

# Test 2: Presign Chunk
echo "=== Test 2: Presign Chunk Upload ==="
PRESIGN_RESPONSE=$(curl -s -X POST \
  "${API_URL}/api/audio/sessions/${SESSION_ID}/chunks/presign" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "seq": 1,
    "tStartMs": 0,
    "tEndMs": 5000,
    "ext": "webm",
    "sizeBytes": 409600,
    "contentType": "audio/webm"
  }')

echo "$PRESIGN_RESPONSE" | jq '.'

# Extract presigned URL and object key
PUT_URL=$(echo "$PRESIGN_RESPONSE" | jq -r '.putUrl')
OBJECT_KEY=$(echo "$PRESIGN_RESPONSE" | jq -r '.objectKey')

if [ "$PUT_URL" == "null" ] || [ -z "$PUT_URL" ]; then
  echo "❌ Failed to get presigned URL"
  exit 1
fi

echo "✓ Presigned URL obtained"
echo ""

# Test 3: Upload Fake Audio Chunk to S3
echo "=== Test 3: Upload Fake Audio Chunk to S3 ==="
# Create a small fake audio file (just test data)
FAKE_AUDIO_DATA="FAKE_WEBM_AUDIO_DATA_FOR_TESTING_$(date +%s)"
echo "$FAKE_AUDIO_DATA" > /tmp/test_chunk.webm

UPLOAD_RESPONSE=$(curl -s -X PUT \
  "$PUT_URL" \
  -H "Content-Type: audio/webm" \
  -H "x-amz-server-side-encryption: AES256" \
  --data-binary "@/tmp/test_chunk.webm" \
  -w "\nHTTP_STATUS:%{http_code}")

HTTP_STATUS=$(echo "$UPLOAD_RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)

if [ "$HTTP_STATUS" == "200" ]; then
  echo "✓ Chunk uploaded to S3 (HTTP $HTTP_STATUS)"
else
  echo "❌ Failed to upload chunk to S3 (HTTP $HTTP_STATUS)"
  echo "$UPLOAD_RESPONSE"
  exit 1
fi
echo ""

# Test 4: Complete Chunk (Verify Upload)
echo "=== Test 4: Complete Chunk ==="
CHUNK_SIZE=$(stat -f%z /tmp/test_chunk.webm 2>/dev/null || stat -c%s /tmp/test_chunk.webm)

COMPLETE_RESPONSE=$(curl -s -X POST \
  "${API_URL}/api/audio/sessions/${SESSION_ID}/chunks/complete" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"objectKey\": \"$OBJECT_KEY\",
    \"seq\": 1,
    \"tStartMs\": 0,
    \"tEndMs\": 5000,
    \"bytes\": $CHUNK_SIZE
  }")

echo "$COMPLETE_RESPONSE" | jq '.'

CHUNK_VERIFIED=$(echo "$COMPLETE_RESPONSE" | jq -r '.ok')
if [ "$CHUNK_VERIFIED" == "true" ]; then
  echo "✓ Chunk verified and manifest updated"
else
  echo "❌ Failed to verify chunk"
  exit 1
fi
echo ""

# Test 5: Finalize Session
echo "=== Test 5: Finalize Session ==="
FINALIZE_RESPONSE=$(curl -s -X POST \
  "${API_URL}/api/audio/sessions/${SESSION_ID}/finalize" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "final": true,
    "durationMs": 5000
  }')

echo "$FINALIZE_RESPONSE" | jq '.'

SESSION_FINALIZED=$(echo "$FINALIZE_RESPONSE" | jq -r '.ok')
if [ "$SESSION_FINALIZED" == "true" ]; then
  echo "✓ Session finalized"
else
  echo "❌ Failed to finalize session"
  exit 1
fi
echo ""

# Test 6: Verify S3 Objects
echo "=== Test 6: Verify S3 Objects ==="
MANIFEST_KEY=$(echo "$FINALIZE_RESPONSE" | jq -r '.manifestKey')
echo "Manifest key: $MANIFEST_KEY"

aws s3 ls "s3://dbm-test-1100-13-2025/${MANIFEST_KEY}" && echo "✓ Manifest exists in S3" || echo "❌ Manifest not found"
aws s3 ls "s3://dbm-test-1100-13-2025/${OBJECT_KEY}" && echo "✓ Chunk exists in S3" || echo "❌ Chunk not found"
echo ""

# Cleanup
rm -f /tmp/test_chunk.webm

echo "============================================"
echo "All tests completed successfully!"
echo "============================================"
echo ""
echo "Summary:"
echo "  ✓ Session created: $SESSION_ID"
echo "  ✓ Chunk uploaded: $OBJECT_KEY"
echo "  ✓ Manifest updated: $MANIFEST_KEY"
echo "  ✓ Session finalized"
echo ""
echo "Next steps:"
echo "  1. Check CloudWatch logs: https://console.aws.amazon.com/cloudwatch/home?region=us-east-2#logsV2:log-groups"
echo "  2. View S3 bucket: https://s3.console.aws.amazon.com/s3/buckets/dbm-test-1100-13-2025"
echo "  3. Monitor costs: https://console.aws.amazon.com/billing/home"

#!/bin/bash
aws cognito-idp admin-create-user \
    --user-pool-id us-east-2_LosMWvc1G \
    --username dmar@capsule.com \
    --temporary-password TempPass123! \
    --message-action SUPPRESS \
    --region us-east-2

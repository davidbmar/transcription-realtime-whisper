#!/usr/bin/bash  
aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id 5rf86mbjntnhesmd9lb04g6kmp \
    --auth-parameters USERNAME=david.bryan.mar@gmail.com,PASSWORD=BearTequila73;11 \
    --region us-east-2

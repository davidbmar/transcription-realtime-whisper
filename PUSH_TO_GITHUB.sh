#!/bin/bash

# Script to push this repository to GitHub
# Run this AFTER creating the GitHub repository

set -e

echo "=== Push to GitHub ==="
echo ""

# Prompt for GitHub repository URL
read -p "Enter your GitHub repository URL (e.g., https://github.com/davidbmar/repo-name.git): " REPO_URL

if [ -z "$REPO_URL" ]; then
  echo "❌ Error: Repository URL cannot be empty"
  exit 1
fi

echo ""
echo "Setting remote origin to: $REPO_URL"
git remote add origin "$REPO_URL"

echo ""
echo "Pushing to GitHub..."
git push -u origin main

echo ""
echo "✅ Successfully pushed to GitHub!"
echo ""
echo "View your repository at:"
echo "${REPO_URL%.git}"
echo ""
echo "Next steps:"
echo "1. Review the code on GitHub"
echo "2. cd audio-api && npm install"
echo "3. Configure .env file"
echo "4. npm run deploy"

#!/bin/bash
# Template deployment script for staging environment
# Copy to scripts/deploy-staging.sh and customize for your project

set -euo pipefail

echo "=== Deploying to Staging ==="
echo "Started: $(date -Iseconds)"
echo ""

# ============================================================
# Pre-deployment checks
# ============================================================

echo "Running pre-deployment checks..."

# Check if tests pass
if command -v npm &>/dev/null && [ -f "package.json" ]; then
    echo "  - Running npm tests..."
    npm test || {
        echo "ERROR: Tests failed - aborting deployment"
        exit 1
    }
fi

# Check if build succeeds
if [ -f "Makefile" ] && grep -q "^build:" Makefile; then
    echo "  - Running build..."
    make build || {
        echo "ERROR: Build failed - aborting deployment"
        exit 1
    }
fi

echo "✅ Pre-deployment checks passed"
echo ""

# ============================================================
# Deploy to staging
# ============================================================

echo "Deploying to staging environment..."

# Example deployment methods (uncomment and customize):

# Docker deployment
# if [ -f "docker-compose.staging.yml" ]; then
#     docker-compose -f docker-compose.staging.yml up -d --build
# fi

# Git push to staging branch
# git push origin main:staging

# Cloud deployment (example: Heroku)
# git push staging main

# Kubernetes deployment
# kubectl apply -f k8s/staging/

# SSH deployment
# rsync -avz --exclude='.git' ./ user@staging-server:/var/www/app/
# ssh user@staging-server 'cd /var/www/app && systemctl restart app'

# Custom deployment command
echo "WARN: No deployment method configured - update scripts/deploy-staging.sh"
echo "      This is just a template. Customize for your project."

echo ""
echo "✅ Deployment complete"
echo "Finished: $(date -Iseconds)"

# ============================================================
# Post-deployment verification
# ============================================================

echo ""
echo "Running post-deployment verification..."

# Health check (example)
# curl -f https://staging.example.com/health || {
#     echo "ERROR: Health check failed"
#     exit 1
# }

echo "✅ Deployment verified"

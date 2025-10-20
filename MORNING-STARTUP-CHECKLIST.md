# Morning Startup Checklist

## Quick Start (If Build Box IP Hasn't Changed)

```bash
./scripts/220-startup-restore.sh
```

Then open in browser: `https://3.16.164.228/`

---

## ⚠️ CRITICAL ISSUE: Build Box IP Changes on Reboot

**Problem:** The build box (edge proxy) does NOT have an Elastic IP, so its IP changes when AWS restarts it.

**When this happens:**
- ❌ You can't access `https://OLD_IP/` from your MacBook
- ❌ Script 220 output shows wrong URL
- ❌ Caddy `.env-http` has wrong DOMAIN

**Symptoms:**
- Browser shows "ERR_CONNECTION_TIMED_OUT"
- Page doesn't load at all

---

## How to Fix Build Box IP Change

### Step 1: Find Current Build Box IP

```bash
# On build box, check current IP
curl -s ifconfig.me
```

### Step 2: Update .env File

```bash
# Update BUILDBOX_PUBLIC_IP in .env
sed -i "s/^BUILDBOX_PUBLIC_IP=.*/BUILDBOX_PUBLIC_IP=NEW_IP_HERE/" .env
```

### Step 3: Verify Security Group Allows Your MacBook

Your MacBook IP: `136.62.92.204` (from `authorized_clients.txt`)

```bash
# Check if MacBook is allowed on build box port 443
source .env
aws ec2 describe-security-groups \
  --group-ids $BUILDBOX_SECURITY_GROUP \
  --region us-east-2 \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[].CidrIp' \
  --output text
```

Should show: `136.62.92.204/32`

### Step 4: Access WhisperLive

```bash
# Use the NEW build box IP
https://NEW_BUILDBOX_IP/
```

---

## Long-Term Solution: Allocate Elastic IP for Build Box

**Recommended:** Allocate an Elastic IP for the build box so the IP never changes.

```bash
# Allocate Elastic IP
aws ec2 allocate-address --region us-east-2 --domain vpc

# Associate with build box instance
BUILD_BOX_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 associate-address \
  --instance-id $BUILD_BOX_INSTANCE_ID \
  --allocation-id ALLOCATION_ID_FROM_ABOVE \
  --region us-east-2
```

**Cost:** ~$0.005/hour (~$3.60/month) if the build box is always running

---

## Current System State

**Last Known Configuration (Oct 20, 2025):**
- Build Box IP: `3.16.164.228`
- GPU Instance ID: `i-04ee374f3582d64d0`
- GPU Last IP: `18.218.177.167` (will change on startup)
- MacBook IP: `136.62.92.204`

**Architecture:**
```
MacBook (136.62.92.204)
   ↓ HTTPS port 443
Build Box Edge (3.16.164.228) ← IP CHANGES ON REBOOT!
   ├─ Caddy serves index.html
   └─ Caddy proxies /ws → GPU:9090
      ↓
GPU Worker (18.218.177.167) ← IP CHANGES ON STARTUP!
   └─ WhisperLive server (internal only)
```

---

## Daily Workflow (Normal Case)

**Evening:**
```bash
./scripts/210-shutdown-gpu.sh
```

**Morning:**
```bash
# 1. Start GPU and restore WhisperLive
./scripts/220-startup-restore.sh

# 2. Get the build box IP from script output, then open:
https://BUILD_BOX_IP/
```

**Time:** 3-5 minutes total

**Cost Savings:** ~$0.526/hour × 12 hours/night = ~$6.31/night

---

## Troubleshooting

### GPU Won't Start
```bash
./scripts/750-status-gpu-instance.sh
./scripts/730-start-gpu-instance.sh
```

### WhisperLive Not Running on GPU
```bash
ssh -i ~/.ssh/dbm-oct18-2025.pem ubuntu@GPU_IP 'systemctl status whisperlive'
ssh -i ~/.ssh/dbm-oct18-2025.pem ubuntu@GPU_IP 'sudo journalctl -u whisperlive -f'
```

### Caddy Not Proxying Correctly
```bash
# Check Caddy has correct GPU IP
docker exec whisperlive-edge env | grep GPU_HOST

# Should match current GPU IP - if not, recreate container:
docker rm -f whisperlive-edge
docker compose up -d
```

### MacBook Can't Connect
1. Check your MacBook IP: `curl ifconfig.me` (should be `136.62.92.204`)
2. If changed, run: `./scripts/031-configure-buildbox-security.sh`
3. Verify build box IP is correct in browser URL

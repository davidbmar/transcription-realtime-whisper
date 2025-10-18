Here’s the same full guide formatted as a clean **Markdown file** — ready to save as
`WhisperLive_AWS_Deployment_Guide.md` or commit to your repo.

---

````markdown
# 🚀 WhisperLive Deployment Guide (AWS + Mac Client)

A step-by-step setup guide to deploy **WhisperLive** on AWS EC2 and stream real-time audio from your Mac for speech recognition testing.

---

## 1️⃣ AWS EC2 SETUP

### Launch the Instance
| Setting | Value |
|----------|--------|
| **AMI** | Ubuntu 22.04 LTS |
| **Instance Type** | `t3.large` (CPU) or `g4dn.xlarge` (GPU T4) |
| **Storage** | 50 GB SSD |
| **Key Pair** | Your SSH key |
| **Security Group** | Allow TCP 22 & 9090 only from your Mac IP |

### Connect to EC2
```bash
ssh -i ~/.ssh/<yourkey>.pem ubuntu@<EC2-Public-IP>
````

---

## 2️⃣ EC2 HOST PREPARATION

### Install Docker

```bash
sudo apt update && sudo apt -y upgrade
sudo apt install -y docker.io
sudo usermod -aG docker ubuntu
# Reconnect SSH after this step
```

### Install NVIDIA Container Toolkit (GPU only)

```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/libnvidia-container.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo systemctl restart docker
nvidia-smi   # verify GPU available
```

---

## 3️⃣ PREFETCH MODEL (Faster-Whisper)

```bash
mkdir -p ~/wl-cache && chmod 777 ~/wl-cache
docker run --rm \
  -v ~/wl-cache:/cache \
  -e HUGGINGFACE_HUB_CACHE=/cache \
  -e XDG_CACHE_HOME=/cache \
  ghcr.io/collabora/whisperlive-cpu:latest \
  python -c 'from faster_whisper import WhisperModel; WhisperModel("small.en"); print("OK: cached small.en")'
```

---

## 4️⃣ RUN THE WHISPERLIVE SERVER

### GPU Version

```bash
docker run -d --name whisperlive \
  --gpus all \
  -p 9090:9090 \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m \
  --tmpfs /var/tmp:rw,noexec,nosuid,nodev,size=256m \
  -e TMPDIR=/tmp \
  -e HUGGINGFACE_HUB_CACHE=/cache \
  -e CTRANSLATE2_CACHE_DIR=/cache \
  -e XDG_CACHE_HOME=/cache \
  -v ~/wl-cache:/cache:rw \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --restart unless-stopped \
  ghcr.io/collabora/whisperlive-gpu:latest \
  python3 run_server.py --port 9090 \
                        --backend faster_whisper \
                        --no_single_model \
                        -c /cache
```

### CPU Version (for cheaper testing)

```bash
docker run -d --name whisperlive \
  -p 9090:9090 \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m \
  --tmpfs /var/tmp:rw,noexec,nosuid,nodev,size=256m \
  -e TMPDIR=/tmp \
  -e HUGGINGFACE_HUB_CACHE=/cache \
  -e CTRANSLATE2_CACHE_DIR=/cache \
  -e XDG_CACHE_HOME=/cache \
  -v ~/wl-cache:/cache:rw \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --restart unless-stopped \
  ghcr.io/collabora/whisperlive-cpu:latest \
  python3 run_server.py --port 9090 \
                        --backend faster_whisper \
                        --no_single_model \
                        -c /cache
```

### Confirm Running

```bash
docker logs --tail=60 whisperlive
sudo ss -ltnp | grep 9090
```

---

## 5️⃣ MAC CLIENT SETUP

### Create Virtual Environment

```bash
python3 -m venv wl-venv
source wl-venv/bin/activate
pip install --upgrade pip
pip install git+https://github.com/collabora/WhisperLive.git
```

### Create `test_client.py`

```python
from whisper_live.client import TranscriptionClient

EC2_IP = "<your-ec2-ip>"
PORT = 9090
AUDIO_PATH = "./test.wav"

client = TranscriptionClient(EC2_IP, PORT, lang="en", translate=False)
client.hf_model = "Systran/faster-whisper-small.en"
print(client(AUDIO_PATH))
```

### Run the Client

```bash
python3 test_client.py
```

✅ You should hear your audio play back and see the transcription printed.

---

## 6️⃣ TROUBLESHOOTING

| Symptom                   | Fix                                                              |
| ------------------------- | ---------------------------------------------------------------- |
| **Connection refused**    | Check EC2 Security Group inbound rule (9090 allowed for your IP) |
| **Failed to load model**  | Ensure `/cache` volume exists & writable; re-run prefetch step   |
| **Read-only FS error**    | Remove `--read-only` flag or set `XDG_CACHE_HOME=/cache`         |
| **WebSocket 0x3e8 close** | Model not loaded; verify `docker logs whisperlive`               |
| **GPU not visible**       | Run `nvidia-smi` and reinstall NVIDIA toolkit if missing         |

---

## 7️⃣ CLEANUP & TEARDOWN

```bash
docker rm -f whisperlive
rm -rf ~/wl-cache
exit   # logout
aws ec2 terminate-instances --instance-ids <your-instance-id>
```

---

## 8️⃣ OPTIONAL ENHANCEMENTS

* Add HTTPS reverse proxy (Caddy/Nginx) on port 443
* Secure with Basic Auth credentials
* Automate deploy/destroy with Terraform or shell script
* Integrate CloudWatch logs for monitoring
* Test larger models (`medium`, `large-v2`) by changing the HF ID

---

## ✅ SUMMARY

This process:

1. Installs Docker & NVIDIA runtime
2. Prefetches Whisper model safely
3. Runs WhisperLive (GPU or CPU)
4. Streams real-time audio from your Mac
5. Produces live transcription output
6. Cleans up everything cleanly afterward

---

*Author: Deployment Automation Notes — WhisperLive GPU/CPU test verified working October 2025.*

```

---

Would you like me to generate this as a downloadable `.md` file so you can drop it straight into your repo (e.g. `/docs/WhisperLive_AWS_Deployment_Guide.md`)?
```


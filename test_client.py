#!/usr/bin/env python3
"""
Simple WhisperLive test client to debug transcription output format.
Connects to WhisperLive and sends audio to see what responses we get.
"""
import asyncio
import websockets
import json
import sys
import wave
import struct

GPU_HOST = "3.138.85.115"
GPU_PORT = 9090

async def test_whisperlive():
    uri = f"ws://{GPU_HOST}:{GPU_PORT}"
    print(f"Connecting to {uri}...")

    try:
        async with websockets.connect(uri) as websocket:
            print("✅ Connected to WhisperLive")

            # Send config
            config = {
                "uid": "test-client-001",
                "task": "transcribe",
                "language": "en",
                "model": "Systran/faster-whisper-small.en",
                "use_vad": False
            }
            print(f"Sending config: {config}")
            await websocket.send(json.dumps(config))

            # Wait for SERVER_READY
            response = await websocket.recv()
            print(f"Received: {response}")

            # Check if we have ffmpeg to convert audio
            import subprocess
            try:
                result = subprocess.run(['which', 'ffmpeg'], capture_output=True)
                if result.returncode == 0:
                    print("\n✅ ffmpeg available - converting WebM to PCM...")
                    # Convert WebM to raw PCM (16kHz, Float32, mono)
                    # ChatGPT says WhisperLive expects Float32, not Int16!
                    subprocess.run([
                        'ffmpeg', '-i', '00000-00060.webm',
                        '-f', 'f32le',  # 32-bit float little-endian
                        '-acodec', 'pcm_f32le',
                        '-ar', '16000',  # 16kHz sample rate
                        '-ac', '1',      # mono
                        '-y',
                        'test_audio.pcm'
                    ], check=True)

                    # Send PCM audio in chunks
                    with open('test_audio.pcm', 'rb') as f:
                        chunk_size = 4096 * 4  # 4096 samples * 4 bytes per Float32
                        chunk_num = 0
                        while True:
                            chunk = f.read(chunk_size)
                            if not chunk:
                                break

                            await websocket.send(chunk)
                            chunk_num += 1
                            if chunk_num % 10 == 0:
                                print(f"Sent chunk {chunk_num} ({len(chunk)} bytes)")

                            # Check for messages while sending
                            try:
                                msg = await asyncio.wait_for(websocket.recv(), timeout=0.01)
                                print(f"\n📨 Received during sending: {msg}\n")
                            except asyncio.TimeoutError:
                                pass

                    print(f"✅ Sent all audio ({chunk_num} chunks)")

                    # Wait for final transcriptions
                    print("\n⏳ Waiting for transcriptions...")
                    for _ in range(10):  # Wait for up to 10 messages
                        try:
                            msg = await asyncio.wait_for(websocket.recv(), timeout=2.0)
                            print(f"📨 Received: {msg}")
                        except asyncio.TimeoutError:
                            print("⏰ Timeout waiting for more messages")
                            break

                else:
                    print("❌ ffmpeg not available - cannot convert WebM to PCM")
                    print("Install with: sudo apt install -y ffmpeg")

            except Exception as e:
                print(f"Error with ffmpeg: {e}")

            print("\n✅ Test complete")

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test_whisperlive())

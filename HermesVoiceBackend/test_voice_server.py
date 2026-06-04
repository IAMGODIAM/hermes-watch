#!/usr/bin/env python3
"""
test_voice_server.py — Lightweight test server (no Whisper dependency).
Simulates the full pipeline with a mock Hermes response.
Use this to validate the WebSocket protocol and TTS before deploying
the full server with Whisper.
"""

import asyncio
import json
import time
import uuid
import io
import logging
import argparse
import base64

import websockets
from websockets.server import WebSocketServerProtocol

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

try:
    import edge_tts
    HAS_TTS = True
except ImportError:
    HAS_TTS = False
    print("WARNING: edge-tts not installed")


async def mock_hermes_response(text: str) -> dict:
    """Simulate Hermes Gateway response."""
    await asyncio.sleep(0.5)  # Simulate processing
    return {
        "text": f"[Mock Hermes] I received: '{text}'. This is a test response from the Hermes voice pipeline.",
        "success": True
    }


async def synthesize_speech(text: str, voice: str = "en-US-GuyNeural") -> bytes:
    """Convert text to speech using edge-tts."""
    if not HAS_TTS:
        return b""
    try:
        communicate = edge_tts.Communicate(text, voice, rate="-15%", pitch="-8Hz")
        audio_data = b""
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio_data += chunk["data"]
        return audio_data
    except Exception as e:
        logger.error(f"TTS error: {e}")
        return b""


async def handle_client(websocket: WebSocketServerProtocol):
    client_id = str(uuid.uuid4())[:8]
    logger.info(f"Client connected: {client_id}")

    try:
        async for message in websocket:
            if isinstance(message, str):
                data = json.loads(message)
                msg_type = data.get("type", "")

                if msg_type == "ping":
                    await websocket.send(json.dumps({
                        "type": "pong",
                        "timestamp": time.time()
                    }))
                    logger.info(f"Ping from {client_id}")

                elif msg_type == "voice_audio":
                    request_id = data.get("request_id", str(uuid.uuid4())[:8])
                    
                    # Mock transcript
                    transcript = data.get("mock_transcript", "Hello Hermes, this is a test.")
                    await websocket.send(json.dumps({
                        "type": "transcript",
                        "text": transcript,
                        "request_id": request_id
                    }))
                    logger.info(f"Transcript: {transcript}")

                    # Mock Hermes response
                    await websocket.send(json.dumps({
                        "type": "processing",
                        "request_id": request_id,
                        "stage": "thinking"
                    }))

                    response = await mock_hermes_response(transcript)
                    response_text = response["text"]

                    await websocket.send(json.dumps({
                        "type": "response",
                        "text": response_text,
                        "request_id": request_id
                    }))
                    logger.info(f"Response: {response_text[:80]}...")

                    # TTS
                    if HAS_TTS:
                        await websocket.send(json.dumps({
                            "type": "processing",
                            "request_id": request_id,
                            "stage": "speaking"
                        }))
                        tts_audio = await synthesize_speech(response_text)
                        if tts_audio:
                            await websocket.send(tts_audio)
                            logger.info(f"Sent TTS audio: {len(tts_audio)} bytes")

                elif msg_type == "test_tts":
                    # Direct TTS test
                    text = data.get("text", "Hello, this is a test of the Hermes voice system.")
                    audio = await synthesize_speech(text)
                    if audio:
                        # Send as base64-encoded JSON
                        await websocket.send(json.dumps({
                            "type": "tts_audio_b64",
                            "audio_b64": base64.b64encode(audio).decode(),
                            "format": "mp3",
                            "text": text
                        }))
                        logger.info(f"TTS test: {len(audio)} bytes for '{text[:50]}'")

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Client disconnected: {client_id}")
    except Exception as e:
        logger.error(f"Error handling client {client_id}: {e}")


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8422)
    args = parser.parse_args()

    logger.info(f"Test Voice Server starting on ws://{args.host}:{args.port}")
    logger.info(f"TTS available: {HAS_TTS}")

    async with websockets.serve(
        handle_client, args.host, args.port,
        max_size=10 * 1024 * 1024,
        ping_interval=20, ping_timeout=10
    ):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())

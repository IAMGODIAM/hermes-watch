#!/usr/bin/env python3
"""
hermes_voice_server.py

WebSocket voice server that bridges iPhone relay to Hermes Agent.
Receives audio → Whisper transcription → Hermes LLM → TTS → returns audio.

Architecture:
  Apple Watch → iPhone Relay → THIS SERVER → Hermes Gateway (Boardroom 8420)
                                                      ↓
                                              Hermie (LLM Agent)
                                                      ↓
                                                   TTS
                                                      ↓
  Apple Watch ← iPhone Relay ← THIS SERVER ← Hermes Gateway

Usage:
  pip install websockets av whisper-edge-tts torch torchaudio edge-tts aiohttp
  python hermes_voice_server.py --host 0.0.0.0 --port 8420 --hermes-host localhost --hermes-port 8420

Requirements:
  - Python 3.10+
  - PyTorch + torchaudio (for Whisper)
  - edge-tts (TTS engine)
  - websockets
  - av (PyAV for audio processing)
"""

import asyncio
import json
import logging
import time
import uuid
import argparse
import io
from pathlib import Path
from typing import Optional

import websockets
from websockets.server import WebSocketServerProtocol
import numpy as np

# Audio processing
try:
    import av
    HAS_AV = True
except ImportError:
    HAS_AV = False
    print("WARNING: PyAV not installed. Audio conversion will be limited.")

# TTS
try:
    import edge_tts
    HAS_EDGE_TTS = True
except ImportError:
    HAS_EDGE_TTS = False
    print("WARNING: edge-tts not installed. TTS will not work.")

# Whisper for transcription
try:
    import torch
    import whisper
    HAS_WHISPER = True
except ImportError:
    HAS_WHISPER = False
    print("WARNING: whisper not installed. Transcription will not work.")

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)


class AudioProcessor:
    """Handles audio format conversion and resampling."""

    @staticmethod
    def aac_to_wav(aac_data: bytes, target_sr: int = 16000) -> Optional[bytes]:
        """Convert AAC audio data to WAV format."""
        if not HAS_AV:
            # Fallback: try to pass through if already correct format
            logger.warning("PyAV not available, returning raw AAC data")
            return aac_data

        try:
            container = av.open(io.BytesIO(aac_data))
            stream = container.streams.audio[0]

            resampler = av.AudioResampler(
                format='s16',
                layout='mono',
                rate=target_sr
            )

            frames = []
            for frame in container.decode(stream):
                resampled = resampler.resample(frame)
                frames.extend(resampled.to_ndarray().flatten())

            container.close()

            # Convert to WAV
            audio_array = np.array(frames, dtype=np.int16)
            wav_buffer = io.BytesIO()
            import wave
            with wave.open(wav_buffer, 'wb') as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(target_sr)
                wf.writeframes(audio_array.tobytes())

            return wav_buffer.getvalue()

        except Exception as e:
            logger.error(f"AAC to WAV conversion failed: {e}")
            return None

    @staticmethod
    def mp3_to_raw(mp3_data: bytes, target_sr: int = 16000) -> Optional[np.ndarray]:
        """Convert MP3 audio to raw numpy array for Whisper."""
        if not HAS_AV:
            return None

        try:
            container = av.open(io.BytesIO(mp3_data))
            stream = container.streams.audio[0]

            resampler = av.AudioResampler(
                format='flt',
                layout='mono',
                rate=target_sr
            )

            frames = []
            for frame in container.decode(stream):
                resampled = resampler.resample(frame)
                frames.append(resampled.to_ndarray().flatten())

            container.close()

            if frames:
                return np.concatenate(frames).astype(np.float32)
            return None

        except Exception as e:
            logger.error(f"MP3 conversion failed: {e}")
            return None


class WhisperTranscriber:
    """Speech-to-text using OpenAI Whisper."""

    def __init__(self, model_size: str = "base"):
        self.model = None
        self.model_size = model_size
        self._loaded = False

    def load(self):
        if not HAS_WHISPER:
            logger.warning("Whisper not available, using dummy transcription")
            return
        logger.info(f"Loading Whisper model: {self.model_size}")
        self.model = whisper.load_model(self.model_size)
        self._loaded = True
        logger.info("Whisper model loaded")

    async def transcribe(self, audio_data: bytes, sample_rate: int = 16000) -> str:
        if not self._loaded or self.model is None:
            return "[Whisper not available — text transcription disabled]"

        try:
            # Convert to numpy array
            wav_processor = AudioProcessor()
            raw_audio = wav_processor.mp3_to_raw(audio_data, sample_rate)

            if raw_audio is None:
                # Try direct bytes as WAV
                audio_array = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0
            else:
                audio_array = raw_audio

            # Run in thread pool to not block
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: self.model.transcribe(audio_array, language="en", fp16=torch.cuda.is_available())
            )

            text = result.get("text", "").strip()
            logger.info(f"Transcription: {text}")
            return text

        except Exception as e:
            logger.error(f"Transcription error: {e}")
            return f"[Transcription error: {e}]"


class TTSEngine:
    """Text-to-speech using Microsoft Edge TTS."""

    def __init__(self, voice: str = "en-US-GuyNeural", rate: str = "-15%", pitch: str = "-8Hz"):
        self.voice = voice
        self.rate = rate
        self.pitch = pitch

    async def synthesize(self, text: str) -> Optional[bytes]:
        if not HAS_EDGE_TTS:
            logger.warning("edge-tts not available")
            return None

        try:
            communicate = edge_tts.Communicate(text, self.voice, rate=self.rate, pitch=self.pitch)
            audio_data = b""
            async for chunk in communicate.stream():
                if chunk["type"] == "audio":
                    audio_data += chunk["data"]

            # Convert to AAC for Watch compatibility
            if HAS_AV and audio_data:
                return self._mp3_to_aac(audio_data)

            return audio_data

        except Exception as e:
            logger.error(f"TTS error: {e}")
            return None

    @staticmethod
    def _mp3_to_aac(mp3_data: bytes) -> bytes:
        """Convert MP3 to AAC for Watch compatibility."""
        try:
            input_container = av.open(io.BytesIO(mp3_data))
            output_buffer = io.BytesIO()
            output_container = av.open(output_buffer, mode='wb', format='mp4')
            aac_stream = output_container.add_stream('aac', rate=24000)
            aac_stream.time_base = aac_stream.codec_context.time_base

            for packet in input_container.demux(0):
                for frame in packet.decode():
                    for pkt in aac_stream.encode(frame):
                        output_container.mux(pkt)

            # Flush
            for pkt in aac_stream.encode():
                output_container.mux(pkt)

            input_container.close()
            output_container.close()

            return output_buffer.getvalue()
        except Exception:
            return mp3_data  # Fallback: return MP3


class HermesClient:
    """Communicates with the Hermes Gateway (Boardroom) via HTTP or WebSocket."""

    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.base_url = f"http://{host}:{port}"

    async def send_message(self, text: str) -> dict:
        """Send transcribed text to Hermes and get response."""
        try:
            import aiohttp
            async with aiohttp.ClientSession() as session:
                # Try Boardroom chat endpoint
                url = f"{self.base_url}/api/v1/chat"
                payload = {
                    "message": text,
                    "source": "apple_watch_voice",
                    "session_id": "watch_voice_session"
                }

                async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=60)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        return {
                            "text": data.get("response", data.get("text", data.get("message", ""))),
                            "success": True
                        }
                    else:
                        text_resp = await resp.text()
                        logger.warning(f"Hermes API returned {resp.status}: {text_resp[:200]}")
                        return {"text": f"Hermes API error: {resp.status}", "success": False}

        except ImportError:
            # Fallback to urllib
            return await self._send_via_urllib(text)
        except Exception as e:
            logger.error(f"Hermes communication error: {e}")
            return {"text": f"Connection error: {e}", "success": False}

    async def _send_via_urllib(self, text: str) -> dict:
        """Fallback HTTP client using urllib."""
        import urllib.request
        import urllib.error

        try:
            data = json.dumps({
                "message": text,
                "source": "apple_watch_voice"
            }).encode()

            req = urllib.request.Request(
                f"{self.base_url}/api/v1/chat",
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )

            loop = asyncio.get_event_loop()
            response = await loop.run_in_executor(
                None,
                lambda: urllib.request.urlopen(req, timeout=60)
            )

            result = json.loads(response.read().decode())
            return {"text": result.get("response", ""), "success": True}

        except Exception as e:
            logger.error(f"urllib fallback error: {e}")
            return {"text": f"Connection failed: {e}", "success": False}


class HermesVoiceServer:
    """Main WebSocket voice server."""

    def __init__(self, host: str, port: int, hermes_host: str, hermes_port: int,
                 whisper_model: str = "base", tts_voice: str = "en-US-GuyNeural"):
        self.host = host
        self.port = port
        self.hermes = HermesClient(hermes_host, hermes_port)
        self.transcriber = WhisperTranscriber(whisper_model)
        self.tts = TTSEngine(tts_voice)
        self.audio_processor = AudioProcessor()
        self.connected_clients: dict[str, WebSocketServerProtocol] = {}

    async def start(self):
        """Start the WebSocket server."""
        self.transcriber.load()

        logger.info(f"Starting Hermes Voice Server on ws://{self.host}:{self.port}")
        logger.info(f"Hermes Gateway: {self.hermes.base_url}")
        logger.info(f"TTS Voice: {self.tts.voice}")
        logger.info(f"Whisper Model: {self.transcriber.model_size}")

        async with websockets.serve(
            self.handle_client,
            self.host,
            self.port,
            max_size=10 * 1024 * 1024,  # 10MB max message
            ping_interval=20,
            ping_timeout=10
        ):
            logger.info("Server is running. Waiting for connections...")
            await asyncio.Future()  # Run forever

    async def handle_client(self, websocket: WebSocketServerProtocol):
        client_id = str(uuid.uuid4())[:8]
        self.connected_clients[client_id] = websocket
        logger.info(f"Client connected: {client_id} from {websocket.remote_address}")

        try:
            async for message in websocket:
                if isinstance(message, bytes):
                    # Binary audio data
                    await self.handle_audio(client_id, websocket, message)
                else:
                    # JSON control message
                    await self.handle_control_message(client_id, websocket, message)

        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client disconnected: {client_id}")
        finally:
            del self.connected_clients[client_id]

    async def handle_control_message(self, client_id: str, websocket: WebSocketServerProtocol, message: str):
        try:
            data = json.loads(message)
            msg_type = data.get("type", "")

            if msg_type == "ping":
                await websocket.send(json.dumps({
                    "type": "pong",
                    "timestamp": time.time(),
                    "clients_connected": len(self.connected_clients)
                }))

            elif msg_type == "voice_audio":
                # Audio embedded as base64 in JSON
                import base64
                audio_b64 = data.get("audio_b64", "")
                if audio_b64:
                    audio_data = base64.b64decode(audio_b64)
                    await self.process_voice(client_id, websocket, audio_data, data)

            elif msg_type == "config":
                # Update configuration
                if "tts_voice" in data:
                    self.tts.voice = data["tts_voice"]
                await websocket.send(json.dumps({
                    "type": "config_ack",
                    "tts_voice": self.tts.voice
                }))

            else:
                await websocket.send(json.dumps({
                    "type": "error",
                    "message": f"Unknown message type: {msg_type}"
                }))

        except json.JSONDecodeError:
            await websocket.send(json.dumps({
                "type": "error",
                "message": "Invalid JSON"
            }))

    async def handle_audio(self, client_id: str, websocket: WebSocketServerProtocol, audio_data: bytes):
        """Handle raw binary audio data."""
        await self.process_voice(client_id, websocket, audio_data, {})

    async def process_voice(self, client_id: str, websocket: WebSocketServerProtocol,
                            audio_data: bytes, metadata: dict):
        """Full voice processing pipeline."""
        request_id = metadata.get("request_id", str(uuid.uuid4())[:8])
        start_time = time.time()

        try:
            # Step 1: Send acknowledgment
            await websocket.send(json.dumps({
                "type": "processing",
                "request_id": request_id,
                "stage": "transcribing"
            }))

            # Step 2: Transcribe audio
            transcript = await self.transcriber.transcribe(
                audio_data,
                metadata.get("sample_rate", 16000)
            )

            # Send transcript
            await websocket.send(json.dumps({
                "type": "transcript",
                "text": transcript,
                "request_id": request_id
            }))

            # Step 3: Send to Hermes
            await websocket.send(json.dumps({
                "type": "processing",
                "request_id": request_id,
                "stage": "thinking"
            }))

            hermes_response = await self.hermes.send_message(transcript)
            response_text = hermes_response.get("text", "I'm sorry, I couldn't process that.")

            # Send response text
            await websocket.send(json.dumps({
                "type": "response",
                "text": response_text,
                "request_id": request_id,
                "processing_time": round(time.time() - start_time, 2)
            }))

            # Step 4: Synthesize TTS
            await websocket.send(json.dumps({
                "type": "processing",
                "request_id": request_id,
                "stage": "speaking"
            }))

            tts_audio = await self.tts.synthesize(response_text)

            if tts_audio:
                # Send TTS audio as binary
                await websocket.send(tts_audio)
                logger.info(f"Sent TTS audio: {len(tts_audio)} bytes")
            else:
                await websocket.send(json.dumps({
                    "type": "tts_error",
                    "request_id": request_id,
                    "message": "TTS synthesis failed"
                }))

            total_time = round(time.time() - start_time, 2)
            logger.info(f"Request {request_id} complete in {total_time}s | "
                        f"Transcript: '{transcript[:50]}...' | Response: '{response_text[:50]}...'")

        except Exception as e:
            logger.error(f"Error processing voice request {request_id}: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "request_id": request_id,
                "message": str(e)
            }))


def main():
    parser = argparse.ArgumentParser(description="Hermes Voice Server for Apple Watch")
    parser.add_argument("--host", default="0.0.0.0", help="WebSocket server host")
    parser.add_argument("--port", type=int, default=8420, help="WebSocket server port")
    parser.add_argument("--hermes-host", default="localhost", help="Hermes Gateway host")
    parser.add_argument("--hermes-port", type=int, default=8420, help="Hermes Gateway port")
    parser.add_argument("--whisper-model", default="base", help="Whisper model size")
    parser.add_argument("--tts-voice", default="en-US-GuyNeural", help="TTS voice")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    server = HermesVoiceServer(
        host=args.host,
        port=args.port,
        hermes_host=args.hermes_host,
        hermes_port=args.hermes_port,
        whisper_model=args.whisper_model,
        tts_voice=args.tts_voice
    )

    asyncio.run(server.start())


if __name__ == "__main__":
    main()

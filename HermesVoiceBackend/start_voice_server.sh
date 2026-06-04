#!/bin/bash
# start_voice_server.sh — Quick start for Hermes Voice Server

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Default config
HOST="${HERMES_VOICE_HOST:-0.0.0.0}"
PORT="${HERMES_VOICE_PORT:-8422}"
HERMES_HOST="${HERMES_GATEWAY_HOST:-localhost}"
HERMES_PORT="${HERMES_GATEWAY_PORT:-8420}"
WHISPER_MODEL="${WHISPER_MODEL:-base}"
TTS_VOICE="${TTS_VOICE:-en-US-GuyNeural}"

echo "╔══════════════════════════════════════════╗"
echo "║     Hermes Voice Server — Quick Start    ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Voice Server:  ws://${HOST}:${PORT}"
echo "║  Hermes GW:     http://${HERMES_HOST}:${HERMES_PORT}"
echo "║  Whisper:       ${WHISPER_MODEL}"
echo "║  TTS Voice:     ${TTS_VOICE}"
echo "╚══════════════════════════════════════════╝"
echo ""

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 not found"
    exit 1
fi

# Install deps if needed
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
else
    source .venv/bin/activate
fi

# Start server
echo "Starting Hermes Voice Server..."
python3 hermes_voice_server.py \
    --host "$HOST" \
    --port "$PORT" \
    --hermes-host "$HERMES_HOST" \
    --hermes-port "$HERMES_PORT" \
    --whisper-model "$WHISPER_MODEL" \
    --tts-voice "$TTS_VOICE" \
    --debug

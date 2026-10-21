#!/usr/bin/env bash
set -euo pipefail

: "${SPEECHKIT_ROUTER_URL:?Set your router origin}"
: "${SPEECHKIT_ROUTER_KEY:?Set your router bearer token}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/SpeechKit/Tests/Transcription/Fixtures/Audio"
mkdir -p "$OUT_DIR"

create_clip() {
  local text="$1"
  local file="$2"
  curl -fsS -X POST "${SPEECHKIT_ROUTER_URL%/}/vendors/elevenlabs/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb" \
    -H "Authorization: Bearer $SPEECHKIT_ROUTER_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    --output "$OUT_DIR/$file" <<JSON
{
  "text": "$text",
  "model_id": "eleven_multilingual_v2",
  "output_format": "mp3_44100_128"
}
JSON
}

create_clip "Hello from SpeechKit integration tests." "clip1_en_intro.mp3"
create_clip "This package supports OpenAI AssemblyAI and ElevenLabs." "clip2_en_providers.mp3"
create_clip "Hej från Stockholm. Jag testar svensk transkribering i SpeechKit." "clip3_sv_example.mp3"
create_clip "Short audio clip number four with punctuation and numbers 42." "clip4_en_numbers.mp3"
create_clip "Realtime dictation test from Stockholm. SpeechKit should buffer the transcript silently while the user is speaking, then paste one final sentence after recording stops." "clip5_realtime_dictation_en.mp3"

echo "Generated fixtures in: $OUT_DIR"
ls -lh "$OUT_DIR"

# Local audio fixtures

No generated audio is distributed in this repository. The original private
fixtures were produced through ElevenLabs, but redistribution rights for the
generation account were not established. They are excluded from the public
snapshot and history.

`scripts/generate-fixtures-elevenlabs.sh` contains five synthetic English and
Swedish test sentences. It generates local MP3s in `Audio/` through your router
using `SPEECHKIT_ROUTER_URL` and `SPEECHKIT_ROUTER_KEY`. Check your provider plan's
terms before generating or sharing output. The script sends only those test
sentences; no recordings, personal vocabulary or transcripts are read.

Live tests expect these local filenames. Realtime tests additionally select a
short abrupt-ending segment; verify its timing when regenerating with a new
voice or model. Offline tests do not load these MP3s.

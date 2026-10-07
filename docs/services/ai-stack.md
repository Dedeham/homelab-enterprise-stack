# AI Stack: Speech Recognition, Vision, and n8n

A small, fully local AI stack for the Docker VM:

| Service | Software | API | Typical use |
|---|---|---|---|
| `whisper` | [speaches](https://github.com/speaches-ai/speaches) (faster-whisper) | OpenAI-compatible `POST /v1/audio/transcriptions` | Voice memos, meeting recordings, subtitles |
| `vision` | [llama.cpp](https://github.com/ggml-org/llama.cpp) server + multimodal GGUF | OpenAI-compatible `POST /v1/chat/completions` with images | Photo descriptions, OCR, document/receipt parsing |
| `n8n` | [n8n](https://n8n.io) + Postgres | Web UI, webhooks | Workflows that chain the two models with other services |

Compose file: [configs/docker/ai-stack/docker-compose.yml](../../configs/docker/ai-stack/docker-compose.yml)

Setup and test procedures: [setup-and-testing/services/ai-stack.md](../setup-and-testing/services/ai-stack.md)

## Architecture

```text
                  LAN / Tailscale only (admin-whitelist)
                               |
                        +------+------+
                        |   Traefik   |
                        +--+---+---+--+
          whisper.example.com  |   n8n.example.com
                           |   |   |
                           | vision.example.com
   +-----------------------+---+---+------------ ai_backend ---+
   |  +-------------+  +---+---+-+  |  +---------+              |
   |  | ai-whisper  |<-+  n8n    +--+->|ai-vision|              |
   |  | :8000       |  | :5678   |  |  | :8080   |              |
   |  +-------------+  +----+----+  |  +---------+              |
   +-----------------------+--------+---------------------------+
                      ai_db |  (internal: true)
                       +----+-----+
                       | Postgres |
                       +----------+
```

- Nothing is exposed to the internet by default. All three routes use the `admin-whitelist@file` middleware (LAN + Tailscale).
- Both model servers require an API key (`WHISPER_API_KEY`, `VISION_API_KEY`), even on the internal network.
- Postgres is on an `internal: true` network and has no internet access.

## Hardware Sizing

The defaults target a CPU-only server with about 16-32 GB RAM (e.g. a 4-core Xeon/i5/i7 with 32 GB).

| Model | RAM (approx.) | CPU speed (4 cores) | Notes |
|---|---|---|---|
| `Systran/faster-whisper-small` | ~1 GB | ~real-time | Recommended default |
| `Systran/faster-whisper-medium` | ~2 GB | ~0.5x real-time | Better with accents/noise |
| `deepdml/faster-whisper-large-v3-turbo-ct2` | ~3 GB | slow on CPU | Best accuracy; use with GPU |
| `ggml-org/Qwen2.5-VL-3B-Instruct-GGUF` | ~3 GB | seconds per image | Strong at OCR/documents |
| `ggml-org/gemma-3-4b-it-GGUF` | ~4-5 GB | seconds per image | Recommended default |
| `ggml-org/gemma-3-12b-it-GGUF` | ~10 GB | slow on CPU | Noticeably better answers |
| `ggml-org/Llama-4-Scout-17B-16E-Instruct-GGUF` | 60+ GB | impractical on CPU | Only for large servers or GPUs |

Intel iGPUs (Quick Sync) do not accelerate this stack; they only accelerate video. A GPU would require switching the images to the CUDA variants (`ghcr.io/speaches-ai/speaches:<version>-cuda`, `ghcr.io/ggml-org/llama.cpp:server-cuda-<build>`) and adding a `deploy.resources.reservations.devices` block.

## Security

- Keep all three routes on `admin-whitelist@file`. For external triggers, only the commented `n8n-webhook` router should be enabled; it exposes `/webhook/*` and never the editor.
- The n8n owner account uses two-factor authentication.
- n8n can run arbitrary code (Code node, Execute Command). Access to the editor is equivalent to SSH access to the Docker VM.
- Once models are cached, `ai_backend` can be set to `internal: true` to block all outbound traffic from the model servers. n8n then also loses internet access unless it is attached to another network.

## Data and Backup

| Data | Location | Backup |
|---|---|---|
| n8n workflows and credentials | `/mnt/main/appdata/ai-stack/n8n` + Postgres | ZFS snapshots of `appdata`, plus a Postgres dump (`pg_dump`) |
| Models | Docker volumes `whisper_models`, `vision_models` | Not backed up; re-downloaded automatically |
| Encryption key (`N8N_ENCRYPTION_KEY`) | `.env` | Stored in the password manager. Without it, saved n8n credentials cannot be recovered after a restore. |

## Versioning

Images are pinned to explicit tags and updated deliberately. Postgres is backed up before any n8n major upgrade.

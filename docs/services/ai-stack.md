# AI Stack: Speech Recognition, Vision, and n8n

A small, fully local AI stack for the Docker VM:

| Service | Software | API | Typical use |
|---|---|---|---|
| `whisper` | [speaches](https://github.com/speaches-ai/speaches) (faster-whisper) | OpenAI-compatible `POST /v1/audio/transcriptions` | Voice memos, meeting recordings, subtitles |
| `vision` | [llama.cpp](https://github.com/ggml-org/llama.cpp) server + multimodal GGUF | OpenAI-compatible `POST /v1/chat/completions` with images | Photo descriptions, OCR, document/receipt parsing |
| `n8n` | [n8n](https://n8n.io) + Postgres | Web UI, webhooks | Workflows that chain the two models with your other services |

Compose file: [configs/docker/ai-stack/docker-compose.yml](../../configs/docker/ai-stack/docker-compose.yml)

## Architecture

```text
                  LAN / Tailscale only (admin-whitelist)
                               │
                        ┌──────┴──────┐
                        │   Traefik   │
                        └──┬───┬───┬──┘
          whisper.example.com  │   n8n.example.com
                           │   │   │
                           │ vision.example.com
   ┌───────────────────────┼───┼───┼─────────────── ai_backend ──┐
   │  ┌─────────────┐  ┌───┴───┴┐  │  ┌─────────┐                │
   │  │ ai-whisper  │◄─┤  n8n   ├──┼─►│ai-vision│                │
   │  │ :8000       │  │ :5678  │  │  │ :8080   │                │
   │  └─────────────┘  └───┬────┘  │  └─────────┘                │
   └───────────────────────┼───────┼─────────────────────────────┘
                     ai_db │ (internal: true)
                     ┌─────┴─────┐
                     │ Postgres  │
                     └───────────┘
```

- Nothing is exposed to the internet by default. All three routes use the `admin-whitelist@file` middleware (LAN + Tailscale).
- Both model servers require an API key (`WHISPER_API_KEY`, `VISION_API_KEY`), even on the internal network.
- Postgres is on an `internal: true` network and has no internet access.

## Hardware Sizing

The defaults target a **CPU-only** server with about 16–32 GB RAM (e.g. a 4-core Xeon/i5/i7 with 32 GB).

| Model | RAM (approx.) | CPU speed (4 cores) | Notes |
|---|---|---|---|
| `Systran/faster-whisper-small` | ~1 GB | ~real-time | Recommended default |
| `Systran/faster-whisper-medium` | ~2 GB | ~0.5× real-time | Better with accents/noise |
| `deepdml/faster-whisper-large-v3-turbo-ct2` | ~3 GB | slow on CPU | Best accuracy; use with GPU |
| `ggml-org/Qwen2.5-VL-3B-Instruct-GGUF` | ~3 GB | seconds per image | Strong at OCR/documents |
| `ggml-org/gemma-3-4b-it-GGUF` | ~4–5 GB | seconds per image | Recommended default |
| `ggml-org/gemma-3-12b-it-GGUF` | ~10 GB | slow on CPU | Noticeably better answers |
| `ggml-org/Llama-4-Scout-17B-16E-Instruct-GGUF` | 60+ GB | impractical on CPU | Only for large servers or GPUs |

> [!TIP]
> Intel iGPUs (Quick Sync) do not help here — they accelerate video, not AI inference.
> If you add a GPU later, switch the images to `ghcr.io/speaches-ai/speaches:<version>-cuda`
> and `ghcr.io/ggml-org/llama.cpp:server-cuda-<build>` and add a `deploy.resources.reservations.devices` block.

## Deployment

```bash
# From your workstation
scp -r configs/docker/ai-stack dockeradmin@192.168.1.20:/opt/docker/

# On the Docker VM
cd /opt/docker/ai-stack
cp .env.example .env
sed -i "s/^WHISPER_API_KEY=.*/WHISPER_API_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^VISION_API_KEY=.*/VISION_API_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 32)/" .env
nano .env   # set DOMAIN, TZ, models

sudo mkdir -p /mnt/main/appdata/ai-stack/{n8n,postgres}
sudo chown 1000:1000 /mnt/main/appdata/ai-stack/n8n   # n8n runs as user "node" (UID 1000)

docker compose up -d
```

> [!IMPORTANT]
> Store `N8N_ENCRYPTION_KEY` in your password manager. Without it, all credentials saved in n8n are unrecoverable after a restore.

### Download the Whisper model (one time)

speaches downloads models on request, not at startup:

```bash
docker exec ai-whisper sh -c \
  'curl -fX POST -H "Authorization: Bearer $API_KEY" http://localhost:8000/v1/models/$WHISPER_MODEL'
```

### Vision model download

llama.cpp downloads the model and its vision projector (`mmproj`) automatically on first start. This takes a few minutes:

```bash
docker compose logs -f vision     # wait for "server is listening"
```

## Testing

```bash
source .env

# Speech-to-text
curl -s https://whisper.$DOMAIN/v1/audio/transcriptions \
  -H "Authorization: Bearer $WHISPER_API_KEY" \
  -F file=@memo.m4a -F model=$WHISPER_MODEL -F language=de

# Image description
IMG=$(base64 -w0 photo.jpg)
curl -s https://vision.$DOMAIN/v1/chat/completions \
  -H "Authorization: Bearer $VISION_API_KEY" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":[
        {"type":"text","text":"Describe this image in two sentences."},
        {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,'"$IMG"'"}}]}]}' \
  | jq -r '.choices[0].message.content'
```

## Example n8n Workflows

In n8n, use **HTTP Request** nodes pointing at the internal container names. `WHISPER_URL` and `VISION_URL` are provided as environment variables (`{{ $env.WHISPER_URL }}`). Store the API keys as n8n **Header Auth** credentials (`Authorization: Bearer <key>`), not in node parameters.

### 1. Voice memo → transcript

1. **Trigger:** Webhook (POST, binary field `file`) or Nextcloud / Local File Trigger on a folder like `voice-memos/`.
2. **HTTP Request:** `POST {{ $env.WHISPER_URL }}/v1/audio/transcriptions`, body *Form-Data*: `file` = binary input, `model` = `Systran/faster-whisper-small`.
3. **Output:** Write `{{ $json.text }}` as a Markdown note back to Nextcloud, or send it as a notification.

### 2. Photo → description / OCR

1. **Trigger:** Folder watch or Webhook with an image.
2. **Move Binary Data / Extract from File:** convert the image to Base64.
3. **HTTP Request:** `POST {{ $env.VISION_URL }}/v1/chat/completions` with a JSON body like the curl example above (prompt, e.g. "Extract date, merchant, and total from this receipt as JSON").
4. **Output:** Save the result to a spreadsheet, a database, or a Nextcloud file.

### 3. Chaining both

Voice memo → Whisper transcript → vision model (text-only request; multimodal models also answer plain text) → "Summarize this transcript into bullet points" → notification.

## Security Notes

- Keep all three routes on `admin-whitelist@file`. For external triggers, enable **only** the commented `n8n-webhook` router, which exposes `/webhook/*` and never the editor.
- Enable 2FA for the n8n owner account (Settings → Personal → Two-factor authentication).
- n8n can run arbitrary code (Code node, Execute Command). Treat access to the editor like SSH access to the Docker VM.
- After models are cached, you can set `ai_backend` to `internal: true` to block all outbound traffic from the model servers. Note that n8n then also loses internet access unless you add it to another network.

## Backup

| Data | Location | Backup |
|---|---|---|
| n8n workflows and credentials | `/mnt/main/appdata/ai-stack/n8n` + Postgres | ZFS snapshots of `appdata`; additionally `docker exec ai-n8n-db pg_dump -U n8n n8n` |
| Models | Docker volumes `whisper_models`, `vision_models` | Not needed; they are re-downloaded automatically |
| Encryption key | `.env` | Password manager |

## Updating

Images are pinned. Update deliberately:

1. Check the release notes for [speaches](https://github.com/speaches-ai/speaches/releases), [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), and [n8n](https://docs.n8n.io/release-notes/).
2. Bump the tag in `docker-compose.yml`.
3. `docker compose pull && docker compose up -d`.
4. Back up Postgres before n8n major upgrades.

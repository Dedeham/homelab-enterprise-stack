# AI Stack: Setup and Testing

Description of the stack, its architecture and sizing: [services/ai-stack.md](../../services/ai-stack.md)

## Deployment

From a workstation:

```bash
scp -r configs/docker/ai-stack dockeradmin@192.168.1.20:/opt/docker/
```

On the Docker VM:

```bash
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

Before continuing, store `N8N_ENCRYPTION_KEY` in the password manager.

## Model Download

### Whisper (one time)

speaches downloads models on request, not at startup:

```bash
docker exec ai-whisper sh -c \
  'curl -fX POST -H "Authorization: Bearer $API_KEY" http://localhost:8000/v1/models/$WHISPER_MODEL'
```

### Vision

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

## n8n Workflow Setup

In n8n, use **HTTP Request** nodes pointing at the internal container names. `WHISPER_URL` and `VISION_URL` are provided as environment variables (`{{ $env.WHISPER_URL }}`). Store the API keys as n8n **Header Auth** credentials (`Authorization: Bearer <key>`), not in node parameters.

### Voice memo to transcript

1. Trigger: Webhook (POST, binary field `file`) or Nextcloud / Local File Trigger on a folder like `voice-memos/`.
2. HTTP Request: `POST {{ $env.WHISPER_URL }}/v1/audio/transcriptions`, body Form-Data: `file` = binary input, `model` = `Systran/faster-whisper-small`.
3. Output: write `{{ $json.text }}` as a Markdown note back to Nextcloud, or send it as a notification.

### Photo to description / OCR

1. Trigger: folder watch or Webhook with an image.
2. Move Binary Data / Extract from File: convert the image to Base64.
3. HTTP Request: `POST {{ $env.VISION_URL }}/v1/chat/completions` with a JSON body like the curl example above (e.g. prompt "Extract date, merchant, and total from this receipt as JSON").
4. Output: save the result to a spreadsheet, a database, or a Nextcloud file.

### Chaining both

Voice memo, then Whisper transcript, then vision model (text-only request; multimodal models also answer plain text), then "Summarize this transcript into bullet points", then notification.

## Backup Procedure

```bash
docker exec ai-n8n-db pg_dump -U n8n n8n > n8n-$(date +%F).sql
```

Run this before any n8n major upgrade, in addition to the ZFS snapshots of `appdata`.

## Updating

1. Check the release notes for [speaches](https://github.com/speaches-ai/speaches/releases), [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), and [n8n](https://docs.n8n.io/release-notes/).
2. Bump the tag in `docker-compose.yml`.
3. Run `docker compose pull && docker compose up -d`.
4. Back up Postgres before n8n major upgrades (see above).

# AI Stack

Local speech recognition (Whisper), image understanding (llama.cpp vision model), and n8n workflow automation.

| Service | Container | Internal URL | LAN route |
|---|---|---|---|
| Whisper (speaches) | `ai-whisper` | `http://ai-whisper:8000` | `whisper.example.com` |
| Vision (llama.cpp) | `ai-vision` | `http://ai-vision:8080` | `vision.example.com` |
| n8n | `ai-n8n` | `http://ai-n8n:5678` | `n8n.example.com` |
| Postgres (n8n) | `ai-n8n-db` | internal only | none |

Quick start:

```bash
cp .env.example .env && nano .env    # set DOMAIN, generate the keys
docker compose up -d
docker exec ai-whisper sh -c \
  'curl -fX POST -H "Authorization: Bearer $API_KEY" http://localhost:8000/v1/models/$WHISPER_MODEL'
```

Full guide, hardware sizing, and example workflows: [docs/services/ai-stack.md](../../../docs/services/ai-stack.md)

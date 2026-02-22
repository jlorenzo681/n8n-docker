# n8n Docker Stack — Ollama + Redis + Mist API Chatbot

Self-hosted **n8n** workflow automation platform with local AI inference via **Ollama**, chat memory via **Redis**, and **Juniper Mist REST API** integration for a natural-language network management chatbot.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Docker Network                      │
│                                                      │
│  ┌───────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ PostgreSQL│  │  Redis   │  │     Ollama       │  │
│  │  :5432    │  │  :6379   │  │  :11434          │  │
│  │  (n8n DB) │  │ (memory) │  │ (LLM inference)  │  │
│  └─────┬─────┘  └────┬─────┘  └────────┬─────────┘  │
│        │              │                 │            │
│        └──────────────┼─────────────────┘            │
│                       │                              │
│                 ┌─────┴─────┐                        │
│                 │    n8n    │                         │
│                 │  :5678   │                         │
│                 └───────────┘                        │
└──────────────────────────────────────────────────────┘
                        │
                        ▼
              Juniper Mist REST API
           https://api.eu.mist.com/api/v1
```

## Prerequisites

- Podman ≥ 5.0 + podman-compose ≥ 1.5
- *(GPU profile only)* NVIDIA GPU + [NVIDIA Container Toolkit / CDI](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

## Quick Start

### 1. Configure Environment

```bash
cp .env .env.local   # optional: keep a local override
```

Edit `.env` and replace all `CHANGE_ME` values:

| Variable | Description |
|----------|-------------|
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `N8N_ENCRYPTION_KEY` | Run `openssl rand -hex 32` to generate |
| `MIST_API_TOKEN` | Your Juniper Mist API token |
| `MIST_API_BASE_URL` | Already set to `https://api.eu.mist.com/api/v1` |

### 2. Start the Stack

**CPU mode** (uses `liquid` model):
```bash
podman-compose --profile cpu up -d
```

**GPU mode** (uses `mistral` model, requires NVIDIA GPU):
```bash
podman-compose --profile gpu up -d
```

> On first start, Ollama will automatically pull the selected model. This may take a few minutes.

### 3. Access n8n

Open **http://localhost:5678** in your browser and complete the initial setup wizard.

## Configuring n8n Credentials

After logging into n8n, create the following credentials:

### Ollama Credentials
- Go to **Settings → Credentials → Add Credential → Ollama API**
- **Base URL**: `http://n8n-ollama:11434`
- This single credential works for all four Ollama node types: *Embeddings Ollama*, *Ollama*, *Ollama Chat Model*, and *Ollama Model*

### Redis Credentials (for Chat Memory)
- Go to **Settings → Credentials → Add Credential → Redis**
- **Host**: `redis`
- **Port**: `6379`
- **Password**: *(leave empty)*

### Mist API Credentials
- Go to **Settings → Credentials → Add Credential → Header Auth**
- **Name**: `Mist API`
- **Header Name**: `Authorization`
- **Header Value**: `Token YOUR_MIST_API_TOKEN`

## Building the Chatbot Workflow

Create a new workflow in n8n with the following node chain:

```
Chat Trigger → AI Agent → Mist HTTP Request → Code (export .txt)
```

### Recommended Node Setup

1. **Chat Trigger** — receives natural language input
2. **AI Agent** node with:
   - **Chat Model**: Ollama Chat Model (model: `liquid` or `mistral`)
   - **Memory**: Redis Chat Memory (for conversation context)
   - **Tools**: HTTP Request tool configured with Mist API credentials
3. **HTTP Request** node (as a tool for the AI Agent):
   - **Base URL**: `https://api.eu.mist.com/api/v1`
   - **Authentication**: Header Auth → `Mist API`
4. **Code** node — converts the API response to `.txt`:
   ```javascript
   const response = JSON.stringify($input.all()[0].json, null, 2);
   const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
   const fileName = `mist_response_${timestamp}.txt`;

   await $('Write Binary File').execute([{
     json: {},
     binary: {
       data: await this.helpers.prepareBinaryData(
         Buffer.from(response, 'utf-8'),
         fileName,
         'text/plain'
       )
     }
   }]);

   return $input.all();
   ```
5. **Write Binary File** node — saves to `/files/` (mapped to `n8n_files` volume)

## Useful Commands

```bash
# View logs
podman-compose logs -f n8n

# Check Ollama models
curl http://localhost:11434/api/tags

# Test Redis
podman-compose exec redis redis-cli ping

# Stop everything
podman-compose --profile cpu down    # or --profile gpu

# Reset all data (⚠️ destructive)
podman-compose --profile cpu down -v
```

## File Exports

Mist API responses exported as `.txt` are saved to the `n8n_files` Docker volume. To access them from the host:

```bash
docker volume inspect n8n-docker_n8n_files  # find the mountpoint
```

Or bind-mount a host directory by changing the volume in `docker-compose.yml`:
```yaml
volumes:
  - ./exports:/files
```

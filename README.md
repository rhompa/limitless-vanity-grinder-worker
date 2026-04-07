# LIMITLESS Vanity Grinder Worker

Persistent GPU worker for grinding Solana vanity addresses. Runs on a vast.ai RTX 4090 instance with SolVanityCL + FastAPI HTTP server.

## Architecture

- **Docker image**: Based on `ghcr.io/wincerchan/solvanitycl:latest` (SolVanityCL + CUDA/OpenCL)
- **HTTP server**: FastAPI on port 8080 with bearer token auth
- **GPU**: Single RTX 4090, handles 3-6 character patterns synchronously
- **Encryption**: AES-256-GCM transport encryption for keypairs

## API

### `GET /health`
Returns worker status, GPU temperature, uptime, and queue depth.

### `POST /grind`
Grinds a vanity address. Requires `Authorization: Bearer <token>` header.

```json
{
  "prefix": "DOGE",
  "position": "start",
  "max_seconds": 30,
  "request_id": "uuid-here"
}
```

Returns:
```json
{
  "pubkey": "DOGExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "encrypted_keypair_b64": "...",
  "iv_b64": "...",
  "tag_b64": "...",
  "grind_seconds": 0.136,
  "request_id": "uuid-here"
}
```

## Setup

1. Copy `.env.example` to `.env` and fill in values
2. Build Docker image: `docker build -t limitless-vanity-grinder .`
3. Deploy to vast.ai: `./deploy.sh`
4. Test: `./deploy.sh test`

## Commands

```bash
./deploy.sh              # Deploy new instance
./deploy.sh destroy      # Destroy current instance
./deploy.sh status       # Check instance status
./deploy.sh test         # Test health + grind endpoints
```

## Environment Variables

| Variable | Description |
|---|---|
| `VASTAI_API_KEY` | vast.ai API key |
| `GRINDER_AUTH_TOKEN` | Bearer token for /grind endpoint |
| `GRINDER_ENCRYPTION_KEY` | 32-byte hex key for AES-256-GCM keypair encryption |
| `PERSISTENT_INSTANCE_ID` | (auto-set by deploy.sh) vast.ai instance ID |
| `PERSISTENT_GRINDER_URL` | (auto-set by deploy.sh) Worker HTTP URL |

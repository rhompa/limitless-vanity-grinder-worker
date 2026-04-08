#!/bin/bash
#
# deploy.sh — Deploy persistent vanity grinder worker to vast.ai
#
# Usage:
#   ./deploy.sh              Deploy new instance
#   ./deploy.sh destroy      Destroy current instance
#   ./deploy.sh status       Check instance status
#   ./deploy.sh test         Test health + grind endpoints
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DOCKER_IMAGE="ghcr.io/wincerchan/solvanitycl:latest"
WORKER_REPO="https://github.com/rhompa/limitless-vanity-grinder-worker.git"
MIN_CREDIT=3.00
GPU_FILTER='gpu_name=RTX_4090 num_gpus=1 dph<=0.50 inet_down>=500 verified=true reliability>0.95'
DISK_GB=15
POLL_INTERVAL=15
MAX_WAIT=300  # 5 minutes max wait for instance boot

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { log "ERROR: $*"; exit 1; }

check_deps() {
  command -v vastai >/dev/null 2>&1 || die "vastai CLI not found. Install: pip install vastai"
  command -v jq    >/dev/null 2>&1 || die "jq not found. Install: brew install jq"
  command -v curl  >/dev/null 2>&1 || die "curl not found"
  [ -n "${VASTAI_API_KEY:-}" ]            || die "VASTAI_API_KEY not set in .env"
  [ -n "${GRINDER_AUTH_TOKEN:-}" ]        || die "GRINDER_AUTH_TOKEN not set in .env"
  [ -n "${GRINDER_ENCRYPTION_KEY:-}" ]    || die "GRINDER_ENCRYPTION_KEY not set in .env"
}

check_credit() {
  local credit
  credit=$(vastai show user --raw 2>/dev/null | jq -r '.credit' 2>/dev/null || echo "0")
  log "vast.ai credit: \$$credit"
  if (( $(echo "$credit < $MIN_CREDIT" | bc -l) )); then
    die "Credit \$$credit is below minimum \$$MIN_CREDIT. Top up before deploying."
  fi
}

get_instance_id() {
  grep -E '^PERSISTENT_INSTANCE_ID=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo ""
}

save_instance_info() {
  local id="$1" url="$2"
  # Remove old entries
  sed -i.bak '/^PERSISTENT_INSTANCE_ID=/d; /^PERSISTENT_GRINDER_URL=/d' "$SCRIPT_DIR/.env" 2>/dev/null || true
  rm -f "$SCRIPT_DIR/.env.bak"
  # Append new
  echo "PERSISTENT_INSTANCE_ID=$id" >> "$SCRIPT_DIR/.env"
  echo "PERSISTENT_GRINDER_URL=$url" >> "$SCRIPT_DIR/.env"
  log "Saved instance $id at $url to .env"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_deploy() {
  check_deps
  check_credit

  # Check for existing instance
  local existing_id
  existing_id=$(get_instance_id)
  if [ -n "$existing_id" ]; then
    log "Existing instance $existing_id found. Checking status..."
    local status
    status=$(vastai show instance "$existing_id" --raw 2>/dev/null | jq -r '.actual_status' 2>/dev/null || echo "unknown")
    if [ "$status" = "running" ]; then
      die "Instance $existing_id is already running. Use './deploy.sh destroy' first, or './deploy.sh test' to verify."
    fi
    log "Instance $existing_id is $status. Proceeding with new deployment."
  fi

  # Search for cheapest RTX 4090 offer
  log "Searching for RTX 4090 offers..."
  local offers
  offers=$(vastai search offers "$GPU_FILTER" -o 'dph' --raw 2>/dev/null)
  local offer_count
  offer_count=$(echo "$offers" | jq 'length' 2>/dev/null || echo "0")

  if [ "$offer_count" -eq 0 ] || [ "$offer_count" = "null" ]; then
    die "No RTX 4090 offers found matching filters. Try relaxing price or reliability constraints."
  fi

  local offer_id dph
  offer_id=$(echo "$offers" | jq -r '.[0].id')
  dph=$(echo "$offers" | jq -r '.[0].dph_total')
  log "Selected offer $offer_id at \$$dph/hr (cheapest of $offer_count offers)"

  # Build onstart command — installs deps, clones repo, starts server
  local onstart_cmd="apt-get update && apt-get install -y python3-pip git && pip3 install --break-system-packages --ignore-installed fastapi uvicorn[standard] cryptography pydantic && git clone $WORKER_REPO /worker && cd /worker && chmod +x entrypoint.sh && GRINDER_AUTH_TOKEN=$GRINDER_AUTH_TOKEN GRINDER_ENCRYPTION_KEY=$GRINDER_ENCRYPTION_KEY ./entrypoint.sh"

  # Create instance
  log "Creating instance..."
  local create_result
  create_result=$(vastai create instance "$offer_id" \
    --image "$DOCKER_IMAGE" \
    --disk "$DISK_GB" \
    --ssh \
    --direct \
    --env '-p 8080:8080' \
    --onstart-cmd "$onstart_cmd" \
    --raw 2>/dev/null)

  local instance_id
  instance_id=$(echo "$create_result" | jq -r '.new_contract' 2>/dev/null || echo "")
  if [ -z "$instance_id" ] || [ "$instance_id" = "null" ]; then
    # Try alternate response format
    instance_id=$(echo "$create_result" | grep -oP '"new_contract"\s*:\s*\K\d+' 2>/dev/null || echo "")
  fi
  if [ -z "$instance_id" ]; then
    die "Failed to parse instance ID from response: $create_result"
  fi

  log "Instance $instance_id created. Waiting for boot..."

  # Poll for instance to be running
  local waited=0
  while [ "$waited" -lt "$MAX_WAIT" ]; do
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))

    local instance_info
    instance_info=$(vastai show instance "$instance_id" --raw 2>/dev/null)
    local actual_status
    actual_status=$(echo "$instance_info" | jq -r '.actual_status' 2>/dev/null || echo "unknown")

    log "  Status: $actual_status ($waited/${MAX_WAIT}s)"

    if [ "$actual_status" = "running" ]; then
      # Extract public IP (always available once running)
      local public_ip
      public_ip=$(echo "$instance_info" | jq -r '.public_ipaddr // .ssh_host // empty' 2>/dev/null)
      if [ -z "$public_ip" ]; then
        log "  Warning: Could not determine public IP. Check 'vastai show instance $instance_id'"
        log "  Instance info: $instance_info"
        continue
      fi

      # Retry loop: wait up to 60s for port info to populate
      local mapped_port="" port_source="" port_waited=0
      while [ "$port_waited" -lt 60 ]; do
        # Re-fetch instance info each iteration
        local fresh_info
        fresh_info=$(vastai show instance "$instance_id" --raw 2>/dev/null)

        # Path 1: ports map (e.g. {"8080/tcp": [{"HostPort": "12345"}]})
        local ports_json
        ports_json=$(echo "$fresh_info" | jq -r '.ports // empty' 2>/dev/null)
        if [ -n "$ports_json" ] && [ "$ports_json" != "null" ]; then
          mapped_port=$(echo "$ports_json" | jq -r '.["8080/tcp"]?[0]?.HostPort // empty' 2>/dev/null || echo "")
          if [ -n "$mapped_port" ] && [ "$mapped_port" != "null" ]; then
            port_source="ports map"
            break
          fi
        fi

        # Path 2: direct_port_start (direct mode exposes container ports as-is)
        local dps
        dps=$(echo "$fresh_info" | jq -r '.direct_port_start // empty' 2>/dev/null || echo "")
        if [ -n "$dps" ] && [ "$dps" != "null" ]; then
          mapped_port="8080"
          port_source="direct mode (direct_port_start=$dps)"
          break
        fi

        port_waited=$((port_waited + 5))
        log "  Waiting for port info... (${port_waited}/60s)"
        sleep 5
      done

      if [ -z "$mapped_port" ]; then
        log "  Warning: Port info did not populate within 60s. Falling back to 8080."
        mapped_port="8080"
        port_source="fallback (timeout)"
      fi

      local worker_url="http://${public_ip}:${mapped_port}"
      log "Instance running at $worker_url (${port_source})"

      # Wait a few more seconds for uvicorn to start
      log "Waiting 10s for FastAPI to initialize..."
      sleep 10

      # Test health endpoint
      log "Testing health endpoint..."
      local health_response
      health_response=$(curl -sf --connect-timeout 10 --max-time 15 "$worker_url/health" 2>/dev/null || echo "FAIL")

      if [ "$health_response" = "FAIL" ]; then
        log "  Health check failed. Worker may still be starting up."
        log "  Try again in 30s with: ./deploy.sh test"
        save_instance_info "$instance_id" "$worker_url"
        exit 0
      fi

      log "  Health: $health_response"
      save_instance_info "$instance_id" "$worker_url"
      log ""
      log "=== DEPLOYMENT SUCCESSFUL ==="
      log "Instance ID: $instance_id"
      log "Worker URL:  $worker_url"
      log "Cost:        \$$dph/hr"
      log ""
      log "Test with: ./deploy.sh test"
      return 0
    fi

    if [ "$actual_status" = "exited" ] || [ "$actual_status" = "error" ]; then
      log "Instance failed with status: $actual_status"
      local logs
      logs=$(vastai logs "$instance_id" 2>/dev/null | tail -20)
      log "Last logs: $logs"
      vastai destroy instance "$instance_id" 2>/dev/null || true
      die "Instance failed to start. Check logs above."
    fi
  done

  die "Instance did not reach 'running' status within ${MAX_WAIT}s. Check: vastai show instance $instance_id"
}

cmd_destroy() {
  local instance_id
  instance_id=$(get_instance_id)
  if [ -z "$instance_id" ]; then
    die "No instance ID found in .env"
  fi
  log "Destroying instance $instance_id..."
  vastai destroy instance "$instance_id" 2>/dev/null || log "Warning: destroy command failed (instance may already be gone)"
  sed -i.bak '/^PERSISTENT_INSTANCE_ID=/d; /^PERSISTENT_GRINDER_URL=/d' "$SCRIPT_DIR/.env" 2>/dev/null || true
  rm -f "$SCRIPT_DIR/.env.bak"
  log "Instance destroyed and .env cleaned."
}

cmd_status() {
  local instance_id
  instance_id=$(get_instance_id)
  if [ -z "$instance_id" ]; then
    die "No instance ID found in .env"
  fi
  vastai show instance "$instance_id" --raw 2>/dev/null | jq '{id, actual_status, gpu_name: .gpu_name, dph_total, public_ipaddr, cur_state, status_msg}'
}

cmd_test() {
  check_deps
  source "$SCRIPT_DIR/.env"
  local url="${PERSISTENT_GRINDER_URL:-}"
  if [ -z "$url" ]; then
    die "PERSISTENT_GRINDER_URL not set in .env. Deploy first."
  fi

  log "Testing health endpoint..."
  local health
  health=$(curl -sf --connect-timeout 10 --max-time 15 "$url/health" 2>/dev/null || echo "FAIL")
  if [ "$health" = "FAIL" ]; then
    die "Health endpoint not responding at $url/health"
  fi
  log "  Health: $health"

  log "Testing grind endpoint (3-char suffix 'abc')..."
  local grind_response
  grind_response=$(curl -sf --connect-timeout 10 --max-time 30 \
    -X POST "$url/grind" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $GRINDER_AUTH_TOKEN" \
    -d '{"suffix":"abc","position":"end","max_seconds":30,"request_id":"test-001"}' \
    2>/dev/null || echo "FAIL")

  if [ "$grind_response" = "FAIL" ]; then
    die "Grind endpoint failed at $url/grind"
  fi

  local pubkey grind_seconds
  pubkey=$(echo "$grind_response" | jq -r '.pubkey' 2>/dev/null)
  grind_seconds=$(echo "$grind_response" | jq -r '.grind_seconds' 2>/dev/null)
  log "  Pubkey: $pubkey"
  log "  Grind time: ${grind_seconds}s"

  # Verify suffix
  if [[ "$pubkey" == *abc ]]; then
    log "  Suffix verification: PASS"
  else
    log "  Suffix verification: FAIL (pubkey does not end with 'abc')"
  fi

  log ""
  log "=== ALL TESTS PASSED ==="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-deploy}" in
  deploy)  cmd_deploy  ;;
  destroy) cmd_destroy ;;
  status)  cmd_status  ;;
  test)    cmd_test    ;;
  *)       echo "Usage: $0 {deploy|destroy|status|test}"; exit 1 ;;
esac

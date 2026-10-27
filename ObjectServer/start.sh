#!/usr/bin/env bash
# Starts the object server on the Colab VM and makes it reachable through this
# Mac. If FALKEY is present in .env.local it also starts a second, Mac-hosted
# fal.ai gateway. The app prefers Colab and automatically retries fal.ai when
# Colab is unavailable or a request fails.
#
#   bash ObjectServer/start.sh
#
# Keep it running while you use Object or SAM Furniture mode. Ctrl-C stops the
# servers and frees the GPU. FALKEY never leaves this Mac.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVICE=${DEVICE:-893484B9-033A-5427-9561-A3DF76E94ACC}
APP=${APP:-dev.bugatti.RoomTwinLol}
SESSION=${SESSION:-roomtwin}
PORT=${PORT:-8765}
FAL_PORT=${FAL_PORT:-8766}
USE_COLAB=${USE_COLAB:-1}
SSH=(ssh -o "ProxyCommand=$HOME/.local/bin/colab --auth=adc ssh --proxy-mode -s $SESSION"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
HOST=root@$SESSION
TOKEN=${OBJECT_SERVER_TOKEN:-$(openssl rand -hex 16)}
LOCAL_NAME=$(scutil --get LocalHostName 2>/dev/null || true)
ADDRESS=${ROOMTWIN_SERVER_HOST:-${LOCAL_NAME:+$LOCAL_NAME.local}}
if [ -z "$ADDRESS" ]; then
    ADDRESS=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)
fi
[ -n "$ADDRESS" ] || { echo "this Mac has no local-network address"; exit 1; }
URL="http://$ADDRESS:$PORT"
FAL_LOG=${FAL_LOG:-/tmp/roomtwin-fal-server.log}

# Read FALKEY as data rather than sourcing arbitrary shell code.
FAL_VALUE=${FALKEY:-}
if [ -z "$FAL_VALUE" ] && [ -f "$ROOT/.env.local" ]; then
    FAL_VALUE=$(awk -F= '$1 == "FALKEY" { sub(/^[^=]*=/, ""); print; exit }' "$ROOT/.env.local")
    FAL_VALUE=${FAL_VALUE#\"}; FAL_VALUE=${FAL_VALUE%\"}
    FAL_VALUE=${FAL_VALUE#\'}; FAL_VALUE=${FAL_VALUE%\'}
fi

REMOTE_STARTED=0
REMOTE_LAUNCHED=0
FAL_READY=0
FAL_PID=""
FAL_CAFFEINATE_PID=""
cleanup() {
    echo
    echo "== stopping"
    if [ "$REMOTE_LAUNCHED" = 1 ]; then
        "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh stop" >/dev/null 2>&1 || true
    fi
    if [ -n "$FAL_PID" ]; then
        kill "$FAL_PID" >/dev/null 2>&1 || true
        wait "$FAL_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "$FAL_CAFFEINATE_PID" ]; then
        kill "$FAL_CAFFEINATE_PID" >/dev/null 2>&1 || true
        wait "$FAL_CAFFEINATE_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

if [ -n "$FAL_VALUE" ]; then
    # Other local development servers sometimes use 8766. Pick the next free
    # port so a stale process cannot make our health check hit the wrong app.
    FAL_PORT_START=$FAL_PORT
    while lsof -nP -iTCP:"$FAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
        FAL_PORT=$((FAL_PORT + 1))
        if [ "$FAL_PORT" -gt $((FAL_PORT_START + 20)) ]; then
            echo "   no free local port found for fal.ai fallback"
            break
        fi
    done
    FAL_URL="http://$ADDRESS:$FAL_PORT"
    if [ "$FAL_PORT" != "$FAL_PORT_START" ]; then
        echo "   port $FAL_PORT_START is occupied; using $FAL_PORT"
    fi
    echo "== starting fal.ai fallback on this Mac"
    FALKEY="$FAL_VALUE" OBJECT_SERVER_TOKEN="$TOKEN" \
        python3 "$ROOT/ObjectServer/fal_server.py" --port "$FAL_PORT" >"$FAL_LOG" 2>&1 &
    FAL_PID=$!
    for _ in $(seq 40); do
        FAL_HEALTH=$(curl -sf -H "X-Token: $TOKEN" "http://127.0.0.1:$FAL_PORT/health" 2>/dev/null || true)
        if printf '%s' "$FAL_HEALTH" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"ready"'; then
            FAL_READY=1
            break
        fi
        kill -0 "$FAL_PID" >/dev/null 2>&1 || break
        sleep 0.25
    done
    if [ "$FAL_READY" = 1 ]; then
        echo "   fal.ai fallback is ready"
    else
        echo "   fal.ai fallback could not start; see $FAL_LOG"
        FAL_REASON=$(printf '%s' "$FAL_HEALTH" \
            | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$FAL_REASON" ] && echo "   $FAL_REASON"
        tail -5 "$FAL_LOG" 2>/dev/null || true
        kill "$FAL_PID" >/dev/null 2>&1 || true
        FAL_PID=""
    fi
else
    FAL_URL=""
    echo "== fal.ai fallback disabled (add FALKEY=... to .env.local)"
fi

if [ "$USE_COLAB" != 1 ]; then
    echo "== skipping Colab (USE_COLAB=$USE_COLAB)"
elif COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf - -C "$ROOT" --exclude __pycache__ ObjectServer Furniture \
    | "${SSH[@]}" "$HOST" "cd /content && tar xzf -"; then
    echo "== uploaded ObjectServer/ and Furniture/"
    echo "== starting the Colab server and generator"
    if "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh start $TOKEN" >/dev/null 2>&1; then
        REMOTE_LAUNCHED=1
        for _ in $(seq 30); do
            "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh health $TOKEN" >/dev/null 2>&1 && break
            sleep 2
        done
        if "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh health $TOKEN" >/dev/null 2>&1; then
            REMOTE_STARTED=1
            echo "   Colab SAM 3 is ready; SAM 3D Objects may take another minute to load"
        else
            echo "   Colab did not become ready; fal.ai will be used"
            "${SSH[@]}" "$HOST" "tail -20 /content/objects/server.log" 2>/dev/null || true
        fi
    else
        echo "   Colab is not prepared or could not start; fal.ai will be used"
    fi
else
    echo "   Could not reach Colab; fal.ai will be used"
fi

if [ "$REMOTE_STARTED" != 1 ] && [ "$FAL_READY" != 1 ]; then
    echo "No SAM provider is available. Prepare Colab or add FALKEY=... to .env.local."
    exit 1
fi

CONFIG=$(mktemp -d)/object-server.json
if [ "$REMOTE_STARTED" = 1 ] && [ "$FAL_READY" = 1 ]; then
    printf '{"url": "%s", "token": "%s", "fallbackURL": "%s", "driveURL": "%s", "provider": "local"}\n' "$URL" "$TOKEN" "$FAL_URL" "$FAL_URL" > "$CONFIG"
elif [ "$REMOTE_STARTED" = 1 ]; then
    printf '{"url": "%s", "token": "%s", "provider": "local"}\n' "$URL" "$TOKEN" > "$CONFIG"
else
    printf '{"url": "%s", "token": "%s", "driveURL": "%s", "provider": "fal.ai"}\n' "$FAL_URL" "$TOKEN" "$FAL_URL" > "$CONFIG"
fi
if xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "$CONFIG" --destination Library/object-server.json > /dev/null 2>&1; then
    echo "== sent the address and token to the phone"
else
    echo "== couldn't reach the phone; enter these in the app:"
    echo "   address $URL"
    echo "   token   $TOKEN"
fi
rm -f "$CONFIG"

if [ "$REMOTE_STARTED" = 1 ]; then
    echo "== serving Colab on $URL (Ctrl-C to stop); logs: /content/objects/{server,generator}.log"
    [ "$FAL_READY" = 1 ] && echo "   automatic fal.ai fallback: $FAL_URL"
    # caffeinate keeps the Mac awake so the tunnel stays up.
    caffeinate -i "${SSH[@]}" -N -L "0.0.0.0:$PORT:127.0.0.1:8000" "$HOST"
else
    echo "== serving fal.ai fallback on $FAL_URL (Ctrl-C to stop); log: $FAL_LOG"
    caffeinate -i -w "$FAL_PID" &
    FAL_CAFFEINATE_PID=$!
    wait "$FAL_PID"
fi

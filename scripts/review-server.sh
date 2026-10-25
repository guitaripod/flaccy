#!/usr/bin/env bash
# A throwaway flaccy-server for App Review: a generated demo library (no real music), a demo login,
# and a public HTTPS address through Tailscale Funnel. Run it only while a version is in review.
#   FLACCY_REVIEW_PASSWORD=<demo password> scripts/review-server.sh start
#   scripts/review-server.sh stop
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/flaccy-review-server"
PORT=4546

case "${1:-}" in
    start)
        : "${FLACCY_REVIEW_PASSWORD:?set FLACCY_REVIEW_PASSWORD to the demo password for the review notes}"
        SERVER=$(command -v flaccy-server) || { echo "install flaccy-server first (yay -S flaccy-server-bin)" >&2; exit 1; }
        mkdir -p "$STATE/data"
        [[ -d "$STATE/music" ]] || bash "$HERE/linux/demo-seed.sh" "$STATE/music"
        cat > "$STATE/config.toml" <<EOF
music_folder = "$STATE/music"
address = "127.0.0.1"
port = $PORT
data_dir = "$STATE/data"
behind_proxy = true
EOF
        printf '%s\n' "$FLACCY_REVIEW_PASSWORD" | "$SERVER" --config "$STATE/config.toml" password set --stdin
        "$SERVER" --config "$STATE/config.toml" scan
        systemd-run --user --unit=flaccy-review-server --collect --quiet \
            "$SERVER" --config "$STATE/config.toml" serve
        tailscale funnel --bg "$PORT"
        tailscale funnel status
        echo "Review notes: the address above, user name flaccy, the demo password you set."
        ;;
    stop)
        tailscale funnel --https=443 off || true
        systemctl --user stop flaccy-review-server || true
        echo "Review server stopped and unpublished."
        ;;
    *)
        echo "usage: $0 start|stop" >&2
        exit 2
        ;;
esac

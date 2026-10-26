#!/bin/sh
set -eu

CONFIG=${FLACCY_SERVER_CONFIG:-/data/config.toml}
GENERATED_MARK='# Written by the container at every start from FLACCY_* variables. Mount your own file here to replace it.'

fail() {
    echo "flaccy-server: $1" >&2
    exit 1
}

reject_unsafe() {
    case $2 in
        *\"* | *\\* | *'
'*) fail "$1 must not contain quotes, backslashes or line breaks." ;;
    esac
}

check_port() {
    case ${FLACCY_PORT:-4545} in
        '' | *[!0-9]*) fail "FLACCY_PORT must be a number, for example 4545." ;;
    esac
}

check_behind_proxy() {
    case ${FLACCY_BEHIND_PROXY:-false} in
        true | false) ;;
        *) fail "FLACCY_BEHIND_PROXY must be true or false." ;;
    esac
}

is_own_config() {
    [ ! -e "$CONFIG" ] || [ "$(head -n 1 "$CONFIG")" = "$GENERATED_MARK" ]
}

write_config() {
    music=${FLACCY_MUSIC_FOLDER:-/music}
    data=${FLACCY_DATA_DIR:-/data}
    address=${FLACCY_ADDRESS:-0.0.0.0}
    reject_unsafe FLACCY_MUSIC_FOLDER "$music"
    reject_unsafe FLACCY_DATA_DIR "$data"
    reject_unsafe FLACCY_ADDRESS "$address"
    check_port
    check_behind_proxy
    {
        echo "$GENERATED_MARK"
        echo "music_folder = \"$music\""
        echo "address = \"$address\""
        echo "port = ${FLACCY_PORT:-4545}"
        echo "data_dir = \"$data\""
        echo "behind_proxy = ${FLACCY_BEHIND_PROXY:-false}"
    } > "$CONFIG" || fail "Could not write $CONFIG. Make /data writable by uid 1000 (chown 1000:1000 on a bind mount) or mount your own config file there."
}

if is_own_config; then
    write_config
fi

exec flaccy-server "$@"

#!/bin/zsh
exec "$(cd "$(dirname "$0")" && pwd)/make_native_app.sh" "$@"

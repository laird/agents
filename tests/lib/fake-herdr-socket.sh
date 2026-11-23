#!/bin/bash
# tests/lib/fake-herdr-socket.sh: a herdr socket that accepts connections (#372).
# reboot-recover.sh asks herdr nothing until its socket answers, so a test with
# a stub herdr needs one, and must never reach the operator's real herdr
# socket under ~/.config. Source it after creating $T; it exports
# HERDR_SOCKET_PATH and defines:
#   herdr_socket_start   listen on $HERDR_SOCKET_PATH (accepts and closes)
#   herdr_socket_stop    stop listening and remove the socket file
# The caller's EXIT trap must call herdr_socket_stop.
export HERDR_SOCKET_PATH="$T/herdr.sock"
HERDR_SOCKET_PID=""
herdr_socket_start() {
  herdr_socket_stop
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(16)
while True:
    c, _ = s.accept()
    c.close()' "$HERDR_SOCKET_PATH" &
  HERDR_SOCKET_PID=$!
  local i=0
  while [ ! -S "$HERDR_SOCKET_PATH" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
herdr_socket_stop() {
  [ -n "$HERDR_SOCKET_PID" ] && { kill "$HERDR_SOCKET_PID" 2>/dev/null; wait "$HERDR_SOCKET_PID" 2>/dev/null; }
  HERDR_SOCKET_PID=""
  rm -f "$HERDR_SOCKET_PATH"
}

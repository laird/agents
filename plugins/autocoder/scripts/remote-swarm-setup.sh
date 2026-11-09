#!/bin/bash
# remote-swarm-setup.sh — let another machine join this swarm over Tailscale.
#
# The swarm (herdr or tmux) runs on a HOST. A CLIENT (a laptop, a uConsole,
# another desktop) attaches to it with `join-parallel --remote <name>`, or the
# short `swarm` command this script installs. SSH is the transport; Tailscale
# provides the network, so nothing is exposed beyond your tailnet.
#
# 1. On the client:   remote-swarm-setup.sh client <host> [--name swarm]
#      Creates a dedicated SSH key, an SSH alias (default "swarm") that points
#      at <host>'s Tailscale address, trusts <host>'s SSH host key, and installs
#      a `swarm` command in ~/.local/bin. Prints the line to run on the host.
#      If the host already runs Tailscale SSH, the client can log in right away
#      and step 2 is skipped (the script tests this and says so).
# 2. On the host:     remote-swarm-setup.sh host --authorize '<public key>'
#      Authorizes the client's key, and (with sudo) turns on sshd with password
#      and root logins disabled. If ufw is active, port 22 is opened on the
#      tailscale0 interface only. With --tailscale-ssh it turns on Tailscale
#      SSH instead (no sshd, no keys; your tailnet policy decides access).
# 3. On the client:   swarm        (or: join-parallel --remote swarm)
#
# Run either half again at any time; every step is idempotent.
# See docs/remote-swarm.md.

set -euo pipefail

say() { printf '%s\n' "$*"; }
die() { say "❌ $*" >&2; exit 1; }

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Tailscale SSH: tailscaled answers port 22 on the tailnet address and checks
# the peer's tailnet identity, so no sshd or authorized key is needed.
tailscale_ssh_on() {
  tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": true'
}

need_tailscale() {
  command -v tailscale >/dev/null 2>&1 || die "tailscale is not installed (https://tailscale.com/download)"
  tailscale status >/dev/null 2>&1 || die "tailscale is not logged in here: run 'sudo tailscale up'"
}

# ---------------------------------------------------------------------------
# host: run on the machine where the swarm runs
# ---------------------------------------------------------------------------
host_setup() {
  local keys=() ts_ssh=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --authorize) keys+=("$2"); shift 2 ;;
      --tailscale-ssh) ts_ssh=true; shift ;;
      -h|--help) usage ;;
      *) die "unknown option: $1" ;;
    esac
  done
  need_tailscale

  if $ts_ssh; then
    tailscale_ssh_on || sudo tailscale set --ssh
    say "✅ Tailscale SSH is on: tailnet devices your policy allows can log in (no sshd, no keys)"
    say "   Clients join with: swarm"
    return
  fi
  if tailscale_ssh_on && ! systemctl is-active -q sshd 2>/dev/null; then
    say "✅ Tailscale SSH is already on here, so clients can log in without sshd."
    say "   Nothing to do. See docs/remote-swarm.md to use sshd and keys instead."
    return
  fi

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  local k
  for k in "${keys[@]}"; do
    [[ $k =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "not an SSH public key: $k"
    if grep -qF -- "$(awk '{print $2}' <<<"$k")" "$HOME/.ssh/authorized_keys"; then
      say "✅ key already authorized: $(awk '{print $3}' <<<"$k")"
    else
      printf '%s\n' "$k" >> "$HOME/.ssh/authorized_keys"
      say "✅ authorized key: $(awk '{print $3}' <<<"$k")"
    fi
  done

  say "🔐 Enabling sshd (needs sudo)..."
  sudo install -d -m755 /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/50-remote-swarm.conf >/dev/null <<'EOF'
# remote-swarm-setup.sh: keys only, no root
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  sudo sshd -t || die "sshd config check failed; not starting sshd"
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh over tailscale (remote swarm)' >/dev/null
    say "✅ ufw: port 22 open on tailscale0 only"
  else
    say "⚠️  no active ufw firewall: sshd also listens on your other networks (keys only)"
  fi
  sudo systemctl enable --now sshd >/dev/null 2>&1 || sudo systemctl enable --now ssh
  local ip fp
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')
  say ""
  say "✅ Host ready: $(hostname) at $ip"
  say "   SSH host key: $fp"
  say "   Clients join with: swarm   (or join-parallel --remote <alias>)"
}

# ---------------------------------------------------------------------------
# client: run on the machine you want to manage the swarm from
# ---------------------------------------------------------------------------
client_setup() {
  local host="" name="swarm"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name) name="$2"; shift 2 ;;
      -h|--help) usage ;;
      -*) die "unknown option: $1" ;;
      *) host="$1"; shift ;;
    esac
  done
  [[ -n $host ]] || usage 2
  [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "bad alias name: $name"
  need_tailscale

  local ip user="${SWARM_USER:-$USER}"
  [[ $host == *@* ]] && { user=${host%@*}; host=${host#*@}; }
  ip=$(tailscale ip -4 "$host" 2>/dev/null | head -1) || true
  [[ -n $ip ]] || die "'$host' is not a machine on your tailnet (see: tailscale status)"

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  local key="$HOME/.ssh/id_ed25519_$name"
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C "$(hostname)-$name" -f "$key"

  touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  if grep -qE "^Host $name( |$)" "$HOME/.ssh/config"; then
    say "ℹ️  ~/.ssh/config already has 'Host $name'; leaving it as is"
  else
    printf '\n# remote-swarm-setup.sh\nHost %s\n  HostName %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  ServerAliveInterval 30\n  ServerAliveCountMax 4\n' \
      "$name" "$ip" "$user" "$key" >> "$HOME/.ssh/config"
    say "✅ SSH alias '$name' -> $user@$ip ($host)"
  fi

  # Tailscale authenticates the peer, so learning the host key over the
  # tailnet is safe; the fingerprint is printed to compare with the host's.
  local fp
  if ! ssh-keygen -F "$ip" >/dev/null 2>&1; then
    if ssh-keyscan -T 5 -t ed25519 "$ip" 2>/dev/null > "$HOME/.ssh/.swarm-hostkey" && [[ -s $HOME/.ssh/.swarm-hostkey ]]; then
      cat "$HOME/.ssh/.swarm-hostkey" >> "$HOME/.ssh/known_hosts"
      fp=$(ssh-keygen -lf "$HOME/.ssh/.swarm-hostkey" | awk '{print $2}')
      say "✅ trusted $host's host key $fp"
    else
      say "ℹ️  $host's sshd isn't reachable yet; its key will be asked for on first connect"
    fi
    rm -f "$HOME/.ssh/.swarm-hostkey"
  fi

  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/$name" <<EOF
#!/bin/bash
# Join the agent swarm on $host over Tailscale (remote-swarm-setup.sh).
if command -v join-parallel >/dev/null 2>&1; then
  exec join-parallel --remote $name "\$@"
fi
exec herdr --remote $name "\$@"
EOF
  chmod 755 "$HOME/.local/bin/$name"
  say "✅ installed ~/.local/bin/$name"

  say ""
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" true 2>/dev/null; then
    say "✅ $name already accepts this login (Tailscale SSH or an authorized key)."
    say "   No host step needed. Run:  $name"
    return
  fi
  say "Next, on $host run:"
  say "  remote-swarm-setup.sh host --authorize '$(cat "$key.pub")'"
  say "  (or: remote-swarm-setup.sh host --tailscale-ssh)"
  say "Then here:  $name"
}

case "${1:-}" in
  host) shift; host_setup "$@" ;;
  client) shift; client_setup "$@" ;;
  -h|--help|"") usage ;;
  *) die "first argument must be 'host' or 'client' (see --help)" ;;
esac

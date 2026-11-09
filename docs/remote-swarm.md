# Remote swarm over Tailscale

Run the swarm on one machine (the **host**, say a desktop or a server) and
manage it from another (the **client**: a laptop, a ClockworkPi uConsole,
another desktop). The client attaches to the host's herdr or tmux session over
SSH, and Tailscale carries the SSH, so nothing is exposed beyond your tailnet.

```
client ──ssh over tailscale──▶ host: herdr / tmux swarm
  swarm                          start-parallel 3 --agent claude --mux herdr
```

## Prerequisites

- Tailscale installed and logged in on both machines, on the same tailnet
  (`tailscale status` lists both).
- On the host: the swarm's multiplexer (herdr or tmux) and `openssh`.
- On the client: `ssh`, and herdr if the host runs herdr. Herdr's protocol
  versions must match: run `herdr status` on both. The client needs
  `join-parallel` only if you prefer it over the `swarm` command.

## Set up (once per client)

`remote-swarm-setup` is linked into `~/.local/bin` by `/autocoder:install`.
Elsewhere, run `plugins/autocoder/scripts/remote-swarm-setup.sh` from a clone
of this repo.

**1. On the client**, name the host as Tailscale knows it:

```bash
remote-swarm-setup client nuc-1          # or user@nuc-1, --name <alias>
```

This:
- creates a dedicated key, `~/.ssh/id_ed25519_swarm`;
- adds a `Host swarm` alias pointing at the host's Tailscale IP;
- trusts the host key it learns over the tailnet, and prints its fingerprint;
- installs a `swarm` command in `~/.local/bin`;
- prints the exact line to run on the host.

If the host already runs **Tailscale SSH** (`tailscale set --ssh`), the client
can log in right away. Step 1 tests this, prints "No host step needed", and
you can skip step 2. Tailscale SSH needs no sshd and no keys; your tailnet's
SSH policy decides who may log in. To turn it on from the host, run
`remote-swarm-setup host --tailscale-ssh`.

**2. On the host** (only when step 1 asks for it), paste the line it printed:

```bash
remote-swarm-setup host --authorize 'ssh-ed25519 AAAA… uconsole-swarm'
```

This:
- authorizes the key;
- with sudo, enables sshd with password and root logins disabled
  (`/etc/ssh/sshd_config.d/50-remote-swarm.conf`);
- if ufw is active, allows port 22 **only on `tailscale0`**;
- prints the host key fingerprint, so you can compare it with step 1.

**3. On the client:**

```bash
swarm                                 # = join-parallel --remote swarm
```

## Using it

| Command | What it does |
|---|---|
| `swarm` | Attach to the host's swarm (herdr TUI, or `tmux attach`) |
| `join-parallel --remote swarm` | The same, through join-parallel |
| `join-parallel --remote swarm claude-myproj` | Attach to one herdr session or tmux session |
| `SWARM_REMOTE=swarm join-parallel` | Make remote the default in this shell (`--local` overrides it) |
| `ssh swarm start-parallel 3 --agent claude --mux herdr` | Start a swarm on the host from the client |

Detaching (herdr: prefix, then `d`; tmux: `Ctrl+b`, then `d`) leaves every
agent running on the host. `--remote` auto-detects herdr, when its server is
running on the host, and falls back to tmux; `--mux herdr|tmux` forces one.
cmux has no remote attach.

## Security notes

- Logins are by key only, and the client's key is dedicated to this alias, so
  revoking it is one line in the host's `~/.ssh/authorized_keys`.
- With ufw active, sshd is reachable only from your tailnet. Without a
  firewall it also listens on the LAN; logins are still key-only.
- With Tailscale SSH, access follows your tailnet ACL `ssh` rules. A rule with
  `"action": "check"` asks for periodic browser re-authentication;
  `"accept"` does not.

## First attach: herdr may offer to restart the host's server

If the host's herdr server was started outside an SSH-safe launch, the first
`swarm` warns that the server may not survive a dropped SSH connection, and
offers to restart it. Restarting stops every pane on the host, agents included.
Say yes once, when no agent is mid-task; after that, a dropped connection
(common on laptops and handhelds) disconnects only that client.
- An attached client can do anything the host user can, and so can the agents.
  Only authorize devices you control.

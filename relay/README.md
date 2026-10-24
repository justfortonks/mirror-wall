# Mirror Wall Relay

A byte pump for Mirror Wall Cast on networks where the phone can't reach the Mac: a customer's
guest Wi-Fi that keeps devices apart, or two different networks with no Tailscale. Both ends dial
out to the relay over TLS on port 443, which every network lets through; the relay pairs a phone's
six-digit code with the Mac's waiting connection and copies bytes verbatim from then on. It never
parses the Cast protocol, so the apps' protocol doesn't change. See `../docs/relay-design.md`.

## Wire protocol

The first line from each side is JSON; after pairing, the connection is the raw Cast stream.

| From | Line | Reply |
| --- | --- | --- |
| Mac | `{"type":"open","token":T,"slot":"Mirror Wall 1","device":ID}` | `{"type":"code","code":"482913","expiresIn":1800}`; later `{"type":"joined"}` when a phone arrives, then raw bytes |
| Phone | `{"type":"join","code":"482913"}` | `{"type":"joined"}` then raw bytes, or `{"type":"error","reason":…}` and the connection closes |

- One waiting Mac connection per slot. When a phone takes it, the Mac opens another for the
  next phone. Reopening the same slot (same token, device and slot name) returns the same code
  while it lives: 30 minutes from the last open (`CODE_TTL`).
- `token` is the team's shared secret (`RELAY_TOKEN`); the relay serves only Macs that know it.
- A wrong code spends a slot in a global limiter (30 a minute), so codes can't be enumerated.
- The relay sees the video in the clear while piping it (TLS ends at Fly's edge). If that
  matters, end-to-end encryption of the Cast stream keyed from the code is the next step.

## Run it

```sh
go test ./...                       # pairs a fake Mac and phone through the relay
RELAY_TOKEN=dev go run .            # listens on :7000, plain TCP, for local testing
```

## The live relay

`mirror-wall-relay.fly.dev:443` (TLS), in Fly's `ord` region, on Cody's personal Fly account.
The team token is in the Mac mini's keychain under "Mirror Wall Relay token"
(`security find-generic-password -a mirrorwall -s "Mirror Wall Relay token" -w`). Deployed
October 24, 2026; verified end to end with a fake Mac and phone.

## Deploy to Fly.io

```sh
fly auth login
fly launch --copy-config --no-deploy   # once; accepts fly.toml, creates the app
fly secrets set RELAY_TOKEN="$(openssl rand -hex 24)"
fly deploy
fly logs
```

The relay is then at `mirror-wall-relay.fly.dev:443` (TLS). Put that host and the token in
Mirror Wall › Settings › Relay on each Mac; phones get the host and code from the QR code. A
custom domain: `fly certs add relay.example.com` and a CNAME to the app.

The machine stops when idle and starts on the first connection (a second or two of delay for the
first phone of a demo). Change `min_machines_running` to 1 in `fly.toml` to keep it warm.

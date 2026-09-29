# pep_core: shared low-level library for "Parcours et Pistes"

## Context
We're building a free, open-source (MIT) app for iOS, Android and the web for sharing search-dog trails:
- **RU** (Recherche Utilitaire): track + object positions + extra info
- **MT** (Man Trailing): track only

A creator makes a project, imports GPX tracks and shares a link plus a password. Participants decrypt the tracks and live-share their positions within the project.

**Design constraints:**
- There is no central user database.
- All project data lives on an MQTT broker under the project's UUID topic, as compressed and encrypted retained messages. Nothing is ever published unencrypted.
- A default broker and account are preconfigured, and users can change them.
- Apps will be built in **Flutter**. Background location is handled by the app later; OwnTracks serves only as a behavioural reference.

This plan covers **only the shared library**. App work starts once the library passes full functional tests.

## Step 0: Repo, memory and git setup
- Run `git init` in `/home/pmp/devel/parcours-et-pistes` on branch `main`, with a `.gitignore` covering `.dart_tool/`, `build/`, `*.lock` for the app later, and `.claude/settings.local.json`.
- Keep **all Claude-related files in the repo** under `.claude/`:
  - `.claude/memory/`: memory files + `MEMORY.md` index
  - `.claude/scripts/`: helper scripts
  - `.claude/settings.json` and `.claude/launch.json` as needed
- Replace the empty `~/.claude/projects/-home-pmp-devel-parcours-et-pistes/memory/` with a **symlink** to `<repo>/.claude/memory`. Automatic memory recall keeps working, and the files are versioned with git.
- Add a root `CLAUDE.md` with a short project overview, the repo layout, the "commit often" rule and a pointer to `.claude/memory/`.
- Memories to write:
  - `project-gpx-trail-app.md`: the summary above + the key decisions below
  - `feedback-repo-conventions.md`: memories and Claude scripts live in the repo, and we commit often
- **Commit often:** one commit per logical step (setup, each phase, each green test milestone), with messages ending in the Co-Authored-By line.

## Key decisions
| Topic | Choice | Why |
|---|---|---|
| Language | **Pure Dart package** | Flutter apps use it directly on iOS, Android and the web, with no FFI or bindings to maintain. It's the easiest option for all three targets. |
| Crypto | **libsodium** via `sodium` (Dart VM + web via sodium.js); apps inject the `sodium_libs` instance | Audited library that is fast everywhere, including Argon2id on the web (wasm). |
| KDF | Argon2id(password, salt, params) → 32-byte project key. Params and salt are stored in the plaintext `meta` topic. | Params are versioned, so they can be tuned later. |
| Cipher | XChaCha20-Poly1305 AEAD, with a random 24-byte nonce and the topic path as associated data | Random nonces are safe at this size, and the associated data stops a message being replayed onto another topic. |
| Compression | Deflate (`archive` package, pure Dart), applied before encryption | Works on every platform, and GPX (XML) compresses well. |
| Integrity / roles | Each device has a local **Ed25519 identity**. The project doc is signed by the **owner** and lists **editor** public keys (delegation). Track docs must be signed by the owner or a listed editor. Positions are signed by their sender. Signatures sit *inside* the ciphertext. | Participants reject forgeries. The owner can grant or revoke editors by republishing the project doc. |
| Trust anchor | The join link carries the UUID and the owner-key fingerprint (plus an optional broker) in the URL **fragment**. The password is shared separately. | New joiners can't be fooled by a replaced project doc. The fragment isn't sent to web servers. |
| MQTT | `mqtt5_client` (TCP/TLS on native, WSS in the browser), behind a pluggable `Transport` interface | You chose "both, pluggable". MQTT 5 is needed for message expiry on positions. |
| Position TTL | Retained publish with MQTT 5 **message expiry** = project setting, plus a client-side filter on the timestamp | The broker removes stale positions, and clients stay correct even if a broker ignores expiry. |
| License | MIT | Your choice. |

## Topic layout (base configurable, default `pep/v1`)
```
pep/v1/<uuid>/meta                  retained, plaintext JSON: format version, KDF alg+params, salt
pep/v1/<uuid>/project               retained, sealed+signed(owner): name, discipline RU|MT, settings
                                     (position TTL…), owner pubkey, editors[], track index [{id, rev, sha256}]
pep/v1/<uuid>/track/<trackId>       retained, sealed+signed(owner|editor): compressed GPX + metadata
pep/v1/<uuid>/member/<memberId>     retained, sealed+signed: display name, pubkey
pep/v1/<uuid>/pos/<memberId>        retained + expiry, sealed+signed: lat, lon, alt, acc, hdg, spd, ts
```
- **Update:** republish the same topic (retained replaces the old message).
- **Delete:** publish an empty retained payload.
- **Clients** subscribe only to `pep/v1/<uuid>/#` (a literal UUID).

**Broker note (out of library scope; documented in `tools/broker/README.md`):** we want to forbid wildcard subscriptions above the UUID level (e.g. `pep/v1/#` or `pep/v1/+/…`), so UUIDs stay secret. Plain Mosquitto ACLs can't express this, so it needs an auth plugin (mosquitto-go-auth or dynsec) or EMQX authz. For development we ship a Mosquitto docker-compose (MQTT 5, TLS and WebSockets) without that rule.

## Envelope format (binary, all sealed payloads)
`magic "PEP1" | version u8 | nonce[24] | AEAD(key, ad=topic, plaintext)`
The plaintext is `flags(compressed) | signerPubKey[32] | signature[64] | body`, where the body is deflated JSON or GPX bytes and the signature covers `topic || body`.

## Package layout
```
parcours-et-pistes/
  LICENSE (MIT), README.md, CLAUDE.md, .gitignore
  .claude/memory/  .claude/scripts/  .claude/settings.json
  packages/pep_core/
    lib/pep_core.dart            public exports
    lib/src/crypto/              kdf.dart, envelope.dart, identity.dart (Ed25519)
    lib/src/codec/               compression.dart, json models
    lib/src/model/               project_doc.dart, track_doc.dart, position.dart, member.dart,
                                 gpx.dart (GPX parse/write; RU objects as <wpt> + pep: extensions)
    lib/src/protocol/            topics.dart, join_link.dart, validation (signature/role checks)
    lib/src/transport/           transport.dart (abstract), mqtt5_transport.dart, memory_transport.dart
    lib/src/session/             project_session.dart (high-level API)
    bin/pep.dart                 CLI for manual end-to-end testing
    test/                        unit + integration tests
  tools/broker/                  docker-compose.yml, mosquitto.conf, README.md
```

## Public API (high level)
- `PepCore.init(sodium)`: initialises the library with the libsodium instance to use.
- `Identity.generate() / export / import`
- `ProjectSession.create(transport, identity, name, discipline, password, settings)` → session + `JoinLink`
- `ProjectSession.join(transport, identity, link, password)`
- Session methods:
  - `publishTrack(gpx, meta)`, `deleteTrack(id)`
  - `addEditor(pubKey)`, `removeEditor`
  - `updateSettings`, `changePassword` (owner re-seals everything)
  - `publishPosition(pos)`, `clearPosition()`
  - `setMember(displayName)`, `leave()`
- Streams: `project`, `tracks`, `positions` (TTL-filtered), `members`, `errors` (e.g. rejected or forged messages)
- `Transport`: `connect`, `publish(topic, bytes, {retain, expiry})`, `subscribe(filter)`, `messages`, `disconnect`, connection-state stream

## Implementation phases
1. **Spike (half a day).** Verify on the Dart VM and in Chrome that `sodium` works (Argon2id timing on the web, AEAD, Ed25519) and that `mqtt5_client` works (WSS, retained messages, message expiry against Mosquitto). If Argon2id on the web is too slow at safe params, fall back to a lower memory cost. The params are stored per project.
2. Crypto, envelope and compression, with test vectors.
3. Models, GPX (tracks + RU object waypoints) and topics/join link.
4. Transport interface, in-memory transport and MQTT 5 transport.
5. `ProjectSession`: create, join, tracks, editors, positions + TTL, password change, signature enforcement.
6. CLI and broker tooling, then README and API docs.

Each phase ends with its tests green and a git commit. Larger phases get intermediate commits.

## Verification
- `dart test` (VM) and `dart test -p chrome` (web) run the unit tests:
  - crypto round-trips, and tampering, wrong-password and wrong-topic failures
  - signature and role enforcement: an editor added then removed, and a forged track rejected
  - GPX round-trip
  - TTL filtering
- Integration tests run the same suite against `tools/broker` Mosquitto (TCP/TLS on the VM, WSS in Chrome):
  - two sessions (owner + participant) share tracks
  - positions appear, then expire
  - a delegated editor updates a track
  - after a password change, the old password fails
- Manual end-to-end with the CLI in two terminals: `pep create --gpx trail.gpx` prints the link. Then `pep join <link>` followed by `pep watch` shows tracks, and `pep pos 45.1 5.7` shows positions live.
- Using `mosquitto_sub -v -t 'pep/v1/#'` as the admin confirms that every payload except `meta` is opaque ciphertext.

# pep_channel

Secure channel of **Parcours et Pistes**: end-to-end encrypted, signed and access-controlled
collections of opaque items, synchronized over MQTT 5. Pure Dart (VM, Flutter, browsers).
It knows nothing about the content it carries.

- `SecureChannel.create` / `join` (join link + password), `put` / `delete` / `items` / `item`,
  `updateAcl` / `assign`, `sync`, `prune`, `close`, `deleteChannel`, `events`;
  `selfItemId` (a member's own items, under a per-channel pseudonym and an optional device tag),
  `recipientsOf` (restricted items), `canWrite`, `joinLink`.
- Owner-signed `ChannelAcl`: declared collections, each with a writer policy (`owner`,
  `assigned` — one writer per item, named by the owner —, `self`) and an optional TTL
  (ephemeral items).
- Restricted items: `put(..., recipients:)` seals the content key for the recipients only (the
  owner and the publisher are always among them).
- Identities: `Identity` (Ed25519; member id = its public key, `fingerprintOf` for people to
  compare), `IdentityExport` (passphrase-protected text to keep as a backup or move to another
  device), `JoinLink`.
- libsodium: Argon2id, XChaCha20-Poly1305, Ed25519. Transports: `Mqtt5Transport`
  (mqtt, mqtts, ws, wss; certificate pinning on the VM) and `MemoryTransport` (tests).

```dart
final crypto = await PepCrypto.init();
final me = Identity.generate(crypto);
final channel = await SecureChannel.create(
  crypto: crypto, transport: MemoryTransport(MemoryBroker()),
  identity: me, password: 'secret',
  collections: {'note': const CollectionPolicy(Writers.assigned)},
);
await channel.put('note', channel.generateItemId(), utf8Bytes('hello'));
```

Protocol and threat model: [`docs/DESIGN.md`](../../docs/DESIGN.md).

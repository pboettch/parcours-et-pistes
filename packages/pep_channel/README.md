# pep_channel

Secure channel of **Parcours et Pistes**: end-to-end encrypted, signed and access-controlled
collections of opaque items, synchronized over MQTT 5. Pure Dart (VM, Flutter, browsers).
It knows nothing about the content it carries.

- `SecureChannel.create` / `join` (join link + password), `put` / `delete` / `items`,
  `updateAcl` / `addEditor` / `removeEditor`, `changePassword` / `unlock`, `sync`,
  `deleteChannel`, `events`.
- Owner-signed `ChannelAcl`: editors and declared collections, each with a writer policy
  (`owner`, `editors`, `self`) and an optional TTL (ephemeral items).
- libsodium: Argon2id, XChaCha20-Poly1305, Ed25519. Transports: `Mqtt5Transport`
  (mqtt, mqtts, ws, wss; certificate pinning on the VM) and `MemoryTransport` (tests).

```dart
final channel = await SecureChannel.create(
  crypto: await PepCrypto.init(), transport: MemoryTransport(MemoryBroker()),
  identity: me, password: 'secret',
  collections: {'note': const CollectionPolicy(Writers.editors)},
);
await channel.put('note', channel.generateItemId(), utf8Bytes('hello'));
```

Protocol and threat model: [`docs/DESIGN.md`](../../docs/DESIGN.md).

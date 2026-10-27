# pep_content

Content model of **Parcours et Pistes** — pure data and byte codecs, no cryptography, no
networking (the secure transport is `pep_channel`):

- `Gpx`: GPX 1.1 reader/writer — tracks, routes (read as single-segment tracks) and waypoints:
  RU objects (`<type>pep:object</type>`, `GpxWaypoint.object`) and useful places
  (`<type>pep:place</type>`, `GpxWaypoint.place`). `<extensions>` on the file, its metadata,
  waypoints, tracks/routes and points are preserved on a round trip (not on track segments).
  Custom sections use the namespace `urn:parcours-et-pistes:gpx:1` (prefix `pep`): build with
  `pepElement(...)`, read with `.extensions.pep('name')` / `.pepAll('name')`. Other elements the
  model does not keep (e.g. `<link>`, `<author>`) are dropped when a document is rewritten.
- `TrailInfo`: official RU trail details in the GPX metadata (`<pep:trail code level setter>`);
  `objectsFromWaypoints` marks the plain waypoints of files from other tools (e.g. Visorando)
  as objects, except those at the start or end of the track.
- JSON documents with `encode()` / `decode()`, each carrying `"v":1` and (except `Position`) an
  `extra` object kept on a round trip: `ProjectInfo` (+ `Discipline`), `MemberProfile`,
  `Position`, `Run` (+ `RunSource`, `RunStatus`: the dog, its track and the members designated
  as its position source over time), `RecordedPath` (points recorded by a device, compact).
- Geometry: `GeoPoint`, `TimedPoint`, `distanceMeters`, `TrackLine` (nearest point, point at a
  distance along the track, slices); `TrailProgress.match` (how far a dog's path has come along
  the track, tuned by `ProgressParams`); `TrailWalker` and `simulateTrail` (simulated trails and
  walks, repeatable with a seed).

Invalid content raises `ContentFormatException`; in a GPX, unreadable `<ele>` and `<time>`
values are skipped. `package:xml` is re-exported (custom sections are `XmlElement`s).

## Why our own GPX implementation?

Existing Dart packages were evaluated on 2026-09-29 with a GPX file carrying `pep:` custom
sections (metadata, waypoint and track-point level) plus a Garmin extension, read then
written back:

| Package | Result |
|---|---|
| [`gpx`](https://pub.dev/packages/gpx) 2.5.0 | Loses attributes of leaf extension elements, writes other attributes as an invalid `<@attributes>` element, drops all namespace declarations, rewrites values (`10` → `10.0`). |
| [`geoxml`](https://pub.dev/packages/geoxml) 2.6.2 | Extensions are a flat `Map<String, String>`: nested or attributed content is lost. |
| [`activity_files`](https://pub.dev/packages/activity_files) 0.7.8 | Keeps extensions, but writes the `gpxx:` prefix without declaring it, invents data (epoch timestamps on points without time, `<desc>`, `<type>Unknown</type>`) and models sport activities rather than trails. |

Since everything about a track travels in its custom sections, and a trail drawn on a map has
no timestamps, none of them fits. `Gpx` is small (about 400 lines, depends only on `xml`),
preserves extensions with their namespaces, and GPX 1.1 is a stable format. Worth re-evaluating
`activity_files` later: it is actively maintained and close.

# pep_content

Content model of **Parcours et Pistes** — pure data and byte codecs, no cryptography, no
networking (the secure transport is `pep_channel`):

- `Gpx`: GPX 1.1 reader/writer — tracks, routes, waypoints (RU objects: `<type>pep:object</type>`),
  and `<extensions>` at every level, preserved on round trip. Custom sections use the namespace
  `urn:parcours-et-pistes:gpx:1` (prefix `pep`): build with `pepElement(...)`, read with
  `.extensions.pep('name')`.
- `Position`, `MemberProfile`, `ProjectInfo` (+ `Discipline`): JSON documents with `encode()` /
  `decode()`.

Invalid content raises `ContentFormatException`.

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
no timestamps, none of them fits. `Gpx` is small (≈360 lines, depends only on `xml`), preserves
extensions with their namespaces, and GPX 1.1 is a stable format. Worth re-evaluating
`activity_files` later: it is actively maintained and close.

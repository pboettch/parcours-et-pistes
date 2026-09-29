/// Content model of Parcours et Pistes: GPX tracks (with custom `pep`
/// sections), positions, member profiles and project information.
///
/// Pure data and byte codecs — no cryptography and no networking; the secure
/// transport is `pep_channel`.
library;

// GPX custom sections are exposed as XmlElement (package:xml).
export 'package:xml/xml.dart';

export 'src/errors.dart';
export 'src/gpx.dart';
export 'src/json.dart' show Json, utf8Bytes;
export 'src/member.dart';
export 'src/position.dart';
export 'src/project_info.dart';

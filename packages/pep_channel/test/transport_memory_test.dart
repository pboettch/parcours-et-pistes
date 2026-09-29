import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

import 'support/transport_contract.dart';

void main() {
  test('topicMatches', () {
    expect(topicMatches('a/#', 'a/b/c'), isTrue);
    expect(topicMatches('a/#', 'a'), isTrue);
    expect(topicMatches('a/+/c', 'a/b/c'), isTrue);
    expect(topicMatches('a/+/c', 'a/b/d'), isFalse);
    expect(topicMatches('a/+', 'a/b/c'), isFalse);
    expect(topicMatches('a/b', 'a/b'), isTrue);
    expect(topicMatches('a/b', 'a/b/c'), isFalse);
  });

  transportContract('memory', MemoryHarness.new);
}

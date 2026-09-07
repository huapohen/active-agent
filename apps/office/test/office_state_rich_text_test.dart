import 'package:active_office/office_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'office_state_test.dart' show Service;

void main() {
  for (final kind in ['human', 'agent']) {
    test(
      '$kind styled send carries ranges and recovers the same ambiguous intent',
      () async {
        final service = Service(kind)..loseFirstSend = true;
        final office = OfficeState(client: MockClient(service.call));
        await office.connect('http://localhost', 'private-test-identity');
        final rich = <String, dynamic>{
          'version': 1,
          'spans': [
            {
              'start': 0,
              'end': 4,
              'styles': ['bold'],
            },
          ],
        };
        await expectLater(
          office.send('ABCD', richText: rich),
          throwsA(isA<OfficeException>()),
        );
        await office.send('ABCD', richText: rich);
        expect(service.bodies.first['rich_text'], rich);
        expect(
          service.bodies.first['client_id'],
          service.bodies[1]['client_id'],
        );
        await office.send('ABCD');
        expect(service.bodies.last.containsKey('rich_text'), false);
        expect(
          service.bodies.last['client_id'],
          isNot(service.bodies.first['client_id']),
        );
        office.disconnect();
        office.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 130));
      },
    );
  }
  test('a changed style has a new intent while the unresolved original remains retryable', () async {
    final service = Service('human')..loseFirstSend = true;
    final office = OfficeState(client: MockClient(service.call));
    await office.connect('http://localhost', 'private-test-identity');
    Json format(String style) => {
      'version': 1,
      'spans': [
        {
          'start': 0,
          'end': 4,
          'styles': [style],
        },
      ],
    };
    await expectLater(
      office.send('ABCD', richText: format('bold')),
      throwsA(isA<OfficeException>()),
    );
    await office.send('ABCD', richText: format('italic'));
    await office.send('ABCD', richText: format('bold'));
    expect(
      service.bodies[0]['client_id'],
      isNot(service.bodies[1]['client_id']),
    );
    expect(service.bodies[0]['client_id'], service.bodies[2]['client_id']);
    office.disconnect();
    office.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 130));
  });
}

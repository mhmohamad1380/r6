import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/next_step.dart';

NextStep s({bool name = true, bool server = true, int rounds = 0, bool found = true}) => nextStep(hasAccount: name, serverConfigured: server, rounds: rounds, playerFound: found);

void main() {
  test('every state of a new user has exactly one clear next step', () {
    expect(s(name: false, server: false).id, StepId.account);
    expect(s(server: false).id, StepId.connectPc);
    expect(s(server: false).secondary, isNotNull, reason: 'importing by hand is offered, quietly');
    expect(s().id, StepId.waiting);
    expect(s(rounds: 12, found: false).id, StepId.pickYourself);
    expect(s(rounds: 12).id, StepId.coach);
  });

  test('the checklist ticks off as things happen', () {
    expect(s(name: false, server: false).doneCount, 0);
    expect(s(server: false).doneCount, 1);
    expect(s().doneCount, 2);
    expect(s(rounds: 5).doneCount, 3);
    expect(s(rounds: 5).complete, isTrue);
    expect(s(server: false, rounds: 5).items[1].done, isTrue, reason: 'replays imported by hand also count as connected');
  });

  test('a name beats everything: nothing else matters until the app knows who you are', () {
    expect(s(name: false, rounds: 40).id, StepId.account);
  });
}

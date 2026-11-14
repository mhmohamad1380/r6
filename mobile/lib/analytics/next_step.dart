/// Where the user is in getting set up, and the one thing to do next. Pure, so it can be tested without any UI.
enum StepId { account, connectPc, waiting, pickYourself, coach }

class SetupItem {
  const SetupItem(this.label, this.done);
  final String label;
  final bool done;
}

class NextStep {
  const NextStep({required this.id, required this.title, required this.message, required this.action, required this.items, this.secondary});
  final StepId id;
  final String title, message, action;
  final String? secondary; // a second, quieter way forward
  final List<SetupItem> items;

  int get doneCount => items.where((i) => i.done).length;
  bool get complete => items.every((i) => i.done);
}

NextStep nextStep({required bool hasAccount, required bool serverConfigured, required int rounds, required bool playerFound}) {
  final items = [
    SetupItem('Your Ubisoft name', hasAccount),
    SetupItem('PC connected', serverConfigured || rounds > 0),
    SetupItem('Replays received', rounds > 0),
  ];
  if (!hasAccount) {
    return NextStep(id: StepId.account, title: 'Tell us who you are', message: 'Enter your Ubisoft name so the coach can find you in your replays.', action: 'Add my name', items: items);
  }
  if (rounds == 0 && !serverConfigured) {
    return NextStep(
      id: StepId.connectPc,
      title: 'Connect your PC',
      message: 'A small Windows app sends your match replays here. Set it up once and every match arrives by itself.',
      action: 'Connect my PC',
      secondary: 'Or import a replay file by hand',
      items: items,
    );
  }
  if (rounds == 0) {
    return NextStep(id: StepId.waiting, title: 'Waiting for your first replays', message: 'Play a match with the PC app running, then tap Sync. The coach appears as soon as 3 rounds arrive.', action: 'Sync now', items: items);
  }
  if (!playerFound) {
    return NextStep(id: StepId.pickYourself, title: 'We could not find you in these replays', message: 'Check that your Ubisoft name is spelled exactly as in the game.', action: 'Check my name', items: items);
  }
  return NextStep(id: StepId.coach, title: 'See how you played', message: 'Your Match Coach has a score for every game and a plan for the next session.', action: 'Open my Match Coach', items: items);
}

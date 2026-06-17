import 'package:sip_ua/src/event_manager/event_manager.dart';
import 'package:sip_ua/src/event_manager/internal_events.dart';
import 'package:sip_ua/src/stack_trace_nj.dart';
import 'package:test/test.dart';

List<void Function()> testFunctions = <void Function()>[
  () =>
      test('EventManager accepts typed listeners with explicit event type', () {
        final EventManager manager = EventManager();
        int calls = 0;

        void stateChanged(EventStateChanged event) {
          calls++;
        }

        expect(
          () =>
              manager.on<EventStateChanged>(EventStateChanged(), stateChanged),
          returnsNormally,
        );

        manager.emit(EventStateChanged());
        expect(calls, 1);
      }),
  () => test('StackTraceNJ.toString handles empty parsed frames', () {
        expect(
          () => StackTraceNJ(skipFrames: 1000000).toString(),
          returnsNormally,
        );
      }),
];

void main() {
  for (final void Function() func in testFunctions) {
    func();
  }
}

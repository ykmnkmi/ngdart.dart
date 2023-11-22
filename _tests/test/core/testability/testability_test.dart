import 'dart:async';

import 'package:ngdart/angular.dart';
import 'package:test/test.dart';

// Schedules a microtasks (using a resolved promise .then())
void microTask(void Function() fn) {
  scheduleMicrotask(() {
    // We do double dispatch so that we  can wait for scheduleMicrotasks in
    // the Testability when NgZone becomes stable.
    scheduleMicrotask(fn);
  });
}

@Injectable()
class TestZone implements NgZone {
  final _delegate = NgZone();
  final _onUnstableStream = StreamController<void>.broadcast(sync: true);
  final _onStableStream = StreamController<void>.broadcast(sync: true);

  @override
  Stream<void> get onTurnStart {
    return _onUnstableStream.stream;
  }

  @override
  Stream<void> get onTurnDone {
    return _onStableStream.stream;
  }

  void unstable() {
    _onUnstableStream.add(null);
    isRunning = true;
  }

  void stable() {
    _onStableStream.add(null);
    isRunning = false;
  }

  @override
  void dispose() => _delegate.dispose();

  @override
  bool get hasPendingMacrotasks => _delegate.hasPendingMacrotasks;

  @override
  bool get hasPendingMicrotasks => _delegate.hasPendingMicrotasks;

  @override
  bool get inInnerZone => _delegate.inInnerZone;

  @override
  bool get inOuterZone => _delegate.inOuterZone;

  @override
  var isRunning = false;

  @override
  Stream<UncaughtError> get onUncaughtError => _delegate.onUncaughtError;

  @override
  Stream<void> get onEventDone => _delegate.onEventDone;

  @override
  Stream<void> get onMicrotaskEmpty => _delegate.onMicrotaskEmpty;

  @override
  R run<R>(callback) => _delegate.run(callback);

  @override
  void runAfterChangesObserved(callback) {
    _delegate.runAfterChangesObserved(callback);
  }

  @override
  void runGuarded(callback) {
    _delegate.runGuarded(callback);
  }

  @override
  R runOutsideAngular<R>(callback) => _delegate.runOutsideAngular(callback);
}

void main() {
  group('Testability', () {
    late Testability testability;
    late TestZone ngZone;

    late int callback1Calls;
    late int callback2Calls;

    void mockCallback1() {
      callback1Calls++;
    }

    void mockCallback2() {
      callback2Calls++;
    }

    setUp(() {
      ngZone = TestZone();
      testability = Testability(ngZone);
      callback1Calls = 0;
      callback2Calls = 0;
    });

    group('NgZone callback logic', () {
      test('should fire whenstable callback if event is already finished',
          () async {
        ngZone.unstable();
        ngZone.stable();
        testability.whenStable(mockCallback1);
        microTask(() {
          expect(callback1Calls, equals(1));
        });
      });

      test(
          'should not fire whenstable callbacks synchronously '
          'if event is already finished', () {
        ngZone.unstable();
        ngZone.stable();
        testability.whenStable(mockCallback1);
        expect(callback1Calls, isZero);
      });

      test('should fire whenstable callback when event finishes', () async {
        ngZone.unstable();
        testability.whenStable(mockCallback1);
        microTask(() {
          expect(callback1Calls, isZero);
          ngZone.stable();
          microTask(() {
            expect(callback1Calls, equals(1));
          });
        });
      });

      test(
          'should not fire whenstable callbacks '
          'synchronously when event finishes', () {
        ngZone.unstable();
        testability.whenStable(mockCallback1);
        ngZone.stable();
        expect(callback1Calls, isZero);
      });

      test('should fire whenstable callback if event is already finished',
          () async {
        ngZone.unstable();
        testability.whenStable(mockCallback1);
        ngZone.stable();
        microTask(() {
          expect(callback1Calls, equals(1));
          testability.whenStable(mockCallback2);
          microTask(() {
            expect(callback2Calls, equals(1));
          });
        });
      });

      test('should fire whenstable callback when event finishes', () async {
        ngZone.unstable();
        testability.whenStable(mockCallback1);
        microTask(() {
          ngZone.stable();
          microTask(() {
            expect(callback1Calls, equals(1));
            testability.whenStable(mockCallback2);
            microTask(() {
              expect(callback2Calls, equals(1));
            });
          });
        });
      });
    });
  });
}

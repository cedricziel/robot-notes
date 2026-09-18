import 'package:app/src/widgets/resizable_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts the panel the way the shell does: width state lives in the
/// parent and is fed back through [ResizablePanel.onWidthChanged].
class _Host extends StatefulWidget {
  const _Host({required this.initial, this.min = 200, this.max = 420});

  final double initial;
  final double min;
  final double max;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late double width = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ResizablePanel(
          width: width,
          minWidth: widget.min,
          maxWidth: widget.max,
          onWidthChanged: (w) => setState(() => width = w),
          child: const ColoredBox(
            key: Key('pane'),
            color: Colors.blue,
            child: SizedBox.expand(),
          ),
        ),
        const Expanded(child: SizedBox.expand()),
      ],
    );
  }
}

void main() {
  final handle = find.byKey(const Key('panel.resizeHandle'));
  final pane = find.byKey(const Key('pane'));

  /// Drags the handle by [dx] with a mouse (no touch slop is swallowed,
  /// so the panel sees exactly [dx]).
  Future<void> drag(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, Widget host) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host)));
  }

  testWidgets('lays the child out at the given width with a handle after it', (
    tester,
  ) async {
    await pump(tester, const _Host(initial: 260));

    expect(tester.getSize(pane).width, 260);
    expect(tester.getSize(handle).width, ResizablePanel.handleWidth);
    expect(tester.getTopLeft(handle).dx, 260);
  });

  testWidgets('dragging the handle reports the new width to the parent', (
    tester,
  ) async {
    await pump(tester, const _Host(initial: 260));

    await drag(tester, 50);
    expect(tester.getSize(pane).width, 310);

    await drag(tester, -80);
    expect(tester.getSize(pane).width, 230);
  });

  testWidgets('clamps drags to minWidth and maxWidth', (tester) async {
    await pump(tester, const _Host(initial: 260, min: 200, max: 420));

    await drag(tester, 500);
    expect(tester.getSize(pane).width, 420);

    await drag(tester, -900);
    expect(tester.getSize(pane).width, 200);
  });

  testWidgets('clamps an out-of-range initial width without a callback', (
    tester,
  ) async {
    final reported = <double>[];
    await pump(
      tester,
      Row(
        children: [
          ResizablePanel(
            width: 900,
            minWidth: 200,
            maxWidth: 420,
            onWidthChanged: reported.add,
            child: const SizedBox.expand(key: Key('pane')),
          ),
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    );

    expect(tester.getSize(pane).width, 420);
    expect(reported, isEmpty);
  });

  testWidgets('does not report a width that would not change', (tester) async {
    final reported = <double>[];
    await pump(
      tester,
      Row(
        children: [
          ResizablePanel(
            width: 420,
            minWidth: 200,
            maxWidth: 420,
            onWidthChanged: reported.add,
            child: const SizedBox.expand(key: Key('pane')),
          ),
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    );

    // Already at the maximum: dragging further right changes nothing.
    await drag(tester, 100);
    expect(reported, isEmpty);

    await drag(tester, -30);
    expect(reported, isNotEmpty);
    expect(reported.last, 390);
  });
}

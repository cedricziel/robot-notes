import 'package:app/src/knowledge/proposal_review_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'operation evidence and superseded sources show full coordinates',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProposalReview(
                context: context,
                proposal: {
                  'operations': [
                    {
                      'type': 'attach_evidence',
                      'evidence_refs': [
                        {
                          'kind': 'block_revision',
                          'note_id': 'source-note',
                          'version': 7,
                          'block_id': 'source-block',
                          'block_revision': 3,
                        },
                        {
                          'kind': 'conversation',
                          'session_id': 'session-1',
                          'turn_id': 'turn-2',
                          'tool_call_id': 'call-3',
                          'task_id': 'task-4',
                        },
                        {'kind': 'archive', 'digest': 'digest-5'},
                      ],
                      'supersedes': [
                        {
                          'kind': 'note_revision',
                          'note_id': 'old-note',
                          'version': 2,
                        },
                      ],
                    },
                  ],
                  'evidence_refs': [
                    {
                      'kind': 'note_revision',
                      'note_id': 'top-source',
                      'version': 4,
                    },
                  ],
                },
                onDecision: (_, _) async {},
                onComment: (_) async {},
              ),
              child: const Text('Review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(find.text('Supporting evidence'), findsOneWidget);
      expect(
        find.text(
          'Note source-note · version 7 · block source-block · revision 3',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Conversation session-1 · turn turn-2 · tool call call-3 · task task-4',
        ),
        findsOneWidget,
      );
      expect(find.text('Evidence archive · digest-5'), findsOneWidget);
      expect(find.text('Superseded sources'), findsOneWidget);
      expect(find.text('Note old-note · version 2'), findsOneWidget);
      expect(find.text('Note top-source · version 4'), findsOneWidget);
    },
  );
}

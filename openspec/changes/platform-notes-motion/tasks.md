## Tasks
- [x] Reproduce missing reduced-motion support.
- [x] Implement platform-specific note and vault dialog motion.
- [x] Verify navigation, dialogs, reduced motion, analysis, and web build.
- [ ] Open a separate pull request.

## Validation

76 router and vault widget tests passed, including iOS edge-swipe back and reduced-motion dialogs across all platform variants. Reduced-motion tests failed against the previous implementation. Changed-file analysis, strict OpenSpec validation, and the release web build passed. The disposable web preview opened and dismissed a vault dialog and navigated into and back from a note. Native device builds were not run.

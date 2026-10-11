## Tasks
- [x] Reproduce missing reduced motion for desktop overlays.
- [x] Implement native mobile sheets and desktop dialog presentation.
- [x] Verify overlay dismissal, reduced motion, analysis, and web build.

## Validation
81 affected router and vault tests passed. Additional narrow-desktop reduced-motion checks passed on macOS, Windows, and Linux. Reduced-motion tests failed against the previous implementation. Analysis, strict spec validation, and release web build passed. The disposable browser preview opened and dismissed search and settings without console warnings or errors. Native devices were not tested.

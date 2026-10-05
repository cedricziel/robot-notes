# Platform-aware workspace

Actual Flutter widget renders using seeded preview notes (not real user data):

- [Mac workspace](mac-workspace.png)
- [Mac dark workspace](mac-dark-workspace.png)
- [iPhone notes](iphone-workspace.png)
- [iPhone reader](iphone-note-workspace.png)
- [iPhone Settings](iphone-settings-workspace.png)

These renders omit native window decorations and the phone status bar. They
show implemented widgets, not the original generated concept. System fonts
and Cupertino/Material icon fonts were loaded for the preview renders.

The app retains its server-backed editing locks, autosave and conflict
handling. Native sharing/export, share extensions, multiple note windows,
native Settings windows and offline recovery are separate follow-ups.

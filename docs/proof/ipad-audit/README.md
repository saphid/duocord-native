# iPad audit proof

Captured on a 13-inch iPad Simulator running iOS 27.2 with offline MockDiscord (`-DuocordMock YES`). Images are direct simulator captures, scaled down; the narrow-window pair is cropped to the app window. "Before" is unmodified main (4104c4a); "after" is this branch.

| Defect | Before | After |
|---|---|---|
| Home with Members open kept Members in the sidebar | `home-members-before.png` | `home-members-after.png` |
| Opening a Search result in another channel blanked the results | `search-jump-before.png` | `search-jump-after.png` |
| A narrow iPad window showed two "…" buttons; Search, Members and Inbox overflowed | `narrow-toolbar-before.png` | `narrow-toolbar-after.png` |
| Hide Sidebar disappeared while typing | `typing-toolbar-before.png` | `typing-toolbar-after.png` |
| Extra Large text: 34 pt channel rows | `rows-xl-before.png` | `rows-xl-after.png` |
| Accessibility Extra Large: names filled 48 pt rows and truncated | `rows-ax-xl-before.png` | `rows-ax-xl-after.png` |

Measured from accessibility frames in portrait: channel rows were 34 pt from Large to Accessibility Medium and 48 pt at Accessibility Extra Large. After the change they are 44 pt at Large and Extra Large. At Accessibility Extra Large, short names are 65 pt rows on one line and longer names wrap fully onto two lines (113 pt). Clearance between the newest message and the composer measured 20–24 pt at every size before and after, including a three- or four-line draft with the keyboard up, so chat spacing is unchanged.

Search jump: 3/3 fresh launches landed on the tapped message, and the results stayed visible. Return inserts a new line and Send sends once; an empty composer can't send. Command-Return could not be delivered by the simulator automation (no modifier keys). A mounted-composer unit test covers it, including the IME composition case.

Not covered: full-screen landscape (rotating this simulator to landscape restores a floating window), Split View and Slide Over, menu interaction inside a narrow window, a hardware keyboard, and real devices. The oversized Inbox badge at accessibility sizes is the system toolbar badge and is unchanged.

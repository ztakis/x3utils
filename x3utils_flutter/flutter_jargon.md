# Flutter jargon

There are two vocabularies:

- Flutter widget names: `Scaffold`, `Row`, `Dialog`, `Tooltip`
- UI/design nicknames: hero, eyebrow, rail, chip, pill

For our app, the useful glossary is:

| Name | Meaning in our app |
|---|---|
| Window | Entire desktop application window |
| Title bar | Top strip with title and window/menu controls |
| Rail / left rail | Left-side mode and action selector |
| Main area | Everything to the right of the rail |
| Header | Stable explanation of the selected action above the hero |
| Hero / hero stage | Large central area showing the current action or result |
| Eyebrow | Small uppercase text above the hero title, such as “FLASHING” |
| Hero title | Large central heading |
| Hero message | Supporting text below the title |
| Visual | Central icon/animation inside the hero |
| Busy spinner | Animated indicator while work is running |
| Result badge | Success/failure visual shown when work finishes |
| Stage buttons | Buttons presented inside the hero area |
| Action tile | Selectable action in the left rail |
| Mode tile | Connection-mode selector |
| Chip | Small compact label, usually informational |
| Pill button | Rounded capsule-shaped button |
| Icon button | Button represented by an icon rather than a text label |
| Status bar | Horizontal information strip near the bottom |
| Firmware bar | Selected-firmware information and controls |
| Console panel/drawer | Expandable OpenOCD output panel |
| Tooltip | Small explanation appearing on hover |
| Dialog/modal | Popup requiring interaction |
| Snackbar/toast | Temporary notification floating near an edge |
| Toggle/switch | On/off setting |
| Dropdown | Control that opens a list of choices |
| Stepper | Plus/minus control for changing a number |
| Resize handle | Area dragged to resize the console |
| Hover / pressed / disabled state | Different visual states of an interactive control |
| Accent color | User-selected highlight color used throughout the interface |
| Theme | Shared colors, typography, and visual styling for the app |
| Widget tree | Parent-and-child hierarchy of widgets composing the interface |
| State | Data that can change what the interface displays |
| Controller | App logic that updates state and drives the interface |
| Responsive layout / breakpoint | Layout rules that adapt to the available window size |
| Scrollable area | Content that can be moved when it does not fit in the available space |
| Padding | Empty space inside an element |
| Margin/gap | Space between elements |
| Divider | Thin line separating sections |

“Hero,” “eyebrow,” “chip,” and “pill” are design terminology, not special Flutter features. In the code, this app formalizes several of those nicknames as classes such as `_HeroStage`, `_Rail`, `_Chip`, and `_PillButton` in [main.dart](./lib/main.dart:571).

When requesting changes, wording like “change the eyebrow above the hero title” or “move the firmware bar below the status bar” will identify the target very precisely.

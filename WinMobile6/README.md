# Windows Mobile 6 Simulator

A single-file, dependency-free browser simulation of a Windows Mobile 6 Professional
Pocket PC. Open `index.html` in any modern desktop or mobile browser; there is no build step.

- 240x320 screen scaled to fill the window, on a device bezel with working Call, Today,
  Back, End, Power, volume and reset buttons.
- Controls: menu button (top left) for **Full screen**, bezel on/off, Today, Back, Power, Soft reset.
  Keys: `F` full screen, `B` bezel, `Esc` back, `H` Today. Phone keypad and calculator accept the keyboard.
- Apps: Today, Start menu, Phone (with simulated incoming calls), Contacts, Calendar, Messaging
  (simulated replies), Internet Explorer (built-in pages only), Windows Media (synthesised tracks),
  Calculator, Notes, Tasks, File Explorer, Pictures, ActiveSync, Search, Help, Solitaire,
  Bubble Breaker, and Settings (Today themes, owner info, sounds, backlight, alarms, power,
  regional, wireless manager).
- Data lives in the browser's `localStorage`. Settings > System > About > Erase all data resets it.

Unofficial; not affiliated with or endorsed by Microsoft.

# ZenHide

ZenHide automatically hides your mouse cursor and desktop icons when you’re idle, or on a hotkey. Show off your wallpaper when you step away, or keep the cursor out of the way while you play.

<p align="center">
  <a href="https://youtu.be/eUiiTkVZzLQ">
    <img src="Thumbnail.png" width="520" alt="ZenHide showcase video">
  </a>
  <br>
  <i>Click the image to watch the showcase.</i>
</p>

## Features

- **Auto-hide when idle:** hides the cursor and desktop icons after a set idle time, and shows them again when you move the mouse
- **Real-movement mode:** ignores apps and games that move the cursor on their own
- **Stays out of your way:** icons don't hide while you're typing or renaming a desktop item
- **Hotkey:** hide or show on demand (default `Ctrl+Alt+Shift+H`), with an optional "stay hidden" mode
- **Taskbar fix:** re-hides an auto-hide taskbar that Windows leaves open (multi-monitor aware)
- **Tray icon:** double-click it, or right-click and choose **Settings**
- **Start with Windows:** optional, with or without admin rights

## Download

Grab `ZenHide.exe` from the [latest release](../../releases/latest) and run it. No install needed.

**Prefer to run the source?** Download it, install [AutoHotkey v1.1](https://www.autohotkey.com/) and run `ZenHide.ahk`.

On first run it asks whether to start with Windows and whether to show the tray icon, then creates its settings in `Core\config\ZenHide.ini` next to the program. Put it in its own folder.

## Settings

Double-click the tray icon, or right-click it and choose **Settings**. Changes apply when you save (the program restarts itself).

You can also edit `Core\config\ZenHide.ini` directly. Each setting has a comment explaining it, but this needs a manual restart (tray menu, **Restart**).

| Section | What it controls |
|---|---|
| General | Start with Windows, tray icon |
| Idle | What to hide, and after how long |
| Taskbar Fix | Re-hide a stuck auto-hide taskbar |
| Hotkeys | Hide/show hotkey, stay-hidden mode |
| Advanced | Admin startup, check intervals |

## Notes

- **Taskbar fix:** it only makes sense if Windows' "Automatically hide the taskbar" setting is on. If you don't use auto-hide, turn the fix off in Settings, because it moves the mouse away from the taskbar to make it hide.
- Taskbars docked to the top, left or right may not always re-hide (a Windows quirk).
- Antivirus tools sometimes flag compiled AutoHotkey programs. The full source code is here to check.

## License

[MIT](LICENSE)

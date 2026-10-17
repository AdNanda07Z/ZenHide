;@Ahk2Exe-SetMainIcon Core\assets\ZenHide\Image.ico
;@Ahk2Exe-SetName ZenHide
;@Ahk2Exe-SetDescription ZenHide
;@Ahk2Exe-SetVersion 1.0.0
appName    := "ZenHide"
appVersion := "1.0"

; ══════════════════════════════════════════════════════════════════════════
;  CORE
; ══════════════════════════════════════════════════════════════════════════

#NoEnv
#SingleInstance Force
#Persistent
#NoTrayIcon
#InstallKeybdHook   ; typing counts as activity (A_TimeIdleKeyboard)
SetWorkingDir %A_ScriptDir%

; Per-monitor DPI awareness: accurate mouse coordinates across monitors with different scaling.
DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")

; ── Bootstrap ─────────────────────────────────────────────────────────────

; Shared GUI state (declared up here because the first-run prompt runs before the Toolkit).
global g_FirstRunStartup := 1
global g_FirstRunTray    := 1
global g_FirstRunCtl     := {}   ; control handles (v-variables can't be used inside functions)
global g_SettingsCtl     := {}   ; schema id -> control handle
global g_SettingsHwnd    := 0    ; the open Settings window
global g_HotkeyVal       := {}   ; schema id -> hotkey text currently chosen in the window
global g_Muted           := {}   ; handles of grey hint texts
global g_HkHook          := ""   ; active hotkey-capture hook
global g_HkBtn           := 0    ; button being captured

core := A_ScriptDir . "\Core"
if !FileExist(core)
    FileCreateDir, %core%
if !FileExist(core . "\config")
    FileCreateDir, %core%\config

iniPath  := core . "\config\" . appName . ".ini"
iconPath := core . "\assets\" . appName . "\Image.ico"

; ── Load settings ─────────────────────────────────────────────────────────

g_IniPath := iniPath
g_Schema  := ParseSchema(AppSchema())

; Load + validate. Invalid values fall back to defaults with a tray warning.
badKeys    := ""
needPrompt := false
if !FileExist(iniPath)
{
    cfg := DefaultConfig(g_Schema)
    needPrompt := true
}
else
    cfg := LoadConfig(iniPath, g_Schema, badKeys, needPrompt)

; First run, or a missing/blank [General] value: ask, then (re)write the ini.
; Closing the prompt without Save exits the script entirely.
if (needPrompt)
{
    startupChoice := cfg.startOnBoot
    trayChoice    := cfg.trayIconOn
    ShowFirstRunPrompt(startupChoice, trayChoice)
    cfg.startOnBoot := startupChoice
    cfg.trayIconOn  := trayChoice
    if !WriteIni(iniPath, g_Schema, cfg)
        MsgBox, 16, Setup Error, % "Couldn't write the config file to:`n" . iniPath . "`n`nSettings won't be saved between launches until this is fixed."
}

; Every setting becomes a plain global named after its schema Variable.
for i, s in g_Schema
{
    varName := s.id
    %varName% := cfg[varName]
}

if (badKeys != "")
    TrayTip, Config warning, % "Invalid value(s) in " . appName . ".ini, using defaults instead:`n" . badKeys, 5

; ── Tray and startup ──────────────────────────────────────────────────────

ApplyTrayIcon(trayIconOn)   ; the icon comes from the exe or Core\assets; this sets visibility
ApplyStartupPreference(startOnBoot, adminStartup)   ; re-checked every launch, so a moved program fixes itself

; ── Run the app ───────────────────────────────────────────────────────────

Gosub, AppStart
return

; ── Handlers ──────────────────────────────────────────────────────────────

FirstRunOK:
    h1 := g_FirstRunCtl.startup, h2 := g_FirstRunCtl.tray
    ControlGet, g_FirstRunStartup, Checked, , , ahk_id %h1%
    ControlGet, g_FirstRunTray,    Checked, , , ahk_id %h2%
    Gui, FirstRun:Destroy
return

FirstRunGuiClose:
FirstRunGuiEscape:
    ; Closing without saving = don't run at all this time.
    Gui, FirstRun:Destroy
    ExitApp
return

OpenSettings:
    ShowSettings()
return

SettingsSave:
    SettingsApply()
return

HotkeyCapture:
    MouseGetPos, , , , hClicked, 2
    StartHotkeyCapture(hClicked)
return

SettingsDefaults:
    RestoreDefaults()
return

SettingsCancel:
SettingsGuiClose:
SettingsGuiEscape:
    StopHotkeyCapture()
    Gui, Settings:Destroy
return

RestartScript:
    Reload
return

ExitScript:
    ExitApp
return

; ── Settings engine (ini and schema) ──────────────────────────────────────

; Schema text -> list of {sec, key, id, type, def, label, hint}.
ParseSchema(text) {
    items := []
    Loop, Parse, text, `n, `r
    {
        if (Trim(A_LoopField) = "")
            continue
        p := StrSplit(A_LoopField, "|")
        items.Push({sec: p[1], key: p[2], id: p[3], type: p[4], def: p[5], label: p[6], hint: p[7]})
    }
    return items
}

SchemaItem(id) {
    global g_Schema
    for i, s in g_Schema
        if (s.id = id)
            return s
}

; Ini comment text: same words as the window (label + unit/hint in brackets).
IniComment(s) {
    notes := ""
    if (s.type = "secs" || s.type = "ms")
        notes := "1000 = 1 second"
    if (s.hint != "")
        notes .= (notes = "" ? "" : "; ") . s.hint
    return s.label . (notes = "" ? "" : " (" . notes . ")")
}

; Ini text -> internal value (bool -> 1/0, numbers -> numbers, hotkey stays text).
ToInternal(s, text) {
    if (s.type = "bool")
        return (text = "true") ? 1 : 0
    if (s.type = "hotkey")
        return text
    return text + 0
}

DefaultConfig(schema) {
    cfg := {}
    for i, s in schema
        cfg[s.id] := ToInternal(s, s.def)
    return cfg
}

; Reads + validates every schema key. A missing/blank [General] key sets
; needPrompt (the first-run questions live there); anything else missing
; just uses its default silently.
LoadConfig(iniPath, schema, ByRef badKeys, ByRef needPrompt) {
    cfg := {}
    needPrompt := false
    for i, s in schema
    {
        IniRead, raw, %iniPath%, % s.sec, % s.key, __missing__
        raw := Trim(raw)
        keyName := s.sec . "/" . s.key
        fallback := ToInternal(s, s.def)

        if (raw = "__missing__" || (raw = "" && s.sec = "General"))
        {
            cfg[s.id] := fallback
            if (s.sec = "General")
                needPrompt := true
        }
        else if (s.type = "bool")
            cfg[s.id] := ValidateBool(raw, fallback, keyName, badKeys)
        else if (s.type = "hotkey")
            cfg[s.id] := raw
        else
            cfg[s.id] := ValidateNum(raw, fallback, keyName, badKeys)
    }
    return cfg
}

; Writes the whole ini from the schema (comments, order and spacing included).
; Written to a temp file first so a failed write never leaves half an ini.
WriteIni(iniPath, schema, cfg) {
    text := "; Note: All settings below require relaunching to take effect.`n"
    lastSec := ""
    for i, s in schema
    {
        if (s.sec != lastSec)
        {
            text .= (lastSec = "" ? "`n" : "`n`n") . "[" . s.sec . "]`n"
            lastSec := s.sec
        }
        v := cfg[s.id]
        if (s.type = "bool")
            v := v ? "true" : "false"
        text .= "`n; " . IniComment(s) . " | Default: " . s.def . "`n" . s.key . " = " . v . "`n"
    }

    tmp := iniPath . ".tmp"
    FileDelete, %tmp%
    FileAppend, %text%, %tmp%
    if (ErrorLevel)
        return false
    FileMove, %tmp%, %iniPath%, 1
    return !ErrorLevel
}

; Valid positive number, else fallback + record in badKeys.
ValidateNum(value, fallback, keyName, ByRef badKeys) {
    if (value is not number) or (value <= 0)
    {
        badKeys .= (badKeys = "" ? "" : "`n") . keyName . " (was: " . value . ")"
        return fallback
    }
    return value
}

; Same idea, for true/false toggles. Returns 1/0 for internal use.
ValidateBool(value, fallback, keyName, ByRef badKeys) {
    trimmed := Trim(value)
    StringLower, valLower, trimmed
    if (valLower = "true")
        return 1
    if (valLower = "false")
        return 0
    badKeys .= (badKeys = "" ? "" : "`n") . keyName . " (was: " . value . ")"
    return fallback ? 1 : 0
}

; Translates a human-friendly hotkey string ("Ctrl+Alt+Shift+H") into AHK's own
; symbol syntax ("^!h"). Unrecognized parts pass through unchanged - that's
; expected to be the actual key itself (letter, F-key, etc).
TranslateHotkeyString(userStr) {
    parts := StrSplit(userStr, "+")
    ahkStr := ""
    for index, part in parts
    {
        p := Trim(part)
        StringLower, pLower, p
        if (pLower = "ctrl")
            ahkStr .= "^"
        else if (pLower = "alt")
            ahkStr .= "!"
        else if (pLower = "shift")
            ahkStr .= "+"
        else if (pLower = "win")
            ahkStr .= "#"
        else
            ahkStr .= p
    }
    return ahkStr
}

; Side-effect-free hotkey check: the key part must be a real key name.
CheckHotkey(combo) {
    key := RegExReplace(TranslateHotkeyString(combo), "^[\^!+#<>*~$]+")
    return (key != "" && (GetKeyVK(key) || GetKeySC(key))) ? true : false
}

; Seconds text for a millisecond value ("10000" -> "10", "1500" -> "1.5").
FormatSecs(ms) {
    return RTrim(RTrim(Round(ms / 1000, 3), "0"), ".")
}

; ── Dark theme (shared by every window below) ─────────────────────────────

WM_CTLCOLOREDIT(wParam, lParam) {
    static hBr := 0
    if !hBr
        hBr := DllCall("CreateSolidBrush", "UInt", 0x505050, "Ptr")
    DllCall("SetBkColor",   "Ptr", wParam, "UInt", 0x505050)
    DllCall("SetTextColor", "Ptr", wParam, "UInt", 0xE8E8E8)
    return hBr
}

WM_CTLCOLORSTATIC(wParam, lParam) {
    global g_Muted
    static hBr := 0
    if !hBr
        hBr := DllCall("CreateSolidBrush", "UInt", 0x404040, "Ptr")
    DllCall("SetBkColor",   "Ptr", wParam, "UInt", 0x404040)
    DllCall("SetTextColor", "Ptr", wParam, "UInt", g_Muted.HasKey(lParam) ? 0xA8A8A8 : 0xE8E8E8)
    return hBr
}

; OnMessage must be registered from inside a function (bare calls past the
; auto-execute section are never reached in AHK v1).
DarkModeInit() {
    static done := false
    if (done)
        return
    done := true
    OnMessage(0x0133, "WM_CTLCOLOREDIT")
    OnMessage(0x0138, "WM_CTLCOLORSTATIC")
}

; Call after Gui Show: dark title bar, native dark buttons, themeless
; edits/checkboxes so the WM_CTLCOLOR handlers above can paint them.
DarkModeApply(guiHwnd) {
    v := 1
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiHwnd, "UInt", 20, "Int*", v, "UInt", 4)

    hChild := 0
    Loop {
        hChild := DllCall("FindWindowEx", "Ptr", guiHwnd, "Ptr", hChild, "Ptr", 0, "Ptr", 0, "Ptr")
        if !hChild
            break
        VarSetCapacity(cls, 64, 0)
        DllCall("GetClassName", "Ptr", hChild, "Str", cls, "Int", 32)
        if (cls = "Button") {
            style   := DllCall("GetWindowLong", "Ptr", hChild, "Int", -16, "UInt")
            btnType := style & 0xF
            if (btnType = 0 || btnType = 1)
                DllCall("uxtheme\SetWindowTheme", "Ptr", hChild, "WStr", "DarkMode_Explorer", "Ptr", 0)
            else
                DllCall("uxtheme\SetWindowTheme", "Ptr", hChild, "WStr", " ", "WStr", " ")
        } else {
            DllCall("uxtheme\SetWindowTheme", "Ptr", hChild, "WStr", " ", "WStr", " ")
        }
        DllCall("InvalidateRect", "Ptr", hChild, "Ptr", 0, "Int", 1)
    }
}

; Dark tray/context menus via undocumented uxtheme ordinals (135 = set app
; mode, 136 = flush). Missing on old Windows builds - then menus stay light.
DarkMenus() {
    hMod := DllCall("LoadLibrary", "str", "uxtheme.dll", "ptr")
    pSetMode := DllCall("GetProcAddress", "ptr", hMod, "ptr", 135, "ptr")
    pFlush   := DllCall("GetProcAddress", "ptr", hMod, "ptr", 136, "ptr")
    if (pSetMode)
        DllCall(pSetMode, "int", 2)   ; 2 = always dark, 1 = follow Windows
    if (pFlush)
        DllCall(pFlush)
}

; ── DPI ───────────────────────────────────────────────────────────────────

; The script itself is per-monitor DPI aware (accurate mouse coordinates), but
; AHK v1 GUIs can't re-layout when dragged to a monitor with another scale
; (contents get cropped). So windows are created system-DPI aware: crisp and
; normal-sized on the main monitor, and Windows just stretches them on others.
GuiDpiUnaware() {
    return DllCall("SetThreadDpiAwarenessContext", "ptr", -2, "ptr")   ; -2 = system aware
}

GuiDpiRestore(prev) {
    DllCall("SetThreadDpiAwarenessContext", "ptr", prev, "ptr")
}

; ── Window rows (shared by the first-run prompt and Settings) ─────────────

; Rows sit on a 32px grid (24px control); a hint line adds 18px. cx is the
; column's left edge. Each function returns the y of the next row.
GuiHint(g, cx, yy, hint) {
    global g_Muted
    if (hint = "")
        return yy + 32
    Gui, %g%:Font, s9 Norm cE8E8E8
    Gui, %g%:Add, Text, % "x" . (cx + 24) . " y" . (yy + 25) . " w356 h15 HwndhTmp", % hint
    Gui, %g%:Font, s10 Norm cE8E8E8
    g_Muted[hTmp + 0] := 1
    return yy + 50
}

GuiRowCheck(g, cx, yy, text, hint, checked, ByRef hOut) {
    Gui, %g%:Add, CheckBox, % "x" . cx . " y" . yy . " w380 h24 HwndhTmp Checked" . checked, % text
    hOut := hTmp
    return GuiHint(g, cx, yy, hint)
}

; Label on the left, edit box (or a button for hotkeys) on the right.
GuiRowInput(g, cx, yy, text, hint, initial, isButton, ByRef hOut) {
    Gui, %g%:Add, Text, % "x" . cx . " y" . yy . " w250 h24 0x200", % text
    if (isButton)
        Gui, %g%:Add, Button, % "x" . (cx + 260) . " y" . yy . " w120 h24 HwndhTmp gHotkeyCapture", % initial
    else
        Gui, %g%:Add, Edit, % "x" . (cx + 260) . " y" . yy . " w120 h24 HwndhTmp", % initial
    hOut := hTmp
    return GuiHint(g, cx, yy, hint)
}

GuiNote(g, cx, yy, text, lines, w) {
    global g_Muted
    Gui, %g%:Font, s9 Norm cE8E8E8
    Gui, %g%:Add, Text, % "x" . cx . " y" . yy . " w" . w . " h" . (lines * 17) . " HwndhTmp", % text
    Gui, %g%:Font, s10 Norm cE8E8E8
    g_Muted[hTmp + 0] := 1
    return yy + lines * 17 + 14
}

GuiHeading(g, cx, yy, text) {
    Gui, %g%:Font, s10 Bold cE8E8E8
    Gui, %g%:Add, Text, % "x" . cx . " y" . yy . " w380 h24 0x200", % text
    Gui, %g%:Font, s10 Norm cE8E8E8
    return yy + 32
}

; ── First-run prompt ──────────────────────────────────────────────────────

; Labels can't live inside AHK v1 functions - the button/close handlers
; live down in the Handlers section instead, so nothing here accidentally
; falls into a label's body during normal top-to-bottom execution.
ShowFirstRunPrompt(ByRef startupChoice, ByRef trayChoice) {
    global g_FirstRunStartup, g_FirstRunTray, g_FirstRunCtl, appName
    g_FirstRunStartup := startupChoice
    g_FirstRunTray    := trayChoice
    DarkModeInit()

    sItem := SchemaItem("startOnBoot")
    tItem := SchemaItem("trayIconOn")

    prevDpi := GuiDpiUnaware()
    Gui, FirstRun:New, +AlwaysOnTop
    Gui, FirstRun:Margin, 16, 14
    Gui, FirstRun:Color, 404040
    Gui, FirstRun:Font, s10 cE8E8E8, Segoe UI

    yy := GuiHeading("FirstRun", 16, 14, "First-Time Setup")
    yy := GuiRowCheck("FirstRun", 16, yy, sItem.label, sItem.hint, startupChoice, h1)
    yy := GuiRowCheck("FirstRun", 16, yy, tItem.label, tItem.hint, trayChoice, h2)
    g_FirstRunCtl := {startup: h1, tray: h2}
    yy := GuiNote("FirstRun", 16, yy + 16, "These settings can be changed later from the tray menu or the .ini file.", 1, 380) - 4   ; sits close to Save
    Gui, FirstRun:Add, Button, % "gFirstRunOK Default w110 h32 xm y" . yy, Save
    Gui, FirstRun:Show, AutoSize, %appName%
    Gui, FirstRun:+LastFound
    hPrompt := WinExist()
    DarkModeApply(hPrompt)
    GuiDpiRestore(prevDpi)

    ; Wait on this exact window - a title match (mode 2 = "contains") would also wait
    ; on any editor/Explorer window with the script's name in its title, and hang here.
    WinWaitClose, ahk_id %hPrompt%
    startupChoice := g_FirstRunStartup
    trayChoice    := g_FirstRunTray
}

; ── Hotkey capture ────────────────────────────────────────────────────────

; Click the hotkey button, press the keys. Esc cancels, 6s timeout. Script
; hotkeys are suspended meanwhile so the current combo can be pressed again.
StartHotkeyCapture(hBtn) {
    global g_HkHook, g_HkBtn
    if (HotkeyIdOf(hBtn) = "")
        return
    if (!IsFunc("InputHook"))
    {
        MsgBox, 48, Settings, Hotkey capture needs AutoHotkey 1.1.28 or newer.
        return
    }
    if (IsObject(g_HkHook))
    {
        g_HkHook.Stop()   ; clicking again cancels
        return
    }
    g_HkBtn := hBtn
    ControlSetText, , Press keys..., ahk_id %hBtn%
    ih := InputHook("T6")
    ih.KeyOpt("{All}", "NS")
    ih.KeyOpt("{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}", "-S")   ; never swallow plain modifiers
    ih.OnKeyDown := Func("HotkeyCaptureDown")
    ih.OnEnd     := Func("HotkeyCaptureEnd")
    g_HkHook := ih
    Suspend, On
    ih.Start()
}

StopHotkeyCapture() {
    global g_HkHook
    if (IsObject(g_HkHook))
        g_HkHook.Stop()
}

HotkeyIdOf(hBtn) {
    global g_SettingsCtl
    for id, h in g_SettingsCtl
        if (h = hBtn)
            return id
    return ""
}

HotkeyCaptureDown(ih, vk, sc) {
    global g_HkBtn, g_HotkeyVal
    name := GetKeyName(Format("vk{:02x}sc{:03x}", vk, sc))
    mods := (GetKeyState("Ctrl", "P") ? "Ctrl+" : "") . (GetKeyState("Alt", "P") ? "Alt+" : "")
          . (GetKeyState("Shift", "P") ? "Shift+" : "") . ((GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) ? "Win+" : "")

    if RegExMatch(name, "i)^[LR]?(Control|Ctrl|Alt|Shift|Win)$")
    {
        shown := (mods = "") ? "Press keys..." : mods . "..."
        ControlSetText, , %shown%, ahk_id %g_HkBtn%
        return
    }
    if (name = "Escape")
    {
        ih.Stop()
        return
    }
    if (StrLen(name) = 1)
        StringUpper, name, name
    if (mods = "" && !RegExMatch(name, "^F\d+$"))   ; a bare letter would hijack typing - only F-keys may stand alone
    {
        ControlSetText, , Add a modifier, ahk_id %g_HkBtn%
        return
    }
    g_HotkeyVal[HotkeyIdOf(g_HkBtn)] := mods . name
    ih.Stop()
}

; Runs however capture ended (key, Esc, timeout, Stop): restore the button text.
HotkeyCaptureEnd(ih) {
    global g_HkHook, g_HkBtn, g_HotkeyVal
    shown := g_HotkeyVal[HotkeyIdOf(g_HkBtn)]
    ControlSetText, , %shown%, ahk_id %g_HkBtn%
    g_HkHook := ""
    Suspend, Off
}

; ── Settings window ───────────────────────────────────────────────────────

; Builds the window from the schema, filled with what the ini holds now.
ShowSettings() {
    global g_Schema, g_IniPath, g_SettingsCtl, g_HotkeyVal, g_SettingsHwnd, appName, appVersion
    title := appName . " Settings"
    if (g_SettingsHwnd && WinExist("ahk_id " . g_SettingsHwnd))
    {
        WinActivate
        return
    }
    DarkModeInit()

    ignoredBad := "", ignoredPrompt := false
    cfg := LoadConfig(g_IniPath, g_Schema, ignoredBad, ignoredPrompt)

    g_SettingsCtl := {}
    g_HotkeyVal   := {}
    prevDpi := GuiDpiUnaware()
    Gui, Settings:Destroy
    Gui, Settings:New, +OwnDialogs
    Gui, Settings:Margin, 16, 14
    Gui, Settings:Color, 404040
    Gui, Settings:Font, s10 cE8E8E8, Segoe UI

    ; Split the sections into two columns of about equal height.
    heights := [], names := [], total := 0
    for i, s in g_Schema
    {
        if (s.sec != names[names.MaxIndex()])
        {
            names.Push(s.sec)
            heights.Push(42)
        }
        heights[heights.MaxIndex()] += (s.hint != "") ? 50 : 32
        total += (s.hint != "") ? 50 : 32
    }
    secCount := names.MaxIndex()
    total += secCount * 42
    splitAt := secCount, bestDiff := 999999, left := 0
    Loop, % secCount - 1
    {
        left += heights[A_Index]
        if (Abs(total - 2 * left) < bestDiff)
        {
            bestDiff := Abs(total - 2 * left)
            splitAt := A_Index
        }
    }

    cx := 16, yy := 14, yyMax := 14, secIdx := 0, lastSec := ""
    for i, s in g_Schema
    {
        if (s.sec != lastSec)
        {
            secIdx++
            if (secIdx = splitAt + 1)
            {
                yyMax := Max(yyMax, yy)
                cx := 16 + 380 + 32
                yy := 14
            }
            else if (lastSec != "")
                yy += 10
            yy := GuiHeading("Settings", cx, yy, s.sec)
            lastSec := s.sec
        }
        v := cfg[s.id]
        if (s.type = "bool")
            yy := GuiRowCheck("Settings", cx, yy, s.label, s.hint, v, h)
        else
        {
            text := s.label
            if (s.type = "secs")
            {
                v := FormatSecs(v)
                text .= " (seconds)"
            }
            else if (s.type = "ms")
                text .= " (ms)"
            else if (s.type = "hotkey")
                g_HotkeyVal[s.id] := v
            yy := GuiRowInput("Settings", cx, yy, text, s.hint, v, s.type = "hotkey", h)
        }
        g_SettingsCtl[s.id] := h
    }
    yyMax := Max(yyMax, yy)

    totalW := (splitAt < secCount) ? 380 + 32 + 380 : 380
    yy := yyMax + 8
    Gui, Settings:Add, Button, % "xm w100 h32 Default gSettingsSave y" . yy, Save
    Gui, Settings:Add, Button, x+10 yp w100 h32 gSettingsCancel, Cancel
    Gui, Settings:Add, Button, % "x" . (16 + totalW - 160) . " y" . yy . " w160 h32 gSettingsDefaults", Restore defaults
    GuiNote("Settings", 16, yy + 32 + 8, appName . " v" . appVersion, 1, 300)
    Gui, Settings:Show, AutoSize, %title%
    Gui, Settings:+LastFound
    g_SettingsHwnd := WinExist()
    DarkModeApply(g_SettingsHwnd)
    GuiDpiRestore(prevDpi)
}

; Validates the window, rewrites the ini, relaunches. Stays open on any problem.
SettingsApply() {
    global g_Schema, g_IniPath, g_SettingsCtl, g_HotkeyVal
    Gui, Settings:+OwnDialogs
    StopHotkeyCapture()

    cfg := {}
    problems := ""
    for i, s in g_Schema
    {
        hCtl := g_SettingsCtl[s.id]
        if (s.type = "bool")
        {
            ControlGet, val, Checked, , , ahk_id %hCtl%
            cfg[s.id] := val ? 1 : 0
        }
        else if (s.type = "hotkey")
        {
            val := g_HotkeyVal[s.id]
            if !CheckHotkey(val)
                problems .= "`n- " . s.label . " (not a valid hotkey)"
            cfg[s.id] := val
        }
        else
        {
            ControlGetText, val, , ahk_id %hCtl%
            val := StrReplace(Trim(val), ",", ".")
            if val is not number
                problems .= "`n- " . s.label . " (needs a number)"
            else
            {
                n := (s.type = "secs") ? Round(val * 1000) : Round(val)
                if (n <= 0)
                    problems .= "`n- " . s.label . " (must be above 0)"
                cfg[s.id] := n
            }
        }
    }

    if (problems != "")
    {
        MsgBox, 48, Settings, % "Please fix:" . problems
        return
    }
    if !WriteIni(g_IniPath, g_Schema, cfg)
    {
        MsgBox, 16, Settings, % "Couldn't write the config file to:`n" . g_IniPath
        return
    }
    Reload
    Sleep, 2000
}

; Puts every schema default into the window. Nothing is saved until Save.
RestoreDefaults() {
    global g_Schema, g_SettingsCtl, g_HotkeyVal
    StopHotkeyCapture()
    for i, s in g_Schema
    {
        h := g_SettingsCtl[s.id]
        v := ToInternal(s, s.def)
        if (s.type = "bool")
        {
            if (v)
                Control, Check, , , ahk_id %h%
            else
                Control, Uncheck, , , ahk_id %h%
        }
        else
        {
            if (s.type = "secs")
                v := FormatSecs(v)
            else if (s.type = "hotkey")
                g_HotkeyVal[s.id] := v
            ControlSetText, , %v%, ahk_id %h%
        }
    }
}

; Tray menu: icon visibility + Settings / Restart / Exit (no default AHK items).
ApplyTrayIcon(showIcon) {
    global appName, iconPath, appVersion
    DarkMenus()

    ; Script users get the icon from Core\assets (a compiled exe carries its own).
    if (!A_IsCompiled && FileExist(iconPath))
        Menu, Tray, Icon, %iconPath%

    if (showIcon)
        Menu, Tray, Icon
    else
        Menu, Tray, NoIcon

    Menu, Tray, NoStandard
    Menu, Tray, Tip, %appName% v%appVersion%
    Menu, Tray, Add, Settings, OpenSettings
    Menu, Tray, Default, Settings
    Menu, Tray, Add, Restart, RestartScript
    Menu, Tray, Add, Exit, ExitScript
}

; ── Startup ───────────────────────────────────────────────────────────────

; Self-heals startup every launch (handles the script having been moved,
; and ini/reality mismatches). Normal mode uses a Startup-folder shortcut;
; admin mode uses a Task Scheduler task instead - only one is ever active.
ApplyStartupPreference(shouldStart, useAdmin) {
    global appName
    shortcutPath := A_Startup . "\" . appName . ".lnk"
    currentTarget := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    currentArgs := A_IsCompiled ? "" : """" . A_ScriptFullPath . """"

    if (shouldStart && !useAdmin)
    {
        needsCreate := true
        if FileExist(shortcutPath)
        {
            FileGetShortcut, %shortcutPath%, existingTarget, , existingArgs
            if (existingTarget = currentTarget && existingArgs = currentArgs)
                needsCreate := false
        }
        if (needsCreate)
            FileCreateShortcut, %currentTarget%, %shortcutPath%, %A_ScriptDir%, %currentArgs%
    }
    else
    {
        if FileExist(shortcutPath)
            FileDelete, %shortcutPath%
    }

    taskName := appName . " Startup"
    state := StartupTaskState(taskName)
    if (shouldStart && useAdmin)
    {
        if (state != "ok")
            CreateStartupTask(taskName)
    }
    else if (state != "missing")
        DeleteStartupTask(taskName)
}

; "missing", "stale" (points at a different script path), or "ok".
StartupTaskState(taskName) {
    try
    {
        svc := ComObjCreate("Schedule.Service")
        svc.Connect()
        action := svc.GetFolder("\").GetTask(taskName).Definition.Actions.Item(1)
        return InStr(action.Path . " " . action.Arguments, A_ScriptFullPath) ? "ok" : "stale"
    }
    catch
    {
        return "missing"
    }
}

; Registered from XML rather than plain schtasks switches: those defaults
; would kill the script after 72h and refuse to start it on battery.
CreateStartupTask(taskName) {
    cmdPath := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    cmdArgs := A_IsCompiled ? "" : """" . A_ScriptFullPath . """"
    user := A_ComputerName . "\" . A_UserName

    xml := "<?xml version=""1.0"" encoding=""UTF-16""?>`n"
        . "<Task version=""1.2"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">`n"
        . "<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" . XmlEsc(user) . "</UserId></LogonTrigger></Triggers>`n"
        . "<Principals><Principal id=""Author""><UserId>" . XmlEsc(user) . "</UserId>"
        . "<LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>`n"
        . "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
        . "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>"
        . "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
        . "<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>`n"
        . "<Actions Context=""Author""><Exec><Command>" . XmlEsc(cmdPath) . "</Command>"
        . "<Arguments>" . XmlEsc(cmdArgs) . "</Arguments>"
        . "<WorkingDirectory>" . XmlEsc(A_ScriptDir) . "</WorkingDirectory></Exec></Actions>`n"
        . "</Task>"

    tmp := A_Temp . "\" . taskName . ".xml"
    FileDelete, %tmp%
    FileAppend, %xml%, %tmp%, UTF-16
    ok := RunSchtasks("/create /tn """ . taskName . """ /xml """ . tmp . """ /f")
    FileDelete, %tmp%

    if (!ok)
        TrayTip, Admin startup, Couldn't set up admin startup (permission declined or it failed). It will try again next launch., 5
}

DeleteStartupTask(taskName) {
    RunSchtasks("/delete /tn """ . taskName . """ /f")
}

; Runs schtasks elevated (UAC prompt) unless already admin. True on success.
RunSchtasks(params) {
    verb := A_IsAdmin ? "" : "*RunAs "
    RunWait, %verb%schtasks.exe %params%, , Hide UseErrorLevel
    return (ErrorLevel = 0)
}

XmlEsc(s) {
    return StrReplace(StrReplace(StrReplace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
}

; ══════════════════════════════════════════════════════════════════════════
;  APP
; ══════════════════════════════════════════════════════════════════════════

; ── Start ─────────────────────────────────────────────────────────────────

AppStart:
    ; Absolute screen coords - relative coords would make CheckIdle see false
    ; "movement" whenever the active window changes, moves, or resizes.
    CoordMode, Mouse, Screen

    lastX        := ""
    lastY        := ""
    lastMove     := A_TickCount
    cursorHidden := false
    iconsHidden  := false

    physTick        := 0   ; last real (hardware) mouse movement
    lastPhysSeen    := 0
    ignorePhysUntil := 0   ; our own scripted mouse moves are ignored until then

    ; Real movement comes from raw input (hardware reports). A game warping the
    ; cursor with SetCursorPos changes the position but sends none of these.
    if (physicalOnly)
    {
        VarSetCapacity(rid, 8 + A_PtrSize, 0)
        NumPut(1,     rid, 0, "UShort")        ; generic desktop controls
        NumPut(2,     rid, 2, "UShort")        ; mouse
        NumPut(0x100, rid, 4, "UInt")          ; RIDEV_INPUTSINK - also while another app is focused
        NumPut(A_ScriptHwnd, rid, 8, "Ptr")
        if (DllCall("RegisterRawInputDevices", "ptr", &rid, "uint", 1, "uint", 8 + A_PtrSize))
            OnMessage(0x00FF, "OnRawInput")    ; WM_INPUT
        else
        {
            physicalOnly := false
            TrayTip, Config warning, Couldn't read raw mouse input - PhysicalMovementOnly is off this run., 5
        }
    }

    SystemCursor("Init")
    if (hideCursor || hideIcons)
        SetTimer, CheckIdle, %pollRate%
    OnExit("RestoreOnExit")

    ; Other programs can ask for a brief cursor hide with this message, so only
    ; this one ever touches the system cursors.
    ;   wParam = 1 -> hide now, pause idle-checking | 0 -> resume normal behavior
    OnMessage(0x5555, "OnCursorControlRequest")

    ; A bad combo can throw at registration, so it falls back to the default.
    hidden := false
    if (hotkeysEnabled)
    {
        if !RegisterForceHideHotkey(hotkeyCombo)
        {
            defaultCombo := "Ctrl+Alt+Shift+H"
            if RegisterForceHideHotkey(defaultCombo)
                TrayTip, Config warning, % "Invalid hotkey in " . appName . ".ini (Hotkeys/ToggleHide: """ . hotkeyCombo . """), using default (" . defaultCombo . ") instead.", 5
            else
                TrayTip, Config warning, Force-hide hotkey could not be registered - feature disabled this run., 5
        }
    }

    if (taskbarEnabled)
        SetTimer, CheckActiveWindow, %tbCheckInterval%

    LastWin        := ""
    EmptyStartTime := 0
    LastMouseX     := ""
    LastMouseY     := ""
return

; ── Handlers ──────────────────────────────────────────────────────────────

ToggleHide:
    if (stayHidden)
    {
        ; Sticky mode - stays hidden regardless of movement until pressed again.
        hidden := !hidden
        if (hidden)
        {
            if (hideCursor && !cursorHidden) {
                SystemCursor("Off")
                cursorHidden := true
            }
            if (hideIcons && !iconsHidden) {
                SetDesktopIcons(false)
                iconsHidden := true
            }
        }
        else
        {
            if (cursorHidden) {
                SystemCursor("On")
                cursorHidden := false
            }
            if (iconsHidden) {
                SetDesktopIcons(true)
                iconsHidden := false
            }
            lastMove := A_TickCount   ; don't instantly re-trigger idle-hide on release
        }
    }
    else
    {
        ; Non-sticky - just flips current visibility once; normal idle
        ; logic (movement un-hides, inactivity re-hides) resumes right away.
        newHidden := !cursorHidden
        if (hideCursor) {
            SystemCursor(newHidden ? "Off" : "On")
            cursorHidden := newHidden
        }
        if (hideIcons) {
            SetDesktopIcons(!newHidden)
            iconsHidden := newHidden
        }
        lastMove := A_TickCount
    }
return

; Runs the idle check right away (used when real mouse input arrives while hidden).
WakeCheck:
    Gosub, CheckIdle
return

CheckIdle:
    ; Force-hide (via hotkey) overrides normal idle behavior entirely -
    ; stays hidden regardless of movement until toggled off again.
    if (hidden)
        return

    MouseGetPos, currX, currY
    posMoved := (currX != lastX || currY != lastY)
    lastX := currX
    lastY := currY

    physMoved := (physTick != lastPhysSeen)
    lastPhysSeen := physTick

    ; Raw input never reaches us while an elevated window has focus (and we
    ; aren't elevated), so there fall back to plain position tracking.
    moved := (physicalOnly && !ForegroundIsElevated()) ? physMoved : posMoved

    if (moved) {
        lastMove := A_TickCount

        if (hideCursor && cursorHidden) {
            SystemCursor("On")
            cursorHidden := false
        }
        if (hideIcons && iconsHidden) {
            SetDesktopIcons(true)
            iconsHidden := false
        }
    } else {
        ; Typing counts as activity too, and icons never hide mid-rename.
        elapsed := Min(A_TickCount - lastMove, A_TimeIdleKeyboard)
        if (hideCursor && !cursorHidden && elapsed > cursorIdleTime) {
            SystemCursor("Off")
            cursorHidden := true
        }
        if (hideIcons && !iconsHidden && elapsed > iconsIdleTime && !DesktopIsRenaming()) {
            SetDesktopIcons(false)
            iconsHidden := true
        }
    }
return

CheckActiveWindow:
    WinGetTitle, Title, A
    WinGet, ProcName, ProcessName, A
    CurrentWin := Title . "|" . ProcName

    if (CurrentWin != LastWin)
    {
        LastWin := CurrentWin
        EmptyStartTime := 0
        return
    }

    StringLower, procLower, ProcName
    if (procLower != "explorer.exe")
    {
        EmptyStartTime := 0
        return
    }

    if (Title != "")
    {
        EmptyStartTime := 0
        return
    }

    MouseGetPos, MouseX, MouseY

    if (LastMouseX = "")
    {
        LastMouseX := MouseX
        LastMouseY := MouseY
        EmptyStartTime := A_TickCount
        return
    }

    if (MouseX != LastMouseX || MouseY != LastMouseY)
    {
        LastMouseX := MouseX
        LastMouseY := MouseY
        EmptyStartTime := A_TickCount
        return
    }

    if (A_TickCount - EmptyStartTime >= tbIdleThreshold)
    {
        EmptyStartTime := A_TickCount   ; reset to "now", not 0 - 0 makes the next elapsed-time check huge

        ; Windows won't auto-hide the taskbar while it still has keyboard
        ; focus (e.g. after a click, or a closed app falling back to it).
        ; Fix: shift focus to the desktop icon view instead - Windows then
        ; re-evaluates and hides it on its own.
        ;
        ; Detection uses a padded rect, not exact bounds - Windows' own
        ; hover zone extends a bit past the taskbar window itself.
        margin := 20
        hitTaskbarHwnd := 0
        hitX := hitY := hitW := hitH := 0

        WinGetPos, tbX, tbY, tbW, tbH, ahk_class Shell_TrayWnd
        if (MouseX >= tbX - margin && MouseX <= tbX + tbW + margin
         && MouseY >= tbY - margin && MouseY <= tbY + tbH + margin)
        {
            hitTaskbarHwnd := WinExist("ahk_class Shell_TrayWnd")
            hitX := tbX, hitY := tbY, hitW := tbW, hitH := tbH
        }

        if (!hitTaskbarHwnd)   ; Shell_TrayWnd is primary-only - check every secondary monitor too
        {
            WinGet, secondaryList, List, ahk_class Shell_SecondaryTrayWnd
            Loop, %secondaryList%
            {
                thisHwnd := secondaryList%A_Index%
                WinGetPos, sX, sY, sW, sH, ahk_id %thisHwnd%
                if (MouseX >= sX - margin && MouseX <= sX + sW + margin
                 && MouseY >= sY - margin && MouseY <= sY + sH + margin)
                {
                    hitTaskbarHwnd := thisHwnd
                    hitX := sX, hitY := sY, hitW := sW, hitH := sH
                    break
                }
            }
        }

        if (hitTaskbarHwnd)
        {
            ; Mouse is on the taskbar - move to that monitor's center and
            ; leave it there (restoring to the original spot would just
            ; re-trigger the hover state). Critical/Try keep CheckIdle from
            ; misreading this move as real activity and guarantee Critical
            ; always turns back off even on error.
            Critical, On
            try
            {
                taskbarCenterX := hitX + hitW // 2
                taskbarCenterY := hitY + hitH // 2
                GetMonitorCenterForPoint(taskbarCenterX, taskbarCenterY, centerX, centerY)

                MouseMove, %centerX%, %centerY%, 0
                lastX := centerX, lastY := centerY, lastMove := A_TickCount, ignorePhysUntil := A_TickCount + 300

                StealFocusToDesktop()
                Click   ; real click on empty desktop - helps top/side-docked taskbars re-evaluate reliably
            }
            catch e
            {
                ToolTip, % "Taskbar-hide fix error: " . e.Message
                SetTimer, RemoveToolTip, -3000
            }
            Critical, Off
        }
        else
        {
            StealFocusToDesktop()
        }
    }
return

RemoveToolTip:
    ToolTip
return

; ── Functions ─────────────────────────────────────────────────────────────

; Every setting is defined once here; the ini, validation and Settings window all follow it.
; Columns: Section|Key|Variable|Type|Default|Label|Hint (ini comment = label + hint)
; Types: bool | secs (ini in ms, window in seconds) | ms | hotkey
AppSchema() {
    text =
(LTrim
General|StartOnBoot|startOnBoot|bool|true|Start automatically with Windows|Launches when your PC starts
General|TrayIcon|trayIconOn|bool|true|Show tray icon|Lets you open settings or exit from the tray menu
Idle|HideCursor|hideCursor|bool|true|Hide cursor when inactive|
Idle|HideIcons|hideIcons|bool|true|Hide desktop icons when inactive|
Idle|PhysicalMovementOnly|physicalOnly|bool|true|Show again only on real mouse movement|Ignores apps that move the cursor on their own
Idle|CursorIdleTime|cursorIdleTime|secs|20000|Hide cursor after|
Idle|IconsIdleTime|iconsIdleTime|secs|20000|Hide icons after|
Taskbar Fix|Enabled|taskbarEnabled|bool|true|Fix stuck auto-hide taskbar|Hides the taskbar again when Windows leaves it open
Taskbar Fix|IdleThreshold|tbIdleThreshold|secs|20000|Re-hide taskbar after|How long the mouse must stay still first
Hotkeys|Enabled|hotkeysEnabled|bool|true|Enable hotkey|
Hotkeys|ToggleHide|hotkeyCombo|hotkey|Ctrl+Alt+Shift+H|Hide/show hotkey|
Hotkeys|StayHidden|stayHidden|bool|false|Stay hidden until pressed again|Even after moving the mouse
Advanced|AdminStartup|adminStartup|bool|false|Start with admin rights|Uses Task Scheduler
Advanced|CursorCheckInterval|pollRate|ms|1000|Cursor check interval|Lower is more responsive
Advanced|TaskbarCheckInterval|tbCheckInterval|ms|1000|Taskbar check interval|Lower is more responsive
)
    return text
}

; Registers the dynamic hotkey; returns false if the combo string was invalid
; so the caller can fall back to the default instead.
RegisterForceHideHotkey(comboStr) {
    ahkCombo := TranslateHotkeyString(comboStr)
    try
    {
        Hotkey, %ahkCombo%, ToggleHide, On
        return true
    }
    catch e
    {
        return false
    }
}

OnCursorControlRequest(wParam, lParam, msg, hwnd) {
    global cursorHidden, lastMove, pollRate, hideCursor, hideIcons
    if (wParam = 1) {
        SetTimer, CheckIdle, Off
        if (!cursorHidden) {
            SystemCursor("Off")
            cursorHidden := true
        }
    } else {
        lastMove := A_TickCount   ; treat as "just moved" so it doesn't instantly re-hide
        if (cursorHidden) {
            SystemCursor("On")
            cursorHidden := false
        }
        if (hideCursor || hideIcons)
            SetTimer, CheckIdle, %pollRate%
    }
}

; Records real hardware mouse movement (WM_INPUT, mouse only).
OnRawInput(wParam, lParam) {
    global physTick, ignorePhysUntil, cursorHidden, iconsHidden
    if (A_TickCount < ignorePhysUntil)
        return
    hdr := 8 + 2 * A_PtrSize
    VarSetCapacity(buf, 64, 0)
    size := 64
    if (DllCall("GetRawInputData", "ptr", lParam, "uint", 0x10000003, "ptr", &buf, "uint*", size, "uint", hdr) = -1)
        return
    if (NumGet(buf, 0, "uint") != 0)   ; not RIM_TYPEMOUSE
        return
    if (NumGet(buf, hdr + 12, "int") != 0 || NumGet(buf, hdr + 16, "int") != 0)   ; lLastX / lLastY
    {
        physTick := A_TickCount
        if (cursorHidden || iconsHidden)
            SetTimer, WakeCheck, -1   ; show again now, don't wait for the next poll
    }
}

; True when the focused window is an elevated app and this script isn't.
; Windows (UIPI) sends no raw input to us there. Reads the process token's
; elevation flag; a token we can't read at all is treated as elevated too.
ForegroundIsElevated() {
    static lastPid := 0, lastResult := false
    if (A_IsAdmin)
        return false
    WinGet, pid, PID, A
    if (!pid)
        return false
    if (pid = lastPid)
        return lastResult
    lastPid := pid
    lastResult := true

    hProc := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")   ; QUERY_LIMITED_INFORMATION
    if (hProc)
    {
        if (DllCall("advapi32\OpenProcessToken", "ptr", hProc, "uint", 0x8, "ptr*", hTok))   ; TOKEN_QUERY
        {
            elevated := 0
            if (DllCall("advapi32\GetTokenInformation", "ptr", hTok, "int", 20, "uint*", elevated, "uint", 4, "uint*", retLen))   ; TokenElevation
                lastResult := (elevated != 0)
            DllCall("CloseHandle", "ptr", hTok)
        }
        DllCall("CloseHandle", "ptr", hProc)
    }
    return lastResult
}

; Never leave the system with a blanked cursor / hidden icons on exit.
RestoreOnExit(ExitReason, ExitCode) {
    global cursorHidden, iconsHidden
    if (cursorHidden)
        SystemCursor("On")
    if (iconsHidden)
        SetDesktopIcons(true)
}

SetDesktopIcons(show) {
    hwnd := 0
    WinGet, progman, ID, ahk_class Progman
    hwnd := FindDesktopListView(progman)

    if (!hwnd) {
        WinGet, workerList, List, ahk_class WorkerW
        Loop, %workerList% {
            hwnd := FindDesktopListView(workerList%A_Index%)
            if (hwnd)
                break
        }
    }

    if (!hwnd)
        return

    DllCall("ShowWindow", "ptr", hwnd, "int", show ? 5 : 0)   ; SW_SHOW : SW_HIDE
}

FindDesktopListView(parent) {
    ; "ptr" (not "uint") required so 64-bit handles aren't truncated
    hwnd := DllCall("FindWindowEx", "ptr", parent, "ptr", 0
                  , "str", "SHELLDLL_DefView", "ptr", 0, "ptr")
    if (hwnd)
        hwnd := DllCall("FindWindowEx", "ptr", hwnd, "ptr", 0
                      , "str", "SysListView32", "ptr", 0, "ptr")
    return hwnd
}

; True while a desktop icon label is being renamed (desktop is active and an edit box has focus).
DesktopIsRenaming() {
    WinGetClass, cls, A
    if (cls != "Progman" && cls != "WorkerW")
        return false
    ControlGetFocus, ctl, A
    return InStr(ctl, "Edit") ? true : false
}

; Shifts focus onto the desktop icon view (tries Progman, falls back to WorkerW).
StealFocusToDesktop() {
    hwnd := 0
    WinGet, progman, ID, ahk_class Progman
    hwnd := FindDesktopListView(progman)

    if (!hwnd) {
        WinGet, workerList, List, ahk_class WorkerW
        Loop, %workerList% {
            hwnd := FindDesktopListView(workerList%A_Index%)
            if (hwnd)
                break
        }
    }

    if (hwnd)
        DllCall("SetForegroundWindow", "ptr", hwnd)
}

; Center of whichever monitor contains the given point (SysGet Monitor -
; matches AHK's own mouse-coordinate space, unlike a raw GetMonitorInfo call).
GetMonitorCenterForPoint(px, py, ByRef outX, ByRef outY) {
    SysGet, monCount, MonitorCount
    Loop, %monCount%
    {
        SysGet, mon, Monitor, %A_Index%
        if (px >= monLeft && px <= monRight && py >= monTop && py <= monBottom)
        {
            outX := monLeft + (monRight - monLeft) // 2
            outY := monTop  + (monBottom - monTop)  // 2
            return
        }
    }
    outX := A_ScreenWidth  // 2
    outY := A_ScreenHeight // 2
}

; Cursor blanking (classic AHK snippet)
SystemCursor(OnOff=1) {
    static AndMask, XorMask, $, h_cursor
          ,c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13
          ,b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12,b13
          ,h1,h2,h3,h4,h5,h6,h7,h8,h9,h10,h11,h12,h13

    if (OnOff = "Init" or OnOff = "I" or $ = "") {
        $ := "h"
        VarSetCapacity(h_cursor, 4444, 1)
        VarSetCapacity(AndMask,  32*4, 0xFF)
        VarSetCapacity(XorMask,  32*4, 0)
        system_cursors := "32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650"
        StringSplit, c, system_cursors, `,
        Loop, %c0% {
            h_cursor   := DllCall("LoadCursor",  "ptr", 0, "ptr", c%A_Index%, "ptr")
            h%A_Index% := DllCall("CopyImage",   "ptr", h_cursor, "uint", 2, "int", 0, "int", 0, "uint", 0, "ptr")
            b%A_Index% := DllCall("CreateCursor","ptr", 0, "int", 0, "int", 0
                         , "int", 32, "int", 32, "ptr", &AndMask, "ptr", &XorMask, "ptr")
        }
        return
    }

    if (OnOff = 0 or OnOff = "Off"
        or ($ = "h" and (OnOff < 0 or OnOff = "Toggle" or OnOff = "T")))
        $ := "b"
    else
        $ := "h"

    Loop, %c0% {
        h_cursor := DllCall("CopyImage", "ptr", %$%%A_Index%, "uint", 2, "int", 0, "int", 0, "uint", 0, "ptr")
        DllCall("SetSystemCursor", "ptr", h_cursor, "uint", c%A_Index%)
    }
}

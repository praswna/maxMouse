/*  maxMouse - mouse gestures for 3ds Max
    --------------------------------------------------------------------------
    Hold the RIGHT (or MIDDLE) mouse button, drag a shape, release.
    The drag is reduced to a direction string (U/D/L/R, e.g. "DR" = down then
    right) and mapped to an action below.

    A plain click (no drag) is passed through untouched, so the normal
    right-click quad menu still works.

    Requires the companion file  MaxMouse_GestureHook.cs  sitting next to this
    script. To install/run: just evaluate this file (Scripting > Run Script,
    or drag it into a viewport). It compiles the hook and starts immediately,
    and also registers a macro "maxMouse Toggle" (category: maxMouse).
    --------------------------------------------------------------------------
*/

global maxMouse_hook
global maxMouse_asm
global maxMouse_map

-- ===========================================================================
--  ACTIONS  (edit / add your own here, then re-run the script)
-- ===========================================================================
fn mm_undo          = ( max undo )
fn mm_redo          = ( max redo )
fn mm_delete        = ( local s = getCurrentSelection(); if s.count > 0 do ( with undo "maxMouse Delete" on ( delete s ) ) )
fn mm_zoomExtSel    = ( max zoomext sel )
fn mm_zoomExtAllSel = ( max zoomext sel all )
fn mm_hideSel       = ( if selection.count > 0 do ( hide (getCurrentSelection()) ) )
fn mm_unhideAll     = ( max unhide all )
fn mm_toggleWire    = ( if (viewport.GetRenderLevel() == #wireframe) then viewport.SetRenderLevel #smoothhighlights else viewport.SetRenderLevel #wireframe; redrawViews() )
fn mm_toggleEdged   = ( viewport.setShowEdgeFaces (not (viewport.getShowEdgeFaces())); redrawViews() )
fn mm_viewTop       = ( viewport.setType #view_top;        redrawViews() )
fn mm_viewFront     = ( viewport.setType #view_front;      redrawViews() )
fn mm_viewPersp     = ( viewport.setType #view_persp_user; redrawViews() )
fn mm_isolate       = (
    -- Isolate Selection toggle. Macro name differs across versions, so try a
    -- few, then fall back to a quiet message.
    local ok = false
    try ( macros.run "Tools" "Macro_IsolateSelection"; ok = true ) catch ()
    if not ok do try ( macros.run "Tools" "IsolateSelection"; ok = true ) catch ()
    if not ok do format "maxMouse: Isolate Selection macro not found in this Max version.\n"
)

-- ===========================================================================
--  GESTURE MAP   #( button, gesture, label, action )
--    button : "R" (right)  |  "M" (middle)
--    gesture: direction string built from U / D / L / R
-- ===========================================================================
fn mm_buildMap = (
    maxMouse_map = #(
        --  RIGHT button -----------------------------------------------------
        #("R", "L",  "Undo",                mm_undo),
        #("R", "R",  "Redo",                mm_redo),
        #("R", "D",  "Delete Selection",    mm_delete),
        #("R", "U",  "Zoom Extents Sel",    mm_zoomExtSel),
        #("R", "UD", "Zoom Ext. All Sel",   mm_zoomExtAllSel),
        #("R", "DR", "Hide Selection",      mm_hideSel),
        #("R", "DL", "Unhide All",          mm_unhideAll),
        #("R", "UR", "Toggle Wireframe",    mm_toggleWire),
        #("R", "UL", "Toggle Edged Faces",  mm_toggleEdged),
        #("R", "LU", "View: Top",           mm_viewTop),
        #("R", "LD", "View: Front",         mm_viewFront),
        #("R", "RU", "View: Perspective",   mm_viewPersp),
        #("R", "RD", "Isolate Toggle",      mm_isolate),

        --  MIDDLE button ----------------------------------------------------
        --  NOTE: the middle button also pans the viewport in 3ds Max, so a
        --  middle-drag gesture will pan AND fire. Keep these few, or set
        --  EnableMiddle = false in maxMouse_start() to disable entirely.
        #("M", "L",  "Undo",                mm_undo),
        #("M", "R",  "Redo",                mm_redo),
        #("M", "U",  "Zoom Extents Sel",    mm_zoomExtSel),
        #("M", "D",  "Hide Selection",      mm_hideSel)
    )
)

-- ===========================================================================
--  GESTURE DISPATCH  (called from the .NET event)
-- ===========================================================================
fn mm_onGesture sender args = (
    local btn = args.Button
    local g   = args.Gesture
    local done = false
    for e in maxMouse_map while not done where (e[1] == btn and e[2] == g) do (
        done = true
        try ( e[4]() )
        catch ( format "maxMouse action error (% %): %\n" btn g (getCurrentException()) )
    )
    if not done do format "maxMouse: unmapped gesture %:%\n" btn g
)

-- ===========================================================================
--  COMPILE + START / STOP
-- ===========================================================================
fn mm_thisDir = (
    local p = undefined
    try ( p = getThisScriptFilename() ) catch ()
    if p == undefined do ( try ( p = getSourceFileName() ) catch () )
    if p == undefined do throw "maxMouse: cannot resolve script path; run via Scripting > Run Script."
    getFilenamePath p
)

fn mm_compile = (
    local csPath = (mm_thisDir()) + "MaxMouse_GestureHook.cs"
    if not (doesFileExist csPath) do throw ("maxMouse: companion file not found: " + csPath)

    local fs = openFile csPath mode:"r"
    local src = ""
    while not (eof fs) do src += (readLine fs) + "\n"
    close fs

    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.ReferencedAssemblies.Add "System.Drawing.dll"
    params.GenerateInMemory     = true
    params.GenerateExecutable   = false

    local res = prov.CompileAssemblyFromSource params #(src)
    if res.Errors.HasErrors do (
        local m = "maxMouse: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    maxMouse_asm = res.CompiledAssembly
)

fn maxMouse_start = (
    if maxMouse_hook != undefined and maxMouse_hook.IsRunning do (
        format "maxMouse: already running.\n"
        return false
    )
    mm_compile()
    mm_buildMap()

    local t = maxMouse_asm.GetType "MaxMouse.GestureHook"
    maxMouse_hook = (dotNetClass "System.Activator").CreateInstance t
    maxMouse_hook.EnableRight  = true
    maxMouse_hook.EnableMiddle = true     -- set false to ignore the middle button
    maxMouse_hook.MinDistance  = 18

    dotNet.addEventHandler maxMouse_hook "GestureRecognized" mm_onGesture
    maxMouse_hook.Start()

    -- make sure the global hook is removed when Max shuts down
    callbacks.removeScripts id:#maxMouse
    callbacks.addScript #preSystemShutdown "if (maxMouse_stop != undefined) do maxMouse_stop()" id:#maxMouse

    format "maxMouse: started (right + middle button gestures).\n"
    true
)

fn maxMouse_stop = (
    if maxMouse_hook != undefined do (
        try ( maxMouse_hook.Stop() ) catch ()
        maxMouse_hook = undefined
    )
    format "maxMouse: stopped.\n"
)

fn maxMouse_toggle = (
    if (maxMouse_hook != undefined and maxMouse_hook.IsRunning) then maxMouse_stop() else maxMouse_start()
)

-- ===========================================================================
--  TOOLBAR MACRO  (drag from Customize > Toolbars, category "maxMouse")
-- ===========================================================================
macroScript maxMouse_Toggle
    category:"maxMouse"
    buttontext:"maxMouse"
    tooltip:"Toggle maxMouse gestures on/off"
(
    on execute do ( if (maxMouse_toggle != undefined) do maxMouse_toggle() )
)

-- start now
try ( maxMouse_start() )
catch ( format "maxMouse: failed to start: %\n" (getCurrentException()) )

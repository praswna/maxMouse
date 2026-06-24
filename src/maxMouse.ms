/*  maxMouse - Maya-style mouse gestures for 3ds Max
    --------------------------------------------------------------------------
    RIGHT button : Maya-style MARKING MENU.
        Press & hold the right button; after a short delay a radial menu of 8
        items appears at the cursor. Flick toward a slice and release to run
        it. Flick fast (release before the menu appears) to run it without ever
        seeing the menu. A plain right-click (no movement) still opens the
        normal quad menu.

    MIDDLE button: screen-space VERTEX MOVE.
        When an Editable Poly / Editable Mesh is in Vertex sub-object level
        with a vertex selection, a middle-button drag moves the selected verts
        along the screen plane (the viewport does NOT pan). Otherwise the
        middle button behaves normally (pan).

    Requires the companion file  MaxMouse_GestureHook.cs  next to this script.
    To install/run: evaluate this file (Scripting > Run Script, or drag it into
    a viewport). It compiles the hook, starts immediately, and registers a
    macro "maxMouse Toggle" (category: maxMouse).
    --------------------------------------------------------------------------
*/

global maxMouse_hook
global maxMouse_asm
global maxMouse_menu
global maxMouse_armTimer

-- ===========================================================================
--  ACTIONS  (used by the marking menu below - edit / add your own)
-- ===========================================================================
fn mm_undo          = ( max undo )
fn mm_redo          = ( max redo )
fn mm_delete        = ( local s = getCurrentSelection(); if s.count > 0 do ( with undo "maxMouse Delete" on ( delete s ) ) )
fn mm_zoomExtSel    = ( max zoomext sel )
fn mm_hideSel       = ( if selection.count > 0 do ( hide (getCurrentSelection()) ) )
fn mm_unhideAll     = ( max unhide all )
fn mm_toggleWire    = ( if (viewport.GetRenderLevel() == #wireframe) then viewport.SetRenderLevel #smoothhighlights else viewport.SetRenderLevel #wireframe; redrawViews() )
fn mm_toggleEdged   = ( viewport.setShowEdgeFaces (not (viewport.getShowEdgeFaces())); redrawViews() )

-- ===========================================================================
--  MARKING MENU  (slice order is clockwise from the top: N, NE, E, SE, S, SW,
--  W, NW). Each entry is #( label, action ). Keep labels short.
-- ===========================================================================
fn mm_buildMenu = (
    maxMouse_menu = #(
        #("Zoom Sel",     mm_zoomExtSel),   -- N
        #("Wireframe",    mm_toggleWire),   -- NE
        #("Redo",         mm_redo),         -- E
        #("Hide",         mm_hideSel),      -- SE
        #("Delete",       mm_delete),       -- S
        #("Unhide All",   mm_unhideAll),    -- SW
        #("Undo",         mm_undo),         -- W
        #("Edged Faces",  mm_toggleEdged)   -- NW
    )
)

fn mm_pushMenu = (
    local al = dotNetObject "System.Collections.ArrayList"
    for e in maxMouse_menu do al.Add e[1]
    maxMouse_hook.SetRightMenu al
)

fn mm_onMenuSelect sender args = (
    local i = args.Index
    if (i >= 0 and i < maxMouse_menu.count) do (
        try ( maxMouse_menu[i + 1][2]() )
        catch ( format "maxMouse: menu action error (slice %): %\n" i (getCurrentException()) )
    )
)

-- ===========================================================================
--  VERTEX SCREEN-SPACE MOVE  (middle button)
-- ===========================================================================
global mmv_obj, mmv_isPoly, mmv_meshCopy, mmv_sel, mmv_orig
global mmv_center, mmv_normal, mmv_offset, mmv_startLocal, mmv_delta, mmv_ok

-- world-space get/set of one vertex, branching Poly vs Mesh
fn mmv_getWorld i = (
    if mmv_isPoly then ( polyop.getVert mmv_obj i node:mmv_obj )
    else ( (getVert mmv_meshCopy i) * mmv_obj.objecttransform )
)
fn mmv_setWorld i wp = (
    if mmv_isPoly then ( polyop.setVert mmv_obj i wp node:mmv_obj )
    else ( setVert mmv_meshCopy i (wp * (inverse mmv_obj.objecttransform)) )
)
fn mmv_commit = (
    if not mmv_isPoly do ( mmv_obj.mesh = mmv_meshCopy; update mmv_obj.mesh )
)

-- world point where a screen point projects onto the drag plane
fn mmv_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir mmv_normal
    if (abs denom) < 1e-7 then mmv_center
    else ( local t = (dot (mmv_center - r.pos) mmv_normal) / denom; r.pos + t * r.dir )
)

fn mmv_onStart sender args = (
    mmv_ok = false
    try (
        if selection.count != 1 do return false
        mmv_obj = selection[1]
        local b = mmv_obj.baseObject
        mmv_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (mmv_isPoly or isMesh) do return false

        mmv_meshCopy = if isMesh then mmv_obj.mesh else undefined
        mmv_sel = (if mmv_isPoly then (polyop.getVertSelection mmv_obj) else (getVertSelection mmv_obj)) as array
        if mmv_sel.count == 0 do return false

        mmv_orig = for i in mmv_sel collect (mmv_getWorld i)
        local c = [0,0,0]; for w in mmv_orig do c += w
        mmv_center = c / mmv_orig.count
        mmv_normal = normalize ((inverse (viewport.getTM())).row3)

        mmv_offset = [args.X, args.Y] - mouse.pos      -- desktop -> viewport offset
        mmv_startLocal = [args.X, args.Y] - mmv_offset
        mmv_delta = [0,0,0]
        mmv_ok = true
    ) catch ( format "maxMouse: vertex move start failed: %\n" (getCurrentException()); mmv_ok = false )
)

fn mmv_onMove sender args = (
    if not mmv_ok do return false
    try (
        local cur = [args.X, args.Y] - mmv_offset
        mmv_delta = (mmv_planePt cur) - (mmv_planePt mmv_startLocal)
        for k = 1 to mmv_sel.count do mmv_setWorld mmv_sel[k] (mmv_orig[k] + mmv_delta)
        mmv_commit()
        redrawViews()
    ) catch ( format "maxMouse: vertex move failed: %\n" (getCurrentException()) )
)

fn mmv_onEnd sender args = (
    if not mmv_ok do return false
    mmv_ok = false
    try (
        if (length mmv_delta) > 1e-6 do (
            -- restore (no undo), then re-apply inside one undo block -> single clean undo
            for k = 1 to mmv_sel.count do mmv_setWorld mmv_sel[k] mmv_orig[k]
            mmv_commit()
            with undo "maxMouse Move Verts (screen)" on (
                for k = 1 to mmv_sel.count do mmv_setWorld mmv_sel[k] (mmv_orig[k] + mmv_delta)
                mmv_commit()
            )
            redrawViews()
        )
    ) catch ( format "maxMouse: vertex move commit failed: %\n" (getCurrentException()) )
)

-- arm/disarm the middle button depending on current sub-object state
fn mm_updateArmed = (
    if maxMouse_hook == undefined do return false
    local armed = false
    try (
        if selection.count == 1 do (
            local o = selection[1]
            local b = o.baseObject
            local lvl = try (subobjectLevel) catch (undefined)
            if (lvl == 1) do (                           -- 1 = Vertex
                if (classof b == Editable_Poly) do
                    armed = ((polyop.getVertSelection o).numberSet > 0)
                if (classof b == Editable_Mesh) do
                    armed = ((getVertSelection o).numberSet > 0)
            )
        )
    ) catch ( armed = false )
    maxMouse_hook.VertexMoveArmed = armed
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
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(src)
    if res.Errors.HasErrors do (
        local m = "maxMouse: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    maxMouse_asm = res.CompiledAssembly
)

fn mm_startArmTimer = (
    if maxMouse_armTimer != undefined do ( try ( maxMouse_armTimer.Stop() ) catch () )
    maxMouse_armTimer = dotNetObject "System.Windows.Forms.Timer"
    maxMouse_armTimer.Interval = 200
    dotNet.addEventHandler maxMouse_armTimer "Tick" (fn mm_armTick s e = mm_updateArmed())
    maxMouse_armTimer.Start()
)

fn maxMouse_start = (
    if maxMouse_hook != undefined and maxMouse_hook.IsRunning do (
        format "maxMouse: already running.\n"
        return false
    )
    mm_compile()
    mm_buildMenu()

    local t = maxMouse_asm.GetType "MaxMouse.GestureHook"
    maxMouse_hook = (dotNetClass "System.Activator").CreateInstance t
    maxMouse_hook.EnableRightMenu = true
    maxMouse_hook.PopupDelayMs    = 160      -- ms to hold before the radial menu shows
    maxMouse_hook.DeadZone        = 14       -- px; flick shorter than this = cancel/plain click

    dotNet.addEventHandler maxMouse_hook "MarkingMenuSelected" mm_onMenuSelect
    dotNet.addEventHandler maxMouse_hook "VertexDragStart"     mmv_onStart
    dotNet.addEventHandler maxMouse_hook "VertexDragMove"      mmv_onMove
    dotNet.addEventHandler maxMouse_hook "VertexDragEnd"       mmv_onEnd

    maxMouse_hook.Start()
    mm_pushMenu()
    mm_startArmTimer()

    callbacks.removeScripts id:#maxMouse
    callbacks.addScript #preSystemShutdown "if (maxMouse_stop != undefined) do maxMouse_stop()" id:#maxMouse

    format "maxMouse: started (right = marking menu, middle = vertex move).\n"
    true
)

fn maxMouse_stop = (
    if maxMouse_armTimer != undefined do ( try ( maxMouse_armTimer.Stop() ) catch (); maxMouse_armTimer = undefined )
    if maxMouse_hook != undefined do ( try ( maxMouse_hook.Stop() ) catch (); maxMouse_hook = undefined )
    format "maxMouse: stopped.\n"
)

fn maxMouse_toggle = (
    if (maxMouse_hook != undefined and maxMouse_hook.IsRunning) then maxMouse_stop() else maxMouse_start()
)

-- ===========================================================================
--  TOOLBAR MACRO  (Customize > Toolbars, category "maxMouse")
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

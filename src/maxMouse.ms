/*  maxMouse - Maya-style mouse gestures for 3ds Max
    --------------------------------------------------------------------------
    RIGHT button : Maya-style MARKING MENU whose contents change with the
        current sub-object level (Object / Vertex / Edge / Polygon).
        Press & hold, a radial menu of 8 items (with icons) appears after a
        short delay; flick toward a slice and release to run it. Flick fast
        (release before the menu shows) to run it without seeing the menu. A
        plain right-click still opens the normal quad menu.

    MIDDLE button: screen-space VERTEX MOVE. When an Editable Poly / Mesh is in
        Vertex sub-object level with a vertex selection, a middle-button drag
        moves the selected verts along the screen plane (no pan). Otherwise the
        middle button pans as usual.

    Requires the companion file  MaxMouse_GestureHook.cs  next to this script,
    and (optionally) PNG icons in ../icons/. To install/run: evaluate this file
    (Scripting > Run Script, or drag it into a viewport). It compiles the hook,
    starts immediately, and registers a macro "maxMouse Toggle" (category:
    maxMouse).
    --------------------------------------------------------------------------
*/

global maxMouse_hook
global maxMouse_asm
global maxMouse_menu                 -- the currently active menu (for dispatch)
global maxMouse_armTimer
global maxMouse_iconDir
global mm_menu_object, mm_menu_vertex, mm_menu_edge, mm_menu_face
global mm_lastMenuKey

-- ===========================================================================
--  GENERAL ACTIONS  (object level)
-- ===========================================================================
fn mm_undo          = ( max undo )
fn mm_redo          = ( max redo )
fn mm_delete        = ( local s = getCurrentSelection(); if s.count > 0 do ( with undo "maxMouse Delete" on ( delete s ) ) )
fn mm_zoomExtSel    = ( max zoomext sel )
fn mm_hideSel       = ( if selection.count > 0 do ( hide (getCurrentSelection()) ) )
fn mm_unhideAll     = ( max unhide all )
fn mm_toggleWire    = ( if (viewport.GetRenderLevel() == #wireframe) then viewport.SetRenderLevel #smoothhighlights else viewport.SetRenderLevel #wireframe; redrawViews() )
fn mm_toggleEdged   = ( viewport.setShowEdgeFaces (not (viewport.getShowEdgeFaces())); redrawViews() )

-- ---------------------------------------------------------------------------
--  Sub-object operations via the EditablePoly interface buttonOp (same as the
--  command-panel buttons: they act on the current sub-object selection using
--  the object's current settings). Edit the enums to taste.
--  NOTE: buttonOp requires an Editable Poly base object. Editable Mesh isn't
--  supported here (a message is printed); convert to Editable Poly if needed.
-- ---------------------------------------------------------------------------
fn mm_bop op = (
    local o = (if selection.count == 1 then selection[1] else undefined)
    if o == undefined do ( format "maxMouse: select a single object first.\n"; return false )
    local b = o.baseObject
    if (classof b != Editable_Poly) do (
        format "maxMouse: '%' needs an Editable Poly (current base: %).\n" op (classof b)
        return false
    )
    -- the EditablePoly mixin interface is reachable from the node or its base
    -- object depending on version; try both before giving up.
    try ( with undo (op as string) on ( o.buttonOp op ); redrawViews() )
    catch (
        try ( with undo (op as string) on ( b.buttonOp op ); redrawViews() )
        catch ( format "maxMouse: buttonOp % failed: %\n" op (getCurrentException()) )
    )
)

fn mm_op_weldV    = ( mm_bop #WeldSelected )
fn mm_op_break    = ( mm_bop #BreakVertex )
fn mm_op_connectV = ( mm_bop #ConnectVertices )
fn mm_op_connectE = ( mm_bop #ConnectEdges )
fn mm_op_chamfer  = ( mm_bop #Chamfer )
fn mm_op_remove   = ( mm_bop #Remove )
fn mm_op_collapse = ( mm_bop #Collapse )
fn mm_op_cut      = ( mm_bop #Cut )
fn mm_op_split    = ( mm_bop #SplitEdges )
fn mm_op_extrude  = ( mm_bop #Extrude )
fn mm_op_bevel    = ( mm_bop #Bevel )
fn mm_op_inset    = ( mm_bop #Inset )
fn mm_op_detach   = ( mm_bop #Detach )
fn mm_op_delete   = ( mm_bop #Delete )

-- ===========================================================================
--  PER-LEVEL MARKING MENUS
--    slice order is clockwise from the top: N, NE, E, SE, S, SW, W, NW
--    each entry is #( "label", actionFn, "iconName" )  (icon = ../icons/<name>.png)
--    Undo/Redo are kept on W/E in every menu for muscle memory.
-- ===========================================================================
fn mm_buildMenus = (
    mm_menu_object = #(
        #("Zoom Sel",   mm_zoomExtSel,  "zoom"),      -- N
        #("Wireframe",  mm_toggleWire,  "wireframe"), -- NE
        #("Redo",       mm_redo,        "redo"),      -- E
        #("Hide",       mm_hideSel,     "hide"),      -- SE
        #("Delete",     mm_delete,      "delete"),    -- S
        #("Unhide All", mm_unhideAll,   "unhide"),    -- SW
        #("Undo",       mm_undo,        "undo"),      -- W
        #("Edged",      mm_toggleEdged, "edged")      -- NW
    )
    mm_menu_vertex = #(
        #("Weld",       mm_op_weldV,    "weld"),      -- N
        #("Connect",    mm_op_connectV, "connect"),   -- NE
        #("Redo",       mm_redo,        "redo"),      -- E
        #("Chamfer",    mm_op_chamfer,  "chamfer"),   -- SE
        #("Remove",     mm_op_remove,   "remove"),    -- S
        #("Collapse",   mm_op_collapse, "collapse"),  -- SW
        #("Undo",       mm_undo,        "undo"),      -- W
        #("Break",      mm_op_break,    "break")      -- NW
    )
    mm_menu_edge = #(
        #("Connect",    mm_op_connectE, "connect"),   -- N
        #("Chamfer",    mm_op_chamfer,  "chamfer"),   -- NE
        #("Redo",       mm_redo,        "redo"),      -- E
        #("Collapse",   mm_op_collapse, "collapse"),  -- SE
        #("Remove",     mm_op_remove,   "remove"),    -- S
        #("Cut",        mm_op_cut,      "cut"),       -- SW
        #("Undo",       mm_undo,        "undo"),      -- W
        #("Split",      mm_op_split,    "cut")        -- NW
    )
    mm_menu_face = #(
        #("Extrude",    mm_op_extrude,  "extrude"),   -- N
        #("Bevel",      mm_op_bevel,    "bevel"),     -- NE
        #("Redo",       mm_redo,        "redo"),      -- E
        #("Inset",      mm_op_inset,    "inset"),     -- SE
        #("Delete",     mm_op_delete,   "delete"),    -- S
        #("Collapse",   mm_op_collapse, "collapse"),  -- SW
        #("Undo",       mm_undo,        "undo"),      -- W
        #("Detach",     mm_op_detach,   "detach")     -- NW
    )
)

fn mm_iconPath name = (
    if name == undefined or name == "" or maxMouse_iconDir == undefined then ""
    else ( local p = maxMouse_iconDir + name + ".png"; if (doesFileExist p) then p else "" )
)

fn mm_setActiveMenu menu = (
    maxMouse_menu = menu
    local labels = dotNetObject "System.Collections.ArrayList"
    local icons  = dotNetObject "System.Collections.ArrayList"
    for e in menu do ( labels.Add e[1]; icons.Add (mm_iconPath e[3]) )
    maxMouse_hook.SetRightMenu labels icons
)

fn mm_onMenuSelect sender args = (
    local i = args.Index
    if (i >= 0 and i < maxMouse_menu.count) do (
        try ( maxMouse_menu[i + 1][2]() )
        catch ( format "maxMouse: menu action error (slice %): %\n" i (getCurrentException()) )
    )
)

-- ===========================================================================
--  CURRENT SUB-OBJECT LEVEL  ->  menu key
-- ===========================================================================
fn mm_currentLevel = (
    local o = (if selection.count == 1 then selection[1] else undefined)
    if o == undefined do return #object
    local b = o.baseObject
    local isPoly = (classof b == Editable_Poly)
    local isMesh = (classof b == Editable_Mesh)
    if not (isPoly or isMesh) do return #object
    local lvl = try (subobjectLevel) catch (0)
    if lvl == undefined do lvl = 0
    case lvl of (
        1: #vertex
        2: #edge
        3: (if isPoly then #edge else #face)   -- poly border ~ edge menu, mesh face
        4: #face
        5: #face
        default: #object
    )
)

fn mm_menuFor key = (
    case key of (
        #vertex: mm_menu_vertex
        #edge:   mm_menu_edge
        #face:   mm_menu_face
        default: mm_menu_object
    )
)

-- ===========================================================================
--  VERTEX SCREEN-SPACE MOVE  (middle button)
-- ===========================================================================
global mmv_obj, mmv_isPoly, mmv_meshCopy, mmv_sel, mmv_orig
global mmv_center, mmv_normal, mmv_offset, mmv_startLocal, mmv_delta, mmv_ok

fn mmv_getWorld i = (
    if mmv_isPoly then ( polyop.getVert mmv_obj i node:mmv_obj )
    else ( (getVert mmv_meshCopy i) * mmv_obj.objecttransform )
)
fn mmv_setWorld i wp = (
    if mmv_isPoly then ( polyop.setVert mmv_obj i wp node:mmv_obj )
    else ( setVert mmv_meshCopy i (wp * (inverse mmv_obj.objecttransform)) )
)
fn mmv_commit = ( if not mmv_isPoly do ( mmv_obj.mesh = mmv_meshCopy; update mmv_obj.mesh ) )

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

        mmv_offset = [args.X, args.Y] - mouse.pos
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

-- ===========================================================================
--  POLL  (every 200ms): keep the active menu + middle-button arming in sync
-- ===========================================================================
fn mm_poll = (
    if maxMouse_hook == undefined do return false
    local key = mm_currentLevel()

    -- arm the middle button only for a vertex selection
    local armed = false
    if key == #vertex and selection.count == 1 do (
        local o = selection[1]; local b = o.baseObject
        try (
            if (classof b == Editable_Poly) do armed = ((polyop.getVertSelection o).numberSet > 0)
            if (classof b == Editable_Mesh) do armed = ((getVertSelection o).numberSet > 0)
        ) catch ( armed = false )
    )
    maxMouse_hook.VertexMoveArmed = armed

    -- switch the marking menu when the level changes
    if key != mm_lastMenuKey do ( mm_lastMenuKey = key; mm_setActiveMenu (mm_menuFor key) )
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
    dotNet.addEventHandler maxMouse_armTimer "Tick" (fn mm_pollTick s e = mm_poll())
    maxMouse_armTimer.Start()
)

fn maxMouse_start = (
    if maxMouse_hook != undefined and maxMouse_hook.IsRunning do (
        format "maxMouse: already running.\n"
        return false
    )
    mm_compile()
    mm_buildMenus()
    maxMouse_iconDir = (mm_thisDir()) + @"..\icons\"   -- src/ -> ../icons/

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
    mm_lastMenuKey = #object
    mm_setActiveMenu mm_menu_object
    mm_startArmTimer()

    callbacks.removeScripts id:#maxMouse
    callbacks.addScript #preSystemShutdown "if (maxMouse_stop != undefined) do maxMouse_stop()" id:#maxMouse

    format "maxMouse: started (right = level-aware marking menu, middle = vertex move).\n"
    true
)

fn maxMouse_stop = (
    if maxMouse_armTimer != undefined do ( try ( maxMouse_armTimer.Stop() ) catch (); maxMouse_armTimer = undefined )
    if maxMouse_hook != undefined do ( try ( maxMouse_hook.Stop() ) catch (); maxMouse_hook = undefined )
    mm_lastMenuKey = undefined
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

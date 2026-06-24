/*  maxMouse - Maya-style mouse gestures for 3ds Max
    --------------------------------------------------------------------------
    RIGHT button : Maya-style MARKING MENU whose contents change with the
        current sub-object level (Object / Vertex / Edge / Polygon).
        Hold, a radial menu of 8 icons appears after a short delay; flick toward
        a slice and release to run it. Fast flick = run without showing the
        menu. A plain right-click still opens the normal quad menu.

    CTRL + MIDDLE button: screen-space VERTEX MOVE (Editable Poly/Mesh in vertex
        level) - drag the selected verts along the screen plane. The middle
        button ALONE always pans normally; only Ctrl+middle is intercepted, so
        there's no pan conflict and no polling is needed.

    The menus are editable from a GUI:  maxMouse_editor()  (or the "maxMouse
    Editor" macro). Edits can be applied live and saved to an INI so they
    persist between sessions.

    Requires the companion file  MaxMouse_GestureHook.cs  next to this script,
    and (optionally) PNG icons in ../icons/. To install/run: evaluate this file
    (Scripting > Run Script). It compiles the hook, loads any saved menu config,
    starts immediately, and registers the "maxMouse Toggle" / "maxMouse Editor"
    macros (category: maxMouse).
    --------------------------------------------------------------------------
*/

global maxMouse_hook
global maxMouse_asm
global maxMouse_menu                 -- the currently active menu (for dispatch)
global maxMouse_iconDir
global mm_menu_object, mm_menu_vertex, mm_menu_edge, mm_menu_face
global mm_lastMenuKey
global mm_actions, mm_actionIds, mm_actionNames

-- ===========================================================================
--  GENERAL ACTIONS  (object level)
-- ===========================================================================
fn mm_noop          = ( )
fn mm_undo          = ( max undo )
fn mm_redo          = ( max redo )
fn mm_delete        = ( local s = getCurrentSelection(); if s.count > 0 do ( with undo "maxMouse Delete" on ( delete s ) ) )
fn mm_zoomExtSel    = ( max zoomext sel )
fn mm_hideSel       = ( if selection.count > 0 do ( hide (getCurrentSelection()) ) )
fn mm_unhideAll     = ( max unhide all )
fn mm_toggleWire    = ( if (viewport.GetRenderLevel() == #wireframe) then viewport.SetRenderLevel #smoothhighlights else viewport.SetRenderLevel #wireframe; redrawViews() )
fn mm_toggleEdged   = ( viewport.setShowEdgeFaces (not (viewport.getShowEdgeFaces())); redrawViews() )

-- Sub-object operations via the EditablePoly buttonOp interface (same as the
-- command-panel buttons; act on the current selection/settings).
fn mm_bop op = (
    local o = (if selection.count == 1 then selection[1] else undefined)
    if o == undefined do ( format "maxMouse: select a single object first.\n"; return false )
    local b = o.baseObject
    if (classof b != Editable_Poly) do (
        format "maxMouse: '%' needs an Editable Poly (current base: %).\n" op (classof b)
        return false
    )
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
--  ACTION REGISTRY   #( id, "Display Name", function )
--  The menus and the GUI editor refer to actions by id; add your own here.
-- ===========================================================================
fn mm_buildActions = (
    mm_actions = #(
        #("none",      "(empty)",            mm_noop),
        #("undo",      "Undo",               mm_undo),
        #("redo",      "Redo",               mm_redo),
        #("delete",    "Delete (objects)",   mm_delete),
        #("zoomSel",   "Zoom Extents Sel",   mm_zoomExtSel),
        #("hide",      "Hide Selection",     mm_hideSel),
        #("unhideAll", "Unhide All",         mm_unhideAll),
        #("wire",      "Toggle Wireframe",   mm_toggleWire),
        #("edged",     "Toggle Edged Faces", mm_toggleEdged),
        #("weld",      "Weld",               mm_op_weldV),
        #("break",     "Break Vertices",     mm_op_break),
        #("connectV",  "Connect Vertices",   mm_op_connectV),
        #("connectE",  "Connect Edges",      mm_op_connectE),
        #("chamfer",   "Chamfer",            mm_op_chamfer),
        #("remove",    "Remove",             mm_op_remove),
        #("collapse",  "Collapse",           mm_op_collapse),
        #("cut",       "Cut",                mm_op_cut),
        #("split",     "Split Edges",        mm_op_split),
        #("extrude",   "Extrude",            mm_op_extrude),
        #("bevel",     "Bevel",              mm_op_bevel),
        #("inset",     "Inset",              mm_op_inset),
        #("detach",    "Detach",             mm_op_detach),
        #("subDelete", "Delete (sub-obj)",   mm_op_delete)
    )
    mm_actionIds   = for a in mm_actions collect a[1]
    mm_actionNames = for a in mm_actions collect a[2]
)

fn mm_actionFn id = (
    local res = mm_noop
    for a in mm_actions do ( if a[1] == id do ( res = a[3]; exit ) )
    res
)
fn mm_indexOfId id = (
    local n = findItem mm_actionIds id
    if n == 0 then (findItem mm_actionIds "none") else n
)

-- ===========================================================================
--  PER-LEVEL MARKING MENUS  (defaults)
--    slice order clockwise from top: N, NE, E, SE, S, SW, W, NW
--    each entry is #( "label", "actionId", "iconName" )
-- ===========================================================================
fn mm_buildMenus = (
    mm_menu_object = #(
        #("Zoom Sel",   "zoomSel",  "zoom"),
        #("Wireframe",  "wire",     "wireframe"),
        #("Redo",       "redo",     "redo"),
        #("Hide",       "hide",     "hide"),
        #("Delete",     "delete",   "delete"),
        #("Unhide All", "unhideAll","unhide"),
        #("Undo",       "undo",     "undo"),
        #("Edged",      "edged",    "edged")
    )
    mm_menu_vertex = #(
        #("Weld",       "weld",     "weld"),
        #("Connect",    "connectV", "connect"),
        #("Redo",       "redo",     "redo"),
        #("Chamfer",    "chamfer",  "chamfer"),
        #("Remove",     "remove",   "remove"),
        #("Collapse",   "collapse", "collapse"),
        #("Undo",       "undo",     "undo"),
        #("Break",      "break",    "break")
    )
    mm_menu_edge = #(
        #("Connect",    "connectE", "connect"),
        #("Chamfer",    "chamfer",  "chamfer"),
        #("Redo",       "redo",     "redo"),
        #("Collapse",   "collapse", "collapse"),
        #("Remove",     "remove",   "remove"),
        #("Cut",        "cut",      "cut"),
        #("Undo",       "undo",     "undo"),
        #("Split",      "split",    "cut")
    )
    mm_menu_face = #(
        #("Extrude",    "extrude",  "extrude"),
        #("Bevel",      "bevel",    "bevel"),
        #("Redo",       "redo",     "redo"),
        #("Inset",      "inset",    "inset"),
        #("Delete",     "subDelete","delete"),
        #("Collapse",   "collapse", "collapse"),
        #("Undo",       "undo",     "undo"),
        #("Detach",     "detach",   "detach")
    )
)

fn mm_getMenu key = (
    case key of (
        #vertex: mm_menu_vertex
        #edge:   mm_menu_edge
        #face:   mm_menu_face
        default: mm_menu_object
    )
)
fn mm_setMenu key menu = (
    case key of (
        #vertex: mm_menu_vertex = menu
        #edge:   mm_menu_edge   = menu
        #face:   mm_menu_face   = menu
        default: mm_menu_object = menu
    )
)
fn mm_menuFor key = mm_getMenu key

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
        local id = maxMouse_menu[i + 1][2]
        try ( (mm_actionFn id)() )
        catch ( format "maxMouse: menu action error (slice %, id %): %\n" i id (getCurrentException()) )
    )
)

-- ===========================================================================
--  CONFIG  (persist menus to <plugcfg>/maxMouse/menus.ini)
-- ===========================================================================
fn mm_configPath = (
    local d = (getDir #plugcfg) + "\\maxMouse\\"
    makeDir d all:true
    d + "menus.ini"
)
fn mmSplitPipe s = (    -- split on '|' preserving empty fields
    local res = #(); local cur = ""
    for i = 1 to s.count do ( local c = s[i]; if c == "|" then ( append res cur; cur = "" ) else cur += c )
    append res cur
    res
)
fn mm_saveConfig = (
    local p = mm_configPath()
    for key in #(#object, #vertex, #edge, #face) do (
        local sec = key as string
        local menu = mm_getMenu key
        for k = 1 to menu.count do (
            local e = menu[k]
            setINISetting p sec ((k - 1) as string) (e[1] + "|" + e[2] + "|" + e[3])
        )
    )
    format "maxMouse: menus saved to %\n" p
)
fn mm_loadConfig = (
    local p = mm_configPath()
    if not (doesFileExist p) do return false
    for key in #(#object, #vertex, #edge, #face) do (
        local sec = key as string
        local def = mm_getMenu key
        local menu = #()
        for k = 0 to 7 do (
            local v = getINISetting p sec (k as string)
            if v != "" then (
                local parts = mmSplitPipe v
                local label = if parts.count >= 1 then parts[1] else ""
                local id    = if parts.count >= 2 then parts[2] else "none"
                local icon  = if parts.count >= 3 then parts[3] else ""
                append menu #(label, id, icon)
            ) else (
                if (k + 1) <= def.count then append menu def[k + 1] else append menu #("", "none", "")
            )
        )
        mm_setMenu key menu
    )
    true
)

-- push the (possibly edited) menus to the live hook
fn mm_applyMenus = (
    mm_lastMenuKey = undefined
    if (maxMouse_hook != undefined and maxMouse_hook.IsRunning) do mm_poll()
)

-- ===========================================================================
--  CURRENT SUB-OBJECT LEVEL -> menu key ; POLL keeps things in sync
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
        3: (if isPoly then #edge else #face)
        4: #face
        5: #face
        default: #object
    )
)

fn mm_poll = (
    if maxMouse_hook == undefined do return false
    local key = mm_currentLevel()

    -- Vertex move is triggered by Ctrl + middle (checked in the hook), so we
    -- only need to know whether we're in vertex level on an editable poly/mesh
    -- (no per-component selection count -> fully callback-driven, no fast poll).
    local armed = false
    if key == #vertex and selection.count == 1 do (
        local b = selection[1].baseObject
        armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    maxMouse_hook.VertexMoveArmed = armed

    if key != mm_lastMenuKey do ( mm_lastMenuKey = key; mm_setActiveMenu (mm_menuFor key) )
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
--  GUI MENU EDITOR
-- ===========================================================================
fn mm_iconList = (
    local names = #()
    if maxMouse_iconDir != undefined do
        for f in (getFiles (maxMouse_iconDir + "*.png")) do append names (getFilenameFile f)
    names
)

rollout maxMouseEditorRoll "maxMouse - Marking Menu Editor" width:476
(
    local levelKeys = #(#object, #vertex, #edge, #face)
    local dirNames  = #("N (up)", "NE", "E", "SE", "S", "SW", "W", "NW")
    local iconNames = #()
    local rEdit = #(), rAct = #(), rIcon = #()
    local curIdx = 1

    dropdownlist ddLevel "Sub-object level" items:#("Object", "Vertex", "Edge", "Polygon") width:200 align:#left across:2
    label lblHint "edit -> Apply (live) -> Save" align:#right

    label l1 "N (up)" align:#left across:4 offset:[0,4]
    edittext et1 "" width:104 fieldWidth:104
    dropdownlist da1 width:150
    dropdownlist di1 width:96
    label l2 "NE" align:#left across:4
    edittext et2 "" width:104 fieldWidth:104
    dropdownlist da2 width:150
    dropdownlist di2 width:96
    label l3 "E" align:#left across:4
    edittext et3 "" width:104 fieldWidth:104
    dropdownlist da3 width:150
    dropdownlist di3 width:96
    label l4 "SE" align:#left across:4
    edittext et4 "" width:104 fieldWidth:104
    dropdownlist da4 width:150
    dropdownlist di4 width:96
    label l5 "S" align:#left across:4
    edittext et5 "" width:104 fieldWidth:104
    dropdownlist da5 width:150
    dropdownlist di5 width:96
    label l6 "SW" align:#left across:4
    edittext et6 "" width:104 fieldWidth:104
    dropdownlist da6 width:150
    dropdownlist di6 width:96
    label l7 "W" align:#left across:4
    edittext et7 "" width:104 fieldWidth:104
    dropdownlist da7 width:150
    dropdownlist di7 width:96
    label l8 "NW" align:#left across:4
    edittext et8 "" width:104 fieldWidth:104
    dropdownlist da8 width:150
    dropdownlist di8 width:96

    button btnApply "Apply (live)" width:108 across:4 offset:[0,6]
    button btnSave  "Save" width:96 offset:[0,6]
    button btnReset "Reset defaults" width:130 offset:[0,6]
    button btnClose "Close" width:96 offset:[0,6]

    fn iconSelFor name = (
        if name == "" or name == undefined then 1
        else ( local n = findItem iconNames name; if n == 0 then 1 else n + 1 )
    )
    fn loadLevel idx = (
        local menu = mm_getMenu levelKeys[idx]
        for k = 1 to 8 do (
            local e = if k <= menu.count then menu[k] else #("", "none", "")
            rEdit[k].text = e[1]
            rAct[k].selection  = mm_indexOfId e[2]
            rIcon[k].selection = iconSelFor e[3]
        )
    )
    fn readLevel idx = (
        local menu = #()
        for k = 1 to 8 do (
            local asel = rAct[k].selection
            if asel < 1 do asel = mm_indexOfId "none"
            local label = rEdit[k].text
            local id    = mm_actionIds[asel]
            local icon  = if rIcon[k].selection <= 1 then "" else iconNames[rIcon[k].selection - 1]
            append menu #(label, id, icon)
        )
        mm_setMenu levelKeys[idx] menu
    )

    on maxMouseEditorRoll open do (
        rEdit = #(et1,et2,et3,et4,et5,et6,et7,et8)
        rAct  = #(da1,da2,da3,da4,da5,da6,da7,da8)
        rIcon = #(di1,di2,di3,di4,di5,di6,di7,di8)
        iconNames = mm_iconList()
        local iconItems = #("(none)"); join iconItems iconNames
        for k = 1 to 8 do ( rAct[k].items = mm_actionNames; rIcon[k].items = iconItems )
        curIdx = ddLevel.selection
        loadLevel curIdx
    )
    on ddLevel selected i do ( readLevel curIdx; curIdx = i; loadLevel curIdx )
    on btnApply pressed do ( readLevel curIdx; mm_applyMenus(); format "maxMouse: menus applied.\n" )
    on btnSave  pressed do ( readLevel curIdx; mm_applyMenus(); mm_saveConfig() )
    on btnReset pressed do ( mm_buildMenus(); loadLevel curIdx; mm_applyMenus(); format "maxMouse: menus reset to defaults (not yet saved).\n" )
    on btnClose pressed do ( try ( destroyDialog maxMouseEditorRoll ) catch () )
)

fn maxMouse_editor = (
    if maxMouse_hook == undefined do ( format "maxMouse: start maxMouse first (run the script).\n"; return false )
    try ( destroyDialog maxMouseEditorRoll ) catch ()
    createDialog maxMouseEditorRoll
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

-- Fully event-driven sync: menu switching and vertex-move arming react to
-- selection / sub-object level callbacks. No polling timer is needed, because
-- arming only depends on the sub-object *level* (vertex move is triggered by
-- Ctrl + middle, detected in the hook), and that level is covered by callbacks.
fn mm_addCb evt = (
    try ( callbacks.addScript evt "if (mm_poll != undefined) do mm_poll()" id:#maxMouseEvt ) catch ()
)
fn mm_registerEvents = (
    callbacks.removeScripts id:#maxMouseEvt
    mm_addCb #selectionSetChanged           -- node selection changed
    mm_addCb #modPanelSubObjectLevelChanged  -- sub-object level changed
    mm_addCb #modPanelSelectionSetChanged    -- modify panel opened on new selection
    mm_addCb #modPanelObjPostChange
    mm_poll()                                -- sync once to the current state
)

fn maxMouse_start = (
    if maxMouse_hook != undefined and maxMouse_hook.IsRunning do (
        format "maxMouse: already running.\n"
        return false
    )
    mm_compile()
    maxMouse_iconDir = (mm_thisDir()) + @"..\icons\"   -- src/ -> ../icons/
    mm_buildActions()
    mm_buildMenus()
    mm_loadConfig()                                    -- override defaults with saved menus

    local t = maxMouse_asm.GetType "MaxMouse.GestureHook"
    maxMouse_hook = (dotNetClass "System.Activator").CreateInstance t
    maxMouse_hook.EnableRightMenu = true
    maxMouse_hook.PopupDelayMs    = 160
    maxMouse_hook.DeadZone        = 14
    maxMouse_hook.VertexMoveModifier = 1     -- 0=none, 1=Ctrl, 2=Alt, 3=Shift

    dotNet.addEventHandler maxMouse_hook "MarkingMenuSelected" mm_onMenuSelect
    dotNet.addEventHandler maxMouse_hook "VertexDragStart"     mmv_onStart
    dotNet.addEventHandler maxMouse_hook "VertexDragMove"      mmv_onMove
    dotNet.addEventHandler maxMouse_hook "VertexDragEnd"       mmv_onEnd

    maxMouse_hook.Start()
    mm_lastMenuKey = #object
    mm_setActiveMenu mm_menu_object
    mm_registerEvents()

    callbacks.removeScripts id:#maxMouse
    callbacks.addScript #preSystemShutdown "if (maxMouse_stop != undefined) do maxMouse_stop()" id:#maxMouse

    format "maxMouse: started (right = level-aware marking menu, middle = vertex move).\n"
    format "          edit menus with  maxMouse_editor()  or the 'maxMouse Editor' macro.\n"
    true
)

fn maxMouse_stop = (
    callbacks.removeScripts id:#maxMouseEvt
    if maxMouse_hook != undefined do ( try ( maxMouse_hook.Stop() ) catch (); maxMouse_hook = undefined )
    mm_lastMenuKey = undefined
    format "maxMouse: stopped.\n"
)

fn maxMouse_toggle = (
    if (maxMouse_hook != undefined and maxMouse_hook.IsRunning) then maxMouse_stop() else maxMouse_start()
)

-- ===========================================================================
--  TOOLBAR MACROS  (Customize > Toolbars, category "maxMouse")
-- ===========================================================================
macroScript maxMouse_Toggle
    category:"maxMouse" buttontext:"maxMouse" tooltip:"Toggle maxMouse gestures on/off"
( on execute do ( if (maxMouse_toggle != undefined) do maxMouse_toggle() ) )

macroScript maxMouse_Editor
    category:"maxMouse" buttontext:"maxMouse Editor" tooltip:"Edit maxMouse marking menus"
( on execute do ( if (maxMouse_editor != undefined) do maxMouse_editor() ) )

-- start now
try ( maxMouse_start() )
catch ( format "maxMouse: failed to start: %\n" (getCurrentException()) )

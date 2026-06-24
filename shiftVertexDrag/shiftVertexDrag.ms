/*  shiftVertexDrag - standalone "Shift + middle-drag = move verts in screen space"
    --------------------------------------------------------------------------
    Self-contained. No marking menu, no UI, no dependency on maxMouse.

    Hold SHIFT and drag with the MIDDLE mouse button while an Editable Poly /
    Editable Mesh is in Vertex sub-object level: the selected vertices slide
    along the screen plane (the viewport does NOT pan). The middle button alone
    pans as usual; the left button is never touched.

    Requires the companion file  ShiftVertexHook.cs  next to this script.
    To run: Scripting > Run Script  ->  shiftVertexDrag.ms  (starts immediately,
    registers the "shiftVertexDrag Toggle" macro, category: shiftVertexDrag).
    --------------------------------------------------------------------------
*/

global svm_hook
global svm_asm
global svm_obj, svm_isPoly, svm_meshCopy, svm_sel, svm_orig
global svm_center, svm_normal, svm_offset, svm_startLocal, svm_startWorld, svm_delta, svm_ok

-- ===========================================================================
--  VERTEX SCREEN-SPACE MOVE
-- ===========================================================================
fn svm_getWorld i = (
    if svm_isPoly then ( polyop.getVert svm_obj i node:svm_obj )
    else ( (getVert svm_meshCopy i) * svm_obj.objecttransform )
)
fn svm_setWorld i wp = (
    if svm_isPoly then ( polyop.setVert svm_obj i wp node:svm_obj )
    else ( setVert svm_meshCopy i (wp * (inverse svm_obj.objecttransform)) )
)
fn svm_commit = ( if not svm_isPoly do ( svm_obj.mesh = svm_meshCopy; update svm_obj.mesh ) )

fn svm_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir svm_normal
    if (abs denom) < 1e-7 then svm_center
    else ( local t = (dot (svm_center - r.pos) svm_normal) / denom; r.pos + t * r.dir )
)

fn svm_onStart sender args = (
    svm_ok = false
    try (
        if selection.count != 1 do return false
        svm_obj = selection[1]
        local b = svm_obj.baseObject
        svm_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (svm_isPoly or isMesh) do return false

        svm_meshCopy = if isMesh then svm_obj.mesh else undefined
        svm_sel = (if svm_isPoly then (polyop.getVertSelection svm_obj) else (getVertSelection svm_obj)) as array
        if svm_sel.count == 0 do return false

        svm_orig = for i in svm_sel collect (svm_getWorld i)
        local c = [0,0,0]; for w in svm_orig do c += w
        svm_center = c / svm_orig.count
        svm_normal = normalize ((inverse (viewport.getTM())).row3)

        svm_offset = [args.X, args.Y] - mouse.pos
        svm_startLocal = [args.X, args.Y] - svm_offset
        svm_startWorld = svm_planePt svm_startLocal   -- cache (constant during drag)
        svm_delta = [0,0,0]
        svm_ok = true
    ) catch ( format "shiftVertexDrag: start failed: %\n" (getCurrentException()); svm_ok = false )
)

fn svm_onMove sender args = (
    if not svm_ok do return false
    try (
        local cur = [args.X, args.Y] - svm_offset
        svm_delta = (svm_planePt cur) - svm_startWorld
        for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
        svm_commit()
        redrawViews()
    ) catch ( format "shiftVertexDrag: move failed: %\n" (getCurrentException()) )
)

fn svm_onEnd sender args = (
    if not svm_ok do return false
    svm_ok = false
    try (
        if (length svm_delta) > 1e-6 do (
            for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] svm_orig[k]   -- restore (no undo)
            svm_commit()
            with undo "Move Verts (screen)" on (
                for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
                svm_commit()
            )
            redrawViews()
        )
    ) catch ( format "shiftVertexDrag: commit failed: %\n" (getCurrentException()) )
)

-- ===========================================================================
--  ARMING  (event-driven: only need to know if we're in vertex level)
-- ===========================================================================
fn svm_poll = (
    if svm_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if lvl == 1 do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    svm_hook.Armed = armed
)

fn svm_addCb evt = (
    try ( callbacks.addScript evt "if (svm_poll != undefined) do svm_poll()" id:#shiftVertexDrag ) catch ()
)

-- ===========================================================================
--  COMPILE + START / STOP
-- ===========================================================================
fn svm_thisDir = (
    local p = undefined
    try ( p = getThisScriptFilename() ) catch ()
    if p == undefined do ( try ( p = getSourceFileName() ) catch () )
    if p == undefined do throw "shiftVertexDrag: cannot resolve script path; run via Scripting > Run Script."
    getFilenamePath p
)

fn svm_compile = (
    local csPath = (svm_thisDir()) + "ShiftVertexHook.cs"
    if not (doesFileExist csPath) do throw ("shiftVertexDrag: companion file not found: " + csPath)

    local fs = openFile csPath mode:"r"
    local src = ""
    while not (eof fs) do src += (readLine fs) + "\n"
    close fs

    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(src)
    if res.Errors.HasErrors do (
        local m = "shiftVertexDrag: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    svm_asm = res.CompiledAssembly
)

fn shiftVertexDrag_start = (
    if svm_hook != undefined and svm_hook.IsRunning do (
        format "shiftVertexDrag: already running.\n"
        return false
    )
    svm_compile()

    local t = svm_asm.GetType "ShiftVertexMove.VertexDragHook"
    svm_hook = (dotNetClass "System.Activator").CreateInstance t
    svm_hook.Modifier = 3     -- 0=none, 1=Ctrl, 2=Alt, 3=Shift

    dotNet.addEventHandler svm_hook "VertexDragStart" svm_onStart
    dotNet.addEventHandler svm_hook "VertexDragMove"  svm_onMove
    dotNet.addEventHandler svm_hook "VertexDragEnd"   svm_onEnd

    svm_hook.Start()

    callbacks.removeScripts id:#shiftVertexDrag
    svm_addCb #selectionSetChanged
    svm_addCb #modPanelSubObjectLevelChanged
    svm_addCb #modPanelSelectionSetChanged
    svm_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (shiftVertexDrag_stop != undefined) do shiftVertexDrag_stop()" id:#shiftVertexDrag
    svm_poll()

    format "shiftVertexDrag: started (Shift + middle-drag moves verts in screen space).\n"
    true
)

fn shiftVertexDrag_stop = (
    callbacks.removeScripts id:#shiftVertexDrag
    if svm_hook != undefined do ( try ( svm_hook.Stop() ) catch (); svm_hook = undefined )
    format "shiftVertexDrag: stopped.\n"
)

fn shiftVertexDrag_toggle = (
    if (svm_hook != undefined and svm_hook.IsRunning) then shiftVertexDrag_stop() else shiftVertexDrag_start()
)

macroScript shiftVertexDrag_Toggle
    category:"shiftVertexDrag" buttontext:"ShiftVertDrag" tooltip:"Toggle Shift+middle vertex drag"
( on execute do ( if (shiftVertexDrag_toggle != undefined) do shiftVertexDrag_toggle() ) )

-- start now
try ( shiftVertexDrag_start() )
catch ( format "shiftVertexDrag: failed to start: %\n" (getCurrentException()) )

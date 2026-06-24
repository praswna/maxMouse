/*  pivotZDrag - "Ctrl+Shift + 휠(중간버튼) 드래그 = 워킹 피벗 Z축으로 버텍스 이동"
    ==========================================================================
    [개요]
    Editable Poly / Editable Mesh 가 "버텍스" 서브오브젝트 레벨일 때,
    CTRL+SHIFT 를 누른 채 중간(휠) 버튼으로 드래그하면, 선택된 버텍스들이
    "워킹 피벗(Working Pivot)의 Z축" 방향으로 이동합니다.

    - 워킹 피벗 Z축을 표면 법선에 맞춰두면(예: 피벗 스냅 도구), 곧 "법선 방향
      밀어내기/집어넣기"가 됩니다. 워킹 피벗이 없으면 오브젝트 로컬 Z로 폴백.
    - 드래그는 "화면 평면 이동량을 그 축에 투영"해서 적용합니다. 즉 축이 화면에
      보이는 방향으로 끌면 그 축을 따라 이동(= Max 기즈모 축 드래그와 동일한 느낌).
    - 중간버튼 단독/Shift만/왼쪽버튼은 건드리지 않습니다(정확 매칭이라 Shift 전용
      도구와도 안 겹침). 한 드래그 = 한 번의 Undo.

    [독립성] maxMouse / shiftVertexDrag 와 완전히 분리된 단독 모듈.
        C# 네임스페이스: PivotZMove / 전역 접두사: pzd_ / 콜백 ID: #pivotZDrag

    [요구사항] 같은 폴더에 PivotZHook.cs 가 있어야 함.
    [실행] Scripting > Run Script -> pivotZDrag.ms (실행 즉시 시작,
        "pivotZDrag Toggle" 매크로 등록. 카테고리: pivotZDrag)
    ==========================================================================
*/

global pzd_hook
global pzd_asm
global pzd_obj, pzd_isPoly, pzd_meshCopy, pzd_sel, pzd_orig
global pzd_center, pzd_normal, pzd_axis, pzd_offset, pzd_startLocal, pzd_startWorld, pzd_delta, pzd_ok

-- ===========================================================================
--  버텍스 이동 (월드 좌표 기반, Poly/Mesh 분기)
-- ===========================================================================
fn pzd_getWorld i = (
    if pzd_isPoly then ( polyop.getVert pzd_obj i node:pzd_obj )
    else ( (getVert pzd_meshCopy i) * pzd_obj.objecttransform )
)
fn pzd_setWorld i wp = (
    if pzd_isPoly then ( polyop.setVert pzd_obj i wp node:pzd_obj )
    else ( setVert pzd_meshCopy i (wp * (inverse pzd_obj.objecttransform)) )
)
fn pzd_commit = ( if not pzd_isPoly do ( pzd_obj.mesh = pzd_meshCopy; update pzd_obj.mesh ) )

-- 화면 좌표 p 를 "화면과 평행한 평면(선택중심 통과)" 위의 월드 좌표로 투영
fn pzd_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir pzd_normal
    if (abs denom) < 1e-7 then pzd_center
    else ( local t = (dot (pzd_center - r.pos) pzd_normal) / denom; r.pos + t * r.dir )
)

-- 이동축(월드) 구하기: 워킹 피벗 Z축, 실패하면 오브젝트 로컬 Z축으로 폴백
fn pzd_moveAxis = (
    local tm = undefined
    try ( tm = WorkingPivot.getTM() ) catch ()       -- 워킹 피벗 변환(월드)
    if tm == undefined do tm = pzd_obj.transform      -- 폴백: 오브젝트 로컬 축
    normalize (tm.row3)                               -- row3 = Z축
)

-- [드래그 시작] 선택 버텍스 원위치/중심/시선법선/이동축 등을 저장
fn pzd_onStart sender args = (
    pzd_ok = false
    try (
        if selection.count != 1 do return false
        pzd_obj = selection[1]
        local b = pzd_obj.baseObject
        pzd_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (pzd_isPoly or isMesh) do return false

        pzd_meshCopy = if isMesh then pzd_obj.mesh else undefined
        pzd_sel = (if pzd_isPoly then (polyop.getVertSelection pzd_obj) else (getVertSelection pzd_obj)) as array
        if pzd_sel.count == 0 do return false

        pzd_orig = for i in pzd_sel collect (pzd_getWorld i)
        local c = [0,0,0]; for w in pzd_orig do c += w
        pzd_center = c / pzd_orig.count

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)   -- 화면 평면 법선(시선)
        pzd_axis   = pzd_moveAxis()                                  -- 이동축 = 워킹 피벗 Z

        pzd_offset = [args.X, args.Y] - mouse.pos                    -- 데스크톱->뷰포트 보정
        pzd_startLocal = [args.X, args.Y] - pzd_offset
        pzd_startWorld = pzd_planePt pzd_startLocal                  -- 시작점 투영(고정)
        pzd_delta = [0,0,0]
        pzd_ok = true
    ) catch ( format "pivotZDrag: start failed: %\n" (getCurrentException()); pzd_ok = false )
)

-- [드래그 중] 화면 평면 이동량을 이동축에 투영한 만큼만 버텍스를 이동
fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        local cur = [args.X, args.Y] - pzd_offset
        local d   = (pzd_planePt cur) - pzd_startWorld    -- 화면 평면상의 월드 이동
        local amt = dot d pzd_axis                        -- 그 이동을 이동축에 투영(스칼라)
        pzd_delta = pzd_axis * amt                        -- 축 방향 성분만 남김
        for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] (pzd_orig[k] + pzd_delta)
        pzd_commit()
        redrawViews()
    ) catch ( format "pivotZDrag: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] 라이브 이동을 원복 후 undo 블록에서 재적용 = 단일 Undo
fn pzd_onEnd sender args = (
    if not pzd_ok do return false
    pzd_ok = false
    try (
        if (length pzd_delta) > 1e-6 do (
            for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] pzd_orig[k]
            pzd_commit()
            with undo "Move Verts (pivot Z)" on (
                for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] (pzd_orig[k] + pzd_delta)
                pzd_commit()
            )
            redrawViews()
        )
    ) catch ( format "pivotZDrag: commit failed: %\n" (getCurrentException()) )
)

-- ===========================================================================
--  무장(Arm): 버텍스 레벨인지만 후크에 알림 (이벤트 기반, 폴링 없음)
-- ===========================================================================
fn pzd_poll = (
    if pzd_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if lvl == 1 do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    pzd_hook.Armed = armed
)
fn pzd_addCb evt = (
    try ( callbacks.addScript evt "if (pzd_poll != undefined) do pzd_poll()" id:#pivotZDrag ) catch ()
)

-- ===========================================================================
--  컴파일 + 시작 / 정지
-- ===========================================================================
fn pzd_thisDir = (
    local p = undefined
    try ( p = getThisScriptFilename() ) catch ()
    if p == undefined do ( try ( p = getSourceFileName() ) catch () )
    if p == undefined do throw "pivotZDrag: cannot resolve script path; run via Scripting > Run Script."
    getFilenamePath p
)

fn pzd_compile = (
    local csPath = (pzd_thisDir()) + "PivotZHook.cs"
    if not (doesFileExist csPath) do throw ("pivotZDrag: companion file not found: " + csPath)

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
        local m = "pivotZDrag: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    pzd_asm = res.CompiledAssembly
)

fn pivotZDrag_start = (
    if pzd_hook != undefined and pzd_hook.IsRunning do (
        format "pivotZDrag: already running.\n"
        return false
    )
    pzd_compile()

    local t = pzd_asm.GetType "PivotZMove.PivotZDragHook"
    pzd_hook = (dotNetClass "System.Activator").CreateInstance t
    pzd_hook.Modifiers = (bit.or 1 4)     -- 정확 매칭: Ctrl(1) + Shift(4)

    dotNet.addEventHandler pzd_hook "VertexDragStart" pzd_onStart
    dotNet.addEventHandler pzd_hook "VertexDragMove"  pzd_onMove
    dotNet.addEventHandler pzd_hook "VertexDragEnd"   pzd_onEnd

    pzd_hook.Start()

    callbacks.removeScripts id:#pivotZDrag
    pzd_addCb #selectionSetChanged
    pzd_addCb #modPanelSubObjectLevelChanged
    pzd_addCb #modPanelSelectionSetChanged
    pzd_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (pivotZDrag_stop != undefined) do pivotZDrag_stop()" id:#pivotZDrag
    pzd_poll()

    format "pivotZDrag: started (Ctrl+Shift + middle-drag moves verts along Working Pivot Z).\n"
    true
)

fn pivotZDrag_stop = (
    callbacks.removeScripts id:#pivotZDrag
    if pzd_hook != undefined do ( try ( pzd_hook.Stop() ) catch (); pzd_hook = undefined )
    format "pivotZDrag: stopped.\n"
)

fn pivotZDrag_toggle = (
    if (pzd_hook != undefined and pzd_hook.IsRunning) then pivotZDrag_stop() else pivotZDrag_start()
)

macroScript pivotZDrag_Toggle
    category:"pivotZDrag" buttontext:"PivotZDrag" tooltip:"Toggle Ctrl+Shift+middle move along Working Pivot Z"
( on execute do ( if (pivotZDrag_toggle != undefined) do pivotZDrag_toggle() ) )

-- 실행 즉시 시작
try ( pivotZDrag_start() )
catch ( format "pivotZDrag: failed to start: %\n" (getCurrentException()) )

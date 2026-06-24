/*  pivotZDrag - "Ctrl+Shift + 휠(중간버튼) 드래그 = 워킹 피벗 Z축으로 버텍스 이동"
    ==========================================================================
    [개요]
    Editable Poly / Editable Mesh 가 버텍스/엣지/페이스 등 서브오브젝트 레벨일 때,
    CTRL+SHIFT 를 누른 채 중간(휠) 버튼으로 드래그하면, 선택된 버텍스들이
    "각자 자기 자신의 법선 방향"으로 같은 거리만큼 이동합니다(노멀 방향 오프셋/
    인플레이트). 다중 선택이면 버텍스마다 서로 다른 방향으로 움직입니다.
    페이스/엣지를 선택해도 그 구성 버텍스들이 각각 자기 법선대로 이동합니다
    (선택은 페이스/엣지로 보이되 움직임은 버텍스 단위).

    동작:
    - 드래그 시작 시 각 버텍스의 월드 법선을 계산. 이동량(스칼라)은 화면 평면
      드래그를 "평균 법선"에 투영해 구한다(바깥으로 끌면 +, 안으로 끌면 -).
    - 각 버텍스: 원위치 + (이동량 x 그 버텍스의 단위 법선).
    - 워킹 피벗/좌표계는 평균 법선으로 잠깐 표시했다가 끝나면 복원(비파괴).
    - 법선을 못 구하면(고립 버텍스 등) 해당 버텍스는 +Z 폴백.
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
global pzd_center, pzd_normal, pzd_axis, pzd_offset, pzd_startLocal, pzd_startWorld, pzd_ok
global pzd_norm                      -- 각 버텍스의 월드 법선 배열(sel 과 같은 순서)
global pzd_amt                       -- 이동량(스칼라): 각 버텍스가 자기 법선으로 amt 만큼
global pzd_prevCoord                 -- 드래그 전 좌표계(끝나면 복원)
global pzd_prevPivotTM               -- 드래그 전 워킹 피벗 TM(끝나면 복원, 비파괴)

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

-- Z 방향으로부터 직교 행렬(matrix3) 생성 (X/Y는 임의의 직교축)
fn pzd_tmFromZ zdir pos = (
    local z = normalize zdir
    local upv = if (abs (dot z [0,0,1])) > 0.99 then [1,0,0] else [0,0,1]
    local x = normalize (cross upv z)
    local y = normalize (cross z x)
    matrix3 x y z pos
)

-- 각 버텍스의 "월드 법선" 배열을 계산 (sel 과 같은 순서).
--   Poly: 그 버텍스를 사용하는 페이스들의 법선 평균(= 버텍스 노멀) -> 월드 변환
--   Mesh: TriMesh 의 버텍스 노멀(getNormal) -> 월드 변환 (best-effort)
--   각 버텍스가 "자기만의 법선" 방향을 갖게 한다.
fn pzd_vertNormals obj isPoly sel = (
    local norms = #()
    local wtm = obj.objecttransform
    if isPoly then (
        for vi in sel do (
            local faces = polyop.getFacesUsingVert obj #{vi}
            local n = [0,0,0]
            for f in faces do n += polyop.getFaceNormal obj f      -- 객체공간
            if (length n) < 1e-9 do n = [0,0,1]                    -- 폴백(고립 버텍스 등)
            append norms (normalize ((normalize n) * wtm - wtm.row4))
        )
    ) else (
        local m = obj.mesh
        for vi in sel do (
            local n = [0,0,1]
            try ( n = getNormal m vi ) catch ()                    -- 메시 버텍스 노멀
            append norms (normalize ((normalize n) * wtm - wtm.row4))
        )
    )
    norms
)

-- 현재 서브오브젝트 레벨에서 "영향받는 버텍스" 집합(비트배열)을 구함.
--   1=버텍스 / 2=엣지·3=보더(엣지가 쓰는 버텍스) / 4=폴리곤·5=엘리먼트(페이스가 쓰는 버텍스)
fn pzd_gatherVerts obj isPoly lvl = (
    if isPoly then (
        case lvl of (
            1: (polyop.getVertSelection obj)
            2: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
            3: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
            4: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
            5: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
            default: #{}
        )
    ) else (
        case lvl of (
            1: (getVertSelection obj)
            2: (try (meshop.getVertsUsingEdge obj (getEdgeSelection obj)) catch (#{}))
            default: (try (meshop.getVertsUsingFace obj (getFaceSelection obj)) catch (#{}))
        )
    )
)

-- [드래그 시작] 선택 서브오브젝트의 버텍스 원위치/중심/시선법선/이동축 등을 저장
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
        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        pzd_sel = (pzd_gatherVerts pzd_obj pzd_isPoly lvl) as array
        if pzd_sel.count == 0 do return false

        pzd_orig = for i in pzd_sel collect (pzd_getWorld i)
        local c = [0,0,0]; for w in pzd_orig do c += w
        pzd_center = c / pzd_orig.count

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)   -- 화면 평면 법선(시선)

        -- 각 버텍스의 "자기만의" 월드 법선 + 평균 법선(드래그량 투영/피벗 표시용)
        pzd_norm = pzd_vertNormals pzd_obj pzd_isPoly pzd_sel
        local an = [0,0,0]; for nrm in pzd_norm do an += nrm
        pzd_axis = if (length an) > 1e-6 then (normalize an) else [0,0,1]

        -- 워킹 피벗을 "평균 법선" 방향으로 정렬하고 좌표계를 워킹 피벗으로 전환(표시용).
        -- 실제 이동은 버텍스별 법선으로 일어남. 좌표계/워킹피벗은 끝나면 복원(비파괴).
        pzd_prevCoord   = try (getRefCoordSys()) catch (#world)
        pzd_prevPivotTM = try (WorkingPivot.getTM()) catch (undefined)
        try (
            WorkingPivot.setTM (pzd_tmFromZ pzd_axis pzd_center)
            toolMode.coordsys #working_pivot
        ) catch ()

        pzd_offset = [args.X, args.Y] - mouse.pos                    -- 데스크톱->뷰포트 보정
        pzd_startLocal = [args.X, args.Y] - pzd_offset
        pzd_startWorld = pzd_planePt pzd_startLocal                  -- 시작점 투영(고정)
        pzd_amt = 0.0
        pzd_ok = true
    ) catch ( format "pivotZDrag: start failed: %\n" (getCurrentException()); pzd_ok = false )
)

-- [드래그 중] 화면 평면 이동량을 "평균 법선"에 투영해 스칼라 amt 를 구하고,
--   각 버텍스를 자기만의 법선 방향으로 amt 만큼 이동(= 노멀 방향 인플레이트/오프셋)
fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        local cur = [args.X, args.Y] - pzd_offset
        local d   = (pzd_planePt cur) - pzd_startWorld    -- 화면 평면상의 월드 이동
        pzd_amt   = dot d pzd_axis                        -- 평균 법선에 투영한 스칼라
        for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] (pzd_orig[k] + pzd_amt * pzd_norm[k])
        pzd_commit()
        redrawViews()
    ) catch ( format "pivotZDrag: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] 라이브 이동을 원복 후 undo 블록에서 재적용 = 단일 Undo
fn pzd_onEnd sender args = (
    if not pzd_ok do return false
    pzd_ok = false
    try (
        if (abs pzd_amt) > 1e-6 do (
            for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] pzd_orig[k]
            pzd_commit()
            with undo "Move Verts (vertex normals)" on (
                for k = 1 to pzd_sel.count do pzd_setWorld pzd_sel[k] (pzd_orig[k] + pzd_amt * pzd_norm[k])
                pzd_commit()
            )
            redrawViews()
        )
    ) catch ( format "pivotZDrag: commit failed: %\n" (getCurrentException()) )
    -- 워킹 피벗 TM 과 좌표계를 드래그 전 상태로 복원(비파괴)
    if pzd_prevPivotTM != undefined do ( try ( WorkingPivot.setTM pzd_prevPivotTM ) catch () )
    if pzd_prevCoord != undefined do ( try ( toolMode.coordsys pzd_prevCoord ) catch () )
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
        -- 버텍스(1)/엣지(2)/보더(3)/폴리곤(4)/엘리먼트(5) 어느 레벨이든 무장
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
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

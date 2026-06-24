/*  pivotZDrag - "Ctrl+Shift + 휠(중간버튼) 드래그 = 워킹 피벗 Z축으로 버텍스 이동"
    ==========================================================================
    [개요]
    Editable Poly / Editable Mesh 가 버텍스/엣지/페이스 등 서브오브젝트 레벨일 때,
    CTRL+SHIFT 를 누른 채 중간(휠) 버튼으로 드래그하면, 선택된 버텍스들이
    "각자 자기 자신의 법선 방향"으로 같은 거리만큼 이동합니다(노멀 방향 오프셋/
    인플레이트). 다중 선택이면 버텍스마다 서로 다른 방향으로 움직입니다.
    페이스/엣지를 선택해도 그 구성 버텍스들이 각각 자기 법선대로 이동합니다
    (선택은 페이스/엣지로 보이되 움직임은 버텍스 단위).

    동작 (주신 스냅 스크립트와 동일하게 "로컬(객체) 공간 법선" 사용):
    - 각 버텍스 법선 = 그 버텍스를 쓰는 페이스 법선들의 합(polyop.getFaceNormal,
      로컬). 회전/이동된 오브젝트에서도 스크립트와 동일한 방향이 나온다.
    - 이동량(스칼라)은 화면 평면 드래그(월드)를 로컬 방향으로 변환 후 "평균 법선"
      에 투영해 구한다(바깥=+, 안=-).
    - 각 버텍스(로컬): 원위치 + (이동량 x 그 버텍스의 단위 법선). 이동도 로컬 공간.
    - 워킹 피벗/좌표계는 평균 법선(월드 표시)으로 잠깐 보였다가 끝나면 복원(비파괴).
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
global pzd_switched                  -- 좌표계/피벗을 바꿨고 아직 복원 안 했는지

-- 좌표계/워킹 피벗을 드래그 전 상태로 복원 (전환했을 때만)
fn pzd_restoreCoord = (
    if pzd_switched == true do (
        if pzd_prevPivotTM != undefined do ( try ( WorkingPivot.setTM pzd_prevPivotTM ) catch () )
        if pzd_prevCoord  != undefined do ( try ( toolMode.coordsys pzd_prevCoord ) catch () )
        pzd_switched = false
    )
)

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

-- 객체(로컬) 좌표 get/set (이동은 로컬 공간에서: 주신 스크립트와 동일하게 로컬 법선 사용)
fn pzd_getObj i = (
    if pzd_isPoly then ( polyop.getVert pzd_obj i )
    else ( getVert pzd_meshCopy i )
)
fn pzd_setObj i p = (
    if pzd_isPoly then ( polyop.setVert pzd_obj i p )
    else ( setVert pzd_meshCopy i p )
)

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

-- 각 버텍스의 "로컬(객체) 법선" 배열을 계산 (sel 과 같은 순서).
--   주신 스냅 스크립트와 동일: 그 버텍스를 쓰는 페이스들의 법선 합 -> 정규화.
--   polyop.getFaceNormal 은 로컬 공간을 반환하므로 변환하지 않고 그대로 사용한다.
--   Mesh: TriMesh 의 버텍스 노멀(getNormal, 로컬). 각 버텍스가 자기 법선을 가짐.
fn pzd_vertNormals obj isPoly sel = (
    local norms = #()
    if isPoly then (
        for vi in sel do (
            local faces = polyop.getFacesUsingVert obj #{vi}
            local n = [0,0,0]
            for f in faces do n += polyop.getFaceNormal obj f
            if (length n) < 1e-9 do n = [0,0,1]
            append norms (normalize n)
        )
    ) else (
        local m = obj.mesh
        for vi in sel do (
            local n = [0,0,1]
            try ( n = getNormal m vi ) catch ()
            append norms (normalize n)
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
    pzd_switched = false
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

        -- 위치: 이동은 로컬 공간에서 하므로 로컬 원위치를 저장.
        -- 중심/평면 투영은 월드가 필요하므로 월드 위치도 따로 구해 평균.
        pzd_orig = for i in pzd_sel collect (pzd_getObj i)           -- 로컬 원위치(이동용)
        local wc = [0,0,0]
        for i in pzd_sel do wc += (pzd_getWorld i)
        pzd_center = wc / pzd_sel.count                              -- 월드 중심

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)   -- 화면 평면 법선(시선)

        -- 각 버텍스의 "자기만의" 로컬 법선 + 평균(로컬) 법선
        pzd_norm = pzd_vertNormals pzd_obj pzd_isPoly pzd_sel
        local an = [0,0,0]; for nrm in pzd_norm do an += nrm
        pzd_axis = if (length an) > 1e-6 then (normalize an) else [0,0,1]   -- 로컬 평균 법선

        -- 워킹 피벗 표시용으로 평균 법선을 월드로 변환해 Z 정렬, 좌표계 전환(끝나면 복원).
        local otm = pzd_obj.objecttransform
        local avgWorld = normalize ((pzd_axis * otm) - otm.row4)
        pzd_prevCoord   = try (getRefCoordSys()) catch (#world)
        pzd_prevPivotTM = try (WorkingPivot.getTM()) catch (undefined)
        try (
            WorkingPivot.setTM (pzd_tmFromZ avgWorld pzd_center)
            toolMode.coordsys #working_pivot
            pzd_switched = true
        ) catch ()

        pzd_offset = [args.X, args.Y] - mouse.pos                    -- 데스크톱->뷰포트 보정
        pzd_startLocal = [args.X, args.Y] - pzd_offset
        pzd_startWorld = pzd_planePt pzd_startLocal                  -- 시작점 투영(고정)
        pzd_amt = 0.0
        pzd_ok = true
    ) catch (
        format "pivotZDrag: start failed: %\n" (getCurrentException())
        pzd_ok = false
        pzd_restoreCoord()    -- 전환 후 예외 시 좌표계가 갇히지 않도록 복원
    )
)

-- 화면 평면 월드 드래그 d 를 로컬 방향으로 변환 후 평균 법선에 투영 -> 스칼라 amt
fn pzd_amtFromDrag args = (
    local cur = [args.X, args.Y] - pzd_offset
    local d   = (pzd_planePt cur) - pzd_startWorld        -- 월드 이동
    local inv = inverse pzd_obj.objecttransform
    local dObj = (d * inv) - inv.row4                      -- 월드 방향 -> 로컬 방향
    dot dObj pzd_axis                                      -- 로컬 평균 법선에 투영
)

-- [드래그 중] 각 버텍스를 자기만의 로컬 법선 방향으로 amt 만큼 이동(노멀 오프셋/인플레이트)
fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        pzd_amt = pzd_amtFromDrag args
        for k = 1 to pzd_sel.count do pzd_setObj pzd_sel[k] (pzd_orig[k] + pzd_amt * pzd_norm[k])
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
            for k = 1 to pzd_sel.count do pzd_setObj pzd_sel[k] pzd_orig[k]
            pzd_commit()
            with undo "Move Verts (vertex normals)" on (
                for k = 1 to pzd_sel.count do pzd_setObj pzd_sel[k] (pzd_orig[k] + pzd_amt * pzd_norm[k])
                pzd_commit()
            )
            redrawViews()
        )
    ) catch ( format "pivotZDrag: commit failed: %\n" (getCurrentException()) )
    pzd_restoreCoord()    -- 워킹 피벗 TM/좌표계를 드래그 전 상태로 복원(비파괴)
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

    format "pivotZDrag: started (Ctrl+Shift + middle-drag moves verts along their surface normals).\n"
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

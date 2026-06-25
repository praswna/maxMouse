/*  pivotZDrag - "Ctrl+Shift + 휠(중간버튼) 드래그 = 각 버텍스를 자기 표면 법선으로 이동" (Editable Poly 전용)
    ==========================================================================
    [개요]  ※ Editable Poly 전용 (Editable Mesh 미지원)
    Editable Poly 가 버텍스/엣지/페이스 등 서브오브젝트 레벨일 때,
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
global pzd_obj, pzd_sel, pzd_selBA, pzd_orig
global pzd_center, pzd_normal, pzd_axis, pzd_offset, pzd_startLocal, pzd_startWorld, pzd_ok
global pzd_invOTM                    -- inverse(objecttransform) 캐시 (드래그 중 불변)
global pzd_norm                      -- 각 버텍스의 월드 법선 배열(sel 과 같은 순서)
global pzd_amt                       -- 이동량(스칼라): 각 버텍스가 자기 법선으로 amt 만큼
global pzd_prevCoord                 -- 드래그 전 좌표계(끝나면 복원)
global pzd_prevPivotTM               -- 드래그 전 워킹 피벗 TM(끝나면 복원, 비파괴)
global pzd_switched                  -- 좌표계/피벗을 바꿨고 아직 복원 안 했는지
global pzd_held                      -- theHold(undo) 를 열어두었는지

-- 좌표계/워킹 피벗을 드래그 전 상태로 복원 (전환했을 때만)
fn pzd_restoreCoord = (
    if pzd_switched == true do (
        if pzd_prevPivotTM != undefined do ( try ( WorkingPivot.setTM pzd_prevPivotTM ) catch () )
        if pzd_prevCoord  != undefined do ( try ( toolMode.coordsys pzd_prevCoord ) catch () )
        pzd_switched = false
    )
)

-- ===========================================================================
--  버텍스 get (Editable Poly 전용; 이동은 로컬 공간, 중심/평면은 월드)
-- ===========================================================================
fn pzd_getWorld i = ( polyop.getVert pzd_obj i node:pzd_obj )   -- 월드(중심/평면용)
fn pzd_getObj   i = ( polyop.getVert pzd_obj i )                -- 로컬(원위치/이동용)

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

-- 각 버텍스의 "로컬(객체) 법선" 배열 (sel 순서). 주신 스냅 스크립트와 동일:
--   그 버텍스를 쓰는 페이스들의 법선 합 -> 정규화.
--   polyop.getFaceNormal 은 로컬 공간을 반환하므로 변환하지 않고 그대로 쓴다.
fn pzd_vertNormals obj sel = (
    local norms = #()
    for vi in sel do (
        local faces = polyop.getFacesUsingVert obj #{vi}
        local n = [0,0,0]
        for f in faces do n += polyop.getFaceNormal obj f
        if (length n) < 1e-9 do n = [0,0,1]
        append norms (normalize n)
    )
    norms
)

-- 현재 서브오브젝트 레벨에서 "영향받는 버텍스" 집합(비트배열)을 구함.
--   1=버텍스 / 2=엣지·3=보더(엣지가 쓰는 버텍스) / 4=폴리곤·5=엘리먼트(페이스가 쓰는 버텍스)
fn pzd_gatherVerts obj lvl = (
    case lvl of (
        1: (polyop.getVertSelection obj)
        2: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
        3: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
        4: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
        5: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
        default: #{}
    )
)

-- [드래그 시작] 선택 서브오브젝트의 버텍스 원위치/중심/시선법선/이동축 등을 저장
fn pzd_onStart sender args = (
    pzd_ok = false
    pzd_restoreCoord()    -- 이전 드래그가 미완료로 좌표계를 바꿔놨다면 먼저 원복(원본 보존)
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )   -- 잔여 hold 정리
    pzd_switched = false
    try (
        if selection.count != 1 do return false
        pzd_obj = selection[1]
        if (classof pzd_obj.baseObject != Editable_Poly) do return false   -- Editable Poly 전용

        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        pzd_selBA = pzd_gatherVerts pzd_obj lvl                     -- bitArray (일괄 setVert용, 고성능)
        pzd_sel = pzd_selBA as array
        if pzd_sel.count == 0 do return false
        pzd_invOTM = inverse pzd_obj.objecttransform               -- 1회만 (드래그 중 불변)

        -- 위치: 이동은 로컬 공간에서 하므로 로컬 원위치를 저장.
        -- 중심/평면 투영은 월드가 필요하므로 월드 위치도 따로 구해 평균.
        pzd_orig = for i in pzd_sel collect (pzd_getObj i)           -- 로컬 원위치(이동용)
        local wc = [0,0,0]
        for i in pzd_sel do wc += (pzd_getWorld i)
        pzd_center = wc / pzd_sel.count                              -- 월드 중심

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)   -- 화면 평면 법선(시선)

        -- 각 버텍스의 "자기만의" 로컬 법선 + 평균(로컬) 법선
        pzd_norm = pzd_vertNormals pzd_obj pzd_sel
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
        theHold.Begin()                                              -- 드래그 전체를 하나의 Undo 로 묶음
        pzd_held = true
        pzd_ok = true
    ) catch (
        format "pivotZDrag: start failed: %\n" (getCurrentException())
        pzd_ok = false
        if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
        pzd_restoreCoord()    -- 전환 후 예외 시 좌표계가 갇히지 않도록 복원
    )
)

-- 화면 평면 월드 드래그 d 를 로컬 방향으로 변환 후 평균 법선에 투영 -> 스칼라 amt
fn pzd_amtFromDrag args = (
    local cur = [args.X, args.Y] - pzd_offset
    local d   = (pzd_planePt cur) - pzd_startWorld        -- 월드 이동
    local dObj = (d * pzd_invOTM) - pzd_invOTM.row4        -- 월드 방향 -> 로컬 방향(캐시된 inverse)
    dot dObj pzd_axis                                      -- 로컬 평균 법선에 투영
)

-- 각 버텍스를 (로컬 원위치 + amt x 자기 법선)으로 설정.
--   vertlist=bitArray + 위치 배열로 "한 번에" 설정(고성능, 루프/개별 notify 제거).
fn pzd_applyAmt amt = (
    local posArr = for k = 1 to pzd_sel.count collect (pzd_orig[k] + amt * pzd_norm[k])
    polyop.setVert pzd_obj pzd_selBA posArr                -- 1회 호출
)

-- [드래그 중] 각 버텍스를 자기만의 로컬 법선 방향으로 amt 만큼 이동(노멀 오프셋/인플레이트)
fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        pzd_amt = pzd_amtFromDrag args
        pzd_applyAmt pzd_amt
        redrawViews()
    ) catch ( format "pivotZDrag: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] 드래그 전체가 theHold 안에서 일어났으므로, 움직였으면 Accept(단일 Undo),
--   안 움직였으면 Cancel(빈 Undo 안 만듦). 라이브 위치를 원복했다 재적용하는 단계 불필요.
fn pzd_onEnd sender args = (
    if not pzd_ok do return false
    pzd_ok = false
    try (
        if pzd_held == true do (
            if (abs pzd_amt) > 1e-6 then theHold.Accept "Move Verts (vertex normals)"
            else theHold.Cancel()
            pzd_held = false
        )
        redrawViews()
    ) catch (
        format "pivotZDrag: commit failed: %\n" (getCurrentException())
        if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    )
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
        -- Editable Poly + 서브오브젝트 레벨(1~5)일 때만 무장
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly)
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
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )   -- 열린 hold 정리
    pzd_restoreCoord()    -- 드래그 중 정지해도 좌표계/피벗 복원
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

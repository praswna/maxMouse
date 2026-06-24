/*  shiftVertexDrag - "Shift + 휠(중간버튼) 드래그 = 버텍스를 화면 평면으로 이동"
    ==========================================================================
    [개요]
    Editable Poly / Editable Mesh 가 버텍스/엣지/페이스 등 서브오브젝트 레벨일 때,
    SHIFT 를 누른 채 중간(휠) 버튼으로 드래그하면 선택 서브오브젝트(가 사용하는
    버텍스들)가 화면과 평행한 평면을 따라 커서를 1:1로 따라 이동합니다.
    (이때 뷰포트는 팬되지 않음. 엣지/페이스는 구성 버텍스를 옮기는 방식)

    - 중간버튼 "단독"은 평소대로 팬으로 동작합니다.
    - 왼쪽 버튼은 절대 건드리지 않습니다.
    - 한 번의 드래그는 한 번의 Undo("Move Verts (screen)")로 기록됩니다.

    [독립성] maxMouse 와 완전히 분리된 단독 모듈입니다.
        - C# 네임스페이스: ShiftVertexMove
        - 전역변수 접두사: svm_
        - 콜백 ID: #shiftVertexDrag
    동시에 maxMouse 의 중간버튼 기능을 켜면 Shift+중간을 둘 다 처리(이중 후킹)
    하므로, 둘 중 하나만 사용하세요.

    [요구사항] 같은 폴더에 companion 파일 ShiftVertexHook.cs 가 있어야 합니다.
    [실행] Scripting > Run Script -> shiftVertexDrag.ms (실행 즉시 시작되고,
        "shiftVertexDrag Toggle" 매크로가 등록됩니다. 카테고리: shiftVertexDrag)
    ==========================================================================
*/

-- [전역변수] 핸들/상태를 세션 동안 보존 (GC 방지 + 이벤트 핸들러 간 공유)
global svm_hook                 -- C# 후크 인스턴스
global svm_asm                  -- 컴파일된 어셈블리
global svm_obj, svm_isPoly, svm_meshCopy, svm_sel, svm_orig
global svm_center, svm_normal, svm_offset, svm_startLocal, svm_startWorld, svm_delta, svm_ok

-- ===========================================================================
--  버텍스 화면 평면 이동 (실제 계산부)
-- ===========================================================================

-- 버텍스 i 의 "월드 좌표"를 읽기 (Poly/Mesh 분기)
--   Poly: polyop.getVert 에 node: 를 주면 월드 좌표로 반환 (견고)
--   Mesh: 객체공간 좌표 * 노드 변환행렬 = 월드 좌표
fn svm_getWorld i = (
    if svm_isPoly then ( polyop.getVert svm_obj i node:svm_obj )
    else ( (getVert svm_meshCopy i) * svm_obj.objecttransform )
)

-- 버텍스 i 를 "월드 좌표 wp" 로 설정 (Poly/Mesh 분기)
--   Mesh: 월드 -> 객체공간 변환 후 메시 복사본에 기록
fn svm_setWorld i wp = (
    if svm_isPoly then ( polyop.setVert svm_obj i wp node:svm_obj )
    else ( setVert svm_meshCopy i (wp * (inverse svm_obj.objecttransform)) )
)

-- Mesh 일 때만 변경된 메시 복사본을 노드에 반영 (Poly 는 setVert 가 즉시 반영)
fn svm_commit = ( if not svm_isPoly do ( svm_obj.mesh = svm_meshCopy; update svm_obj.mesh ) )

-- 화면 좌표 p 를 "드래그 평면" 위의 월드 좌표로 투영
--   p 에서 쏜 광선(mapScreenToWorldRay)과, 선택중심을 지나고 시선에 수직인
--   평면(center, normal)의 교점을 구한다. denom 이 0에 가까우면(평면을 스치는
--   각도) 중심점을 반환해 0으로 나누기를 회피.
fn svm_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir svm_normal
    if (abs denom) < 1e-7 then svm_center
    else ( local t = (dot (svm_center - r.pos) svm_normal) / denom; r.pos + t * r.dir )
)

-- 현재 서브오브젝트 레벨에서 "영향받는 버텍스" 집합(비트배열)을 구함.
--   1=버텍스: 선택 버텍스 그대로
--   2=엣지 / 3=보더: 선택 엣지가 사용하는 버텍스
--   4=폴리곤 / 5=엘리먼트: 선택 페이스가 사용하는 버텍스
fn svm_gatherVerts obj isPoly lvl = (
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
        -- Editable Mesh (best-effort)
        case lvl of (
            1: (getVertSelection obj)
            2: (try (meshop.getVertsUsingEdge obj (getEdgeSelection obj)) catch (#{}))
            default: (try (meshop.getVertsUsingFace obj (getFaceSelection obj)) catch (#{}))
        )
    )
)

-- [드래그 시작] Shift+중간 down 시 후크가 보낸 VertexDragStart 이벤트 처리.
--   현재 선택 버텍스의 월드 원위치/중심/평면법선과, 화면<->뷰포트 좌표 보정값을
--   저장한다. 유효하지 않으면(객체 아님/선택 0개) svm_ok=false 로 두어 무시.
fn svm_onStart sender args = (
    svm_ok = false
    try (
        if selection.count != 1 do return false           -- 단일 선택만 지원
        svm_obj = selection[1]
        local b = svm_obj.baseObject
        svm_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (svm_isPoly or isMesh) do return false      -- Poly/Mesh 만

        svm_meshCopy = if isMesh then svm_obj.mesh else undefined
        -- 현재 레벨(버텍스/엣지/페이스)에서 영향받는 버텍스 집합을 모음
        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        svm_sel = (svm_gatherVerts svm_obj svm_isPoly lvl) as array
        if svm_sel.count == 0 do return false               -- 옮길 버텍스 없으면 무동작

        -- 원위치(월드) 저장 + 중심점 계산
        svm_orig = for i in svm_sel collect (svm_getWorld i)
        local c = [0,0,0]; for w in svm_orig do c += w
        svm_center = c / svm_orig.count
        -- 평면 법선 = 뷰(카메라) Z축 = 시선 방향
        svm_normal = normalize ((inverse (viewport.getTM())).row3)

        -- args 는 데스크톱(전역) 좌표 / mouse.pos 는 활성 뷰포트 좌표
        --   offset = 데스크톱 - 뷰포트  -> 이후 (데스크톱 - offset) = 뷰포트 좌표
        svm_offset = [args.X, args.Y] - mouse.pos
        svm_startLocal = [args.X, args.Y] - svm_offset
        svm_startWorld = svm_planePt svm_startLocal         -- 시작점 투영 1회만 (드래그 내내 고정)
        svm_delta = [0,0,0]
        svm_ok = true
    ) catch ( format "shiftVertexDrag: start failed: %\n" (getCurrentException()); svm_ok = false )
)

-- [드래그 중] 후크가 보낸 VertexDragMove 마다 호출.
--   현재 커서를 평면에 투영해 시작점과의 차이(=월드 이동량)를 구하고,
--   모든 선택 버텍스를 (원위치 + 이동량)으로 갱신 후 즉시 리드로우.
fn svm_onMove sender args = (
    if not svm_ok do return false
    try (
        local cur = [args.X, args.Y] - svm_offset           -- 데스크톱 -> 뷰포트 좌표
        svm_delta = (svm_planePt cur) - svm_startWorld       -- 월드 이동량
        for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
        svm_commit()
        redrawViews()
    ) catch ( format "shiftVertexDrag: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] VertexDragEnd 시 호출.
--   라이브 이동은 undo 없이 적용됐으므로: (1) 원위치로 되돌린 뒤
--   (2) undo 블록 안에서 최종 위치를 재적용 -> "한 번의 깨끗한 Undo" 생성.
fn svm_onEnd sender args = (
    if not svm_ok do return false
    svm_ok = false
    try (
        if (length svm_delta) > 1e-6 do (                    -- 실제로 움직였을 때만
            for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] svm_orig[k]   -- 원위치 복원(undo 없음)
            svm_commit()
            with undo "Move Verts (screen)" on (             -- 단일 Undo 로 재적용
                for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
                svm_commit()
            )
            redrawViews()
        )
    ) catch ( format "shiftVertexDrag: commit failed: %\n" (getCurrentException()) )
)

-- ===========================================================================
--  무장(Arm) : "지금 버텍스 레벨인가?" 만 후크에 알려줌 (이벤트 기반, 폴링 없음)
-- ===========================================================================

-- 현재 상태를 보고 후크의 Armed 플래그를 갱신.
--   조건: 단일 Editable Poly/Mesh + 서브오브젝트 레벨이 버텍스(=1).
--   (Shift 동시 누름은 후크가 직접 감지하므로 여기선 레벨만 따짐)
fn svm_poll = (
    if svm_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)           -- 모디파이 패널 아닐 때 undefined 가능
        if lvl == undefined do lvl = 0
        -- 버텍스(1)/엣지(2)/보더(3)/폴리곤(4)/엘리먼트(5) 어느 레벨이든 무장
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    svm_hook.Armed = armed
)

-- 콜백 1개 등록 헬퍼 (없는 콜백 이름이면 try 로 조용히 무시)
fn svm_addCb evt = (
    try ( callbacks.addScript evt "if (svm_poll != undefined) do svm_poll()" id:#shiftVertexDrag ) catch ()
)

-- ===========================================================================
--  컴파일 + 시작 / 정지
-- ===========================================================================

-- 이 스크립트 파일이 있는 폴더 경로 (companion .cs 를 찾기 위함)
fn svm_thisDir = (
    local p = undefined
    try ( p = getThisScriptFilename() ) catch ()             -- 2016+ 권장
    if p == undefined do ( try ( p = getSourceFileName() ) catch () )   -- 구버전 대비
    if p == undefined do throw "shiftVertexDrag: cannot resolve script path; run via Scripting > Run Script."
    getFilenamePath p
)

-- 옆의 ShiftVertexHook.cs 를 읽어 메모리에 런타임 컴파일 -> svm_asm 에 보관
fn svm_compile = (
    local csPath = (svm_thisDir()) + "ShiftVertexHook.cs"
    if not (doesFileExist csPath) do throw ("shiftVertexDrag: companion file not found: " + csPath)

    -- 파일 전체를 문자열로 읽기
    local fs = openFile csPath mode:"r"
    local src = ""
    while not (eof fs) do src += (readLine fs) + "\n"
    close fs

    -- .NET C# 컴파일러 준비 (UI/메시지창에 필요한 어셈블리 참조)
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true                        -- 디스크에 안 쓰고 메모리에만
    params.GenerateExecutable = false                       -- DLL(라이브러리)로

    local res = prov.CompileAssemblyFromSource params #(src)
    if res.Errors.HasErrors do (                            -- 컴파일 에러 모아서 보고
        local m = "shiftVertexDrag: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    svm_asm = res.CompiledAssembly
)

-- [시작] 컴파일 -> 후크 인스턴스 생성 -> 이벤트 연결 -> 후크 가동 -> 콜백 등록
fn shiftVertexDrag_start = (
    if svm_hook != undefined and svm_hook.IsRunning do (
        format "shiftVertexDrag: already running.\n"
        return false
    )
    svm_compile()

    -- 컴파일된 어셈블리에서 후크 타입을 찾아 인스턴스화
    local t = svm_asm.GetType "ShiftVertexMove.VertexDragHook"
    svm_hook = (dotNetClass "System.Activator").CreateInstance t
    svm_hook.Modifier = 3     -- 트리거 수정자: 0=없음, 1=Ctrl, 2=Alt, 3=Shift

    -- 후크가 보내는 .NET 이벤트를 MAXScript 핸들러에 연결
    dotNet.addEventHandler svm_hook "VertexDragStart" svm_onStart
    dotNet.addEventHandler svm_hook "VertexDragMove"  svm_onMove
    dotNet.addEventHandler svm_hook "VertexDragEnd"   svm_onEnd

    svm_hook.Start()          -- 전역 마우스 후크 + 메시지 전용 창 설치

    -- 선택/레벨 변화 시 Armed 를 갱신하도록 콜백 등록 (폴링 타이머 없음)
    callbacks.removeScripts id:#shiftVertexDrag
    svm_addCb #selectionSetChanged           -- 노드 선택 변경
    svm_addCb #modPanelSubObjectLevelChanged  -- 서브오브젝트 레벨 변경
    svm_addCb #modPanelSelectionSetChanged    -- 모디파이 패널이 새 선택을 열 때
    svm_addCb #modPanelObjPostChange
    -- Max 종료 시 후크 자동 해제 (전역 후크 누수 방지)
    callbacks.addScript #preSystemShutdown "if (shiftVertexDrag_stop != undefined) do shiftVertexDrag_stop()" id:#shiftVertexDrag
    svm_poll()                -- 현재 상태로 한 번 동기화

    format "shiftVertexDrag: started (Shift + middle-drag moves verts in screen space).\n"
    true
)

-- [정지] 콜백 제거 + 후크 해제(후크 + 메시지 창 정리)
fn shiftVertexDrag_stop = (
    callbacks.removeScripts id:#shiftVertexDrag
    if svm_hook != undefined do ( try ( svm_hook.Stop() ) catch (); svm_hook = undefined )
    format "shiftVertexDrag: stopped.\n"
)

-- [토글] 켜져 있으면 끄고, 꺼져 있으면 켜기
fn shiftVertexDrag_toggle = (
    if (svm_hook != undefined and svm_hook.IsRunning) then shiftVertexDrag_stop() else shiftVertexDrag_start()
)

-- 툴바 버튼용 매크로 (Customize > Toolbars > 카테고리 shiftVertexDrag)
macroScript shiftVertexDrag_Toggle
    category:"shiftVertexDrag" buttontext:"ShiftVertDrag" tooltip:"Toggle Shift+middle vertex drag"
( on execute do ( if (shiftVertexDrag_toggle != undefined) do shiftVertexDrag_toggle() ) )

-- 스크립트를 실행하면 곧바로 시작
try ( shiftVertexDrag_start() )
catch ( format "shiftVertexDrag: failed to start: %\n" (getCurrentException()) )

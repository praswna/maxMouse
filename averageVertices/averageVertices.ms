/*  averageVertices - 선택 버텍스를 이웃 평균으로 이동(릴렉스/스무딩) - 3ds Max (Editable Poly)
    ==========================================================================
    [개요]
    선택한 버텍스(또는 선택 엣지/페이스가 쓰는 버텍스)를 "이웃 버텍스들의 평균
    위치"로 이동시킵니다. = 릴렉스 / 라플라시안 스무딩. 반복할수록 더 매끄러워짐.
    (선택 경계는 주변 메시로 자연스럽게 섞입니다.)

    실행 방법 2가지 (둘 다 매크로 등록 -> Customize 에서 단축키 지정):
      1) "Average Vertices"        - 누르면 즉시 1회 적용 (현재 강도값 사용)
      2) "Average Vertices (Caddy)"- 커서 옆에 테두리 없는 작은 띠를 띄워, 좌우로
         드래그해 Weight 를 실시간 미리보기하며 조절. 떼면 확정(단일 Undo),
         우클릭/Esc 취소, Enter 확정.

    [독립성] 다른 모듈과 무관. 전역 접두사 avgv_. C#/후크 없음(MAXScript만).
    [실행] Scripting > Run Script -> averageVertices.ms  (매크로 등록)
    ==========================================================================
*/

global avgv_iterations               -- 반복 횟수 (많을수록 더 스무딩)
global avgv_weight                   -- 0..1, 이웃 평균으로 이동하는 비율 (1=완전 평균)
if avgv_iterations == undefined do avgv_iterations = 1
if avgv_weight == undefined do avgv_weight = 1.0

-- 단일 Editable Poly 노드 반환 (아니면 undefined)
fn avgv_obj = (
    if selection.count != 1 do return undefined
    local o = selection[1]
    if (classof o.baseObject != Editable_Poly) do return undefined
    o
)

-- 현재 서브오브젝트 레벨에서 "대상 버텍스" 집합(비트배열).
--   1=버텍스 / 2=엣지·3=보더(엣지가 쓰는 버텍스) / 4=폴리곤·5=엘리먼트(페이스가 쓰는 버텍스)
fn avgv_gatherVerts o lvl = (
    case lvl of (
        1: (polyop.getVertSelection o)
        2: (polyop.getVertsUsingEdge o (polyop.getEdgeSelection o))
        3: (polyop.getVertsUsingEdge o (polyop.getEdgeSelection o))
        4: (polyop.getVertsUsingFace o (polyop.getFaceSelection o))
        5: (polyop.getVertsUsingFace o (polyop.getFaceSelection o))
        default: (polyop.getVertSelection o)
    )
)

-- 대상 버텍스의 이웃 목록(엣지로 연결된 버텍스 - 자기 자신) 계산. 토폴로지 불변이라 1회만.
fn avgv_neighborLists o selArr = (
    for vi in selArr collect (
        local e = polyop.getEdgesUsingVert o #{vi}
        ((polyop.getVertsUsingEdge o e) - #{vi}) as array
    )
)

-- [최적화] 토폴로지 캐시: 같은 (객체/정점수/선택) 이면 이웃목록과 선택색인을 재사용.
--   이웃목록 계산은 선택당 2N 번의 polyop 호출이라 "할때마다" 반복되면 가장 비쌈 -> 캐시로 제거.
--   selIdx: 정점인덱스 -> selArr 내 위치 k (선택 아니면 undefined). relaxCompute 가 이웃이
--   "선택(움직임)인지 vs 고정인지" 를 O(1) 로 판별하는 데 사용 -> nv 크기 배열 복사 제거.
global avgv_cacheObj, avgv_cacheNV, avgv_cacheSelBA, avgv_cacheNbr, avgv_cacheSelIdx
fn avgv_topo o selBA selArr = (
    local nv = polyop.getNumVerts o
    if (avgv_cacheObj == o and avgv_cacheNV == nv and \
        avgv_cacheSelBA != undefined and avgv_cacheSelBA == selBA) then (
        #(avgv_cacheNbr, avgv_cacheSelIdx)                 -- 캐시 적중: 재계산 없음
    ) else (
        local nbr = avgv_neighborLists o selArr
        local selIdx = #(); selIdx[nv] = undefined
        for k = 1 to selArr.count do selIdx[selArr[k]] = k
        avgv_cacheObj = o; avgv_cacheNV = nv
        avgv_cacheSelBA = (#{} + selBA)                    -- 외부 변형과 분리된 사본
        avgv_cacheNbr = nbr; avgv_cacheSelIdx = selIdx
        #(nbr, selIdx)
    )
)

-- 관련 버텍스(선택+이웃) 위치 스냅샷. vertexIndex -> point3 (나머지는 undefined).
fn avgv_snapBase o selBA nbrLists = (
    local involved = #{} + selBA                                      -- selBA 와 독립된 새 bitArray
    for nbrs in nbrLists do for n in nbrs do involved[n] = true        -- 선택 + 모든 이웃
    local nv = polyop.getNumVerts o
    local base = #(); base[nv] = undefined
    for vi in involved do base[vi] = polyop.getVert o vi
    base
)

-- 메모리 안에서 릴렉스 계산 (object 미접근, 빠름). basePos 는 스냅샷 배열, selIdx 는 선택색인.
--   [최적화] nv 크기 배열을 매번 copy 하지 않음: 움직이는 건 선택 버텍스뿐이므로 작은 배열
--   cur(=선택 위치, 크기 = 선택수)만 갱신. 이웃이 선택이면 cur[selIdx[n]](이전 반복값),
--   선택이 아니면 basePos[n](고정값)을 읽음. Jacobi(이전 상태에서 계산). 최종 선택 위치 반환.
fn avgv_relaxCompute selArr selIdx nbrLists basePos w iters = (
    local n = selArr.count
    local cur = for k = 1 to n collect basePos[selArr[k]]             -- 선택 버텍스의 현재 위치(작은 배열)
    for iter = 1 to iters do (
        local nxt = for k = 1 to n collect (
            local nbrs = nbrLists[k]
            if nbrs.count == 0 then cur[k]                            -- 고립 버텍스: 유지
            else (
                local s = [0,0,0]
                for nb in nbrs do (
                    local si = selIdx[nb]
                    s += (if si != undefined then cur[si] else basePos[nb])
                )
                local op = cur[k]
                op + w * ((s / nbrs.count) - op)                      -- weight 만큼 평균으로
            )
        )
        cur = nxt
    )
    cur
)

-- 즉시용: object 에서 스냅샷 -> 계산 -> setVert 1회
fn avgv_relaxN o selBA selArr nbrLists selIdx w iters = (
    local base = avgv_snapBase o selBA nbrLists
    polyop.setVert o selBA (avgv_relaxCompute selArr selIdx nbrLists base w iters)
)

-- ===========================================================================
--  즉시 실행 (현재 강도값으로 1회, 단일 Undo)
-- ===========================================================================
fn avgv_run = (
    local o = avgv_obj()
    if o == undefined do ( format "averageVertices: 단일 Editable Poly 를 선택하세요.\n"; return false )
    local lvl = try (subobjectLevel) catch (1)
    if lvl == undefined do lvl = 1
    if lvl < 1 do ( format "averageVertices: 서브오브젝트(버텍스/엣지/페이스) 레벨에서 선택하세요.\n"; return false )

    local selBA  = avgv_gatherVerts o lvl
    local selArr = selBA as array
    if selArr.count == 0 do ( format "averageVertices: 선택된 것이 없습니다.\n"; return false )
    local topo = avgv_topo o selBA selArr               -- 이웃목록/선택색인 (캐시됨)
    local nbrLists = topo[1]; local selIdx = topo[2]

    local okk = true
    theHold.Begin()
    try ( avgv_relaxN o selBA selArr nbrLists selIdx avgv_weight avgv_iterations )
    catch ( okk = false; format "averageVertices: 적용 실패: %\n" (getCurrentException()) )
    if okk then ( theHold.Accept "Average Vertices" ) else ( theHold.Cancel() )
    redrawViews()
    okk
)

-- ===========================================================================
--  캐디형 팝업 (커서 옆 작은 창, 실시간 미리보기)
-- ===========================================================================
global avgv_cO, avgv_cSelBA, avgv_cSelArr, avgv_cNbr, avgv_cSelIdx, avgv_cOrig, avgv_cBase

-- 선택을 캡처하고 원본 위치를 스냅샷 (성공하면 true)
fn avgv_caddyStart = (
    avgv_cO = undefined
    local o = avgv_obj()
    if o == undefined do ( format "averageVertices: 단일 Editable Poly 를 선택하세요.\n"; return false )
    local lvl = try (subobjectLevel) catch (1)
    if lvl == undefined do lvl = 1
    if lvl < 1 do ( format "averageVertices: 서브오브젝트 레벨에서 선택하세요.\n"; return false )
    local selBA = avgv_gatherVerts o lvl
    local selArr = selBA as array
    if selArr.count == 0 do ( format "averageVertices: 선택된 것이 없습니다.\n"; return false )

    avgv_cO = o
    avgv_cSelBA = selBA
    avgv_cSelArr = selArr
    local topo = avgv_topo o selBA selArr                              -- 이웃목록/선택색인 (캐시됨)
    avgv_cNbr = topo[1]; avgv_cSelIdx = topo[2]
    avgv_cOrig = for vi in selArr collect (polyop.getVert o vi)        -- 선택 버텍스 원본(취소 복원용)
    avgv_cBase = avgv_snapBase o selBA avgv_cNbr                       -- 선택+이웃 원본 스냅샷(계산용, 1회)
    true
)

-- 미리보기: 메모리 스냅샷에서 계산 -> setVert "1회"만 (원본 복원 단계 없음 = 깜박임 없음)
fn avgv_caddyPreview = (
    if avgv_cO == undefined do return false
    try (
        local finalSel = avgv_relaxCompute avgv_cSelArr avgv_cSelIdx avgv_cNbr avgv_cBase avgv_weight avgv_iterations
        polyop.setVert avgv_cO avgv_cSelBA finalSel
        redrawViews()
    ) catch ( format "averageVertices: preview 실패: %\n" (getCurrentException()) )
)

-- 확정: 원본 복원 후 theHold 안에서 재적용 -> 단일 Undo
fn avgv_caddyCommit = (
    if avgv_cO == undefined do return false
    try (
        polyop.setVert avgv_cO avgv_cSelBA avgv_cOrig                  -- undo 캡처 기준을 원본으로
        theHold.Begin()
        polyop.setVert avgv_cO avgv_cSelBA (avgv_relaxCompute avgv_cSelArr avgv_cSelIdx avgv_cNbr avgv_cBase avgv_weight avgv_iterations)
        theHold.Accept "Average Vertices"
        redrawViews()
    ) catch ( try (theHold.Cancel()) catch (); format "averageVertices: 확정 실패: %\n" (getCurrentException()) )
    avgv_cO = undefined        -- 종료 표시(이후 close 핸들러의 취소를 무효화)
)

-- 취소: 원본으로 되돌리고 종료
fn avgv_caddyCancel = (
    if avgv_cO != undefined do (
        try ( polyop.setVert avgv_cO avgv_cSelBA avgv_cOrig; redrawViews() ) catch ()
        avgv_cO = undefined
    )
)

-- 테두리 없는 작은 창 + 마우스 드래그로 Weight 스크럽 (실시간 미리보기).
--   좌클릭 드래그(좌우) = Weight 조절, 떼면 확정(단일 Undo).
--   우클릭 / Esc = 취소,  Enter = 확정.
global avgv_form, avgv_lbl, avgv_scrubbing, avgv_startX, avgv_startW
global avgv_lastPrevW                 -- 마지막으로 미리보기한 weight (중복 갱신 방지)

-- 컨트롤의 protected DoubleBuffered 속성을 reflection 으로 켬 (라벨 글자 깜박임 제거).
--   라벨은 .Text 가 바뀔 때마다 배경을 지우고 다시 그려서 깜박이는데, 더블버퍼링이면
--   오프스크린에 그린 뒤 한 번에 표시하므로 깜박임/가려짐이 사라진다.
fn avgv_setDB ctrl = (
    try (
        local bf = dotNetClass "System.Reflection.BindingFlags"
        local pi = ctrl.GetType().GetProperty "DoubleBuffered" (bf.Instance + bf.NonPublic)
        if pi != undefined do pi.SetValue ctrl true
    ) catch ()
)

fn avgv_lblText = (
    if avgv_lbl != undefined do (
        local n = (avgv_weight * 12.0) as integer
        local bar = ""
        for i = 1 to 12 do bar += (if i <= n then "|" else ".")
        local s = ("  W " + (formattedPrint avgv_weight format:".2f") + "  [" + bar + "]")
        if avgv_lbl.Text != s do avgv_lbl.Text = s        -- 동일 문자열이면 다시 그리지 않음
    )
)

fn avgv_scrubEnd doCommit = (
    if avgv_form == undefined do return false
    avgv_scrubbing = false
    local f = avgv_form
    avgv_form = undefined                 -- 재진입 방지
    if doCommit then avgv_caddyCommit() else avgv_caddyCancel()
    try ( f.Close() ) catch ()
)

fn avgv_onMD s e = (
    if (e.Button.ToString() == "Right") then avgv_scrubEnd false
    else (
        avgv_scrubbing = true
        avgv_startX = (dotNetClass "System.Windows.Forms.Control").MousePosition.X
        avgv_startW = avgv_weight
        try ( avgv_lbl.Capture = true ) catch ()
    )
)
fn avgv_onMM s e = (
    if avgv_scrubbing == true do (
        local sx = (dotNetClass "System.Windows.Forms.Control").MousePosition.X
        avgv_weight = amax 0.0 (amin 1.0 (avgv_startW + (sx - avgv_startX) * 0.006))   -- ~170px=0..1
        if avgv_weight != avgv_lastPrevW do (        -- 값이 실제로 바뀐 경우만 갱신(끝단 클램프 시 낭비 제거)
            avgv_lastPrevW = avgv_weight
            avgv_lblText()
            avgv_caddyPreview()
        )
    )
)
fn avgv_onMU s e = (
    if avgv_scrubbing == true do ( try ( avgv_lbl.Capture = false ) catch (); avgv_scrubEnd true )
)
fn avgv_onKey s e = (
    local k = e.KeyCode.ToString()
    if k == "Escape" then avgv_scrubEnd false
    else if k == "Return" then avgv_scrubEnd true
)

-- 캐디를 "커서 옆"에 띄움 (테두리 없음)
fn avgv_caddy = (
    if avgv_form != undefined do avgv_scrubEnd false        -- 이미 떠 있는 캐디 정리(중복 방지)
    if not (avgv_caddyStart()) do return false
    avgv_scrubbing = false

    avgv_form = dotNetObject "System.Windows.Forms.Form"
    avgv_form.FormBorderStyle = (dotNetClass "System.Windows.Forms.FormBorderStyle").None
    avgv_form.StartPosition   = (dotNetClass "System.Windows.Forms.FormStartPosition").Manual
    avgv_form.TopMost       = true
    avgv_form.ShowInTaskbar = false
    avgv_form.KeyPreview    = true
    avgv_form.Width = 150; avgv_form.Height = 24
    avgv_form.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 40 40 44
    avgv_setDB avgv_form                       -- 폼 더블버퍼링(깜박임 방지)
    local p = (dotNetClass "System.Windows.Forms.Control").MousePosition
    avgv_form.Location = dotNetObject "System.Drawing.Point" (p.X + 12) (p.Y - 12)

    avgv_lbl = dotNetObject "System.Windows.Forms.Label"
    avgv_lbl.Dock      = (dotNetClass "System.Windows.Forms.DockStyle").Fill
    avgv_lbl.TextAlign = (dotNetClass "System.Drawing.ContentAlignment").MiddleLeft
    avgv_lbl.ForeColor = (dotNetClass "System.Drawing.Color").White
    avgv_lbl.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 40 40 44
    avgv_lbl.Font      = dotNetObject "System.Drawing.Font" "Segoe UI" 9
    avgv_lbl.Cursor    = (dotNetClass "System.Windows.Forms.Cursors").SizeWE
    avgv_form.Controls.Add avgv_lbl
    avgv_setDB avgv_lbl                        -- 라벨 더블버퍼링(.Text 갱신 시 깜박임 제거)

    dotNet.addEventHandler avgv_lbl  "MouseDown" avgv_onMD
    dotNet.addEventHandler avgv_lbl  "MouseMove" avgv_onMM
    dotNet.addEventHandler avgv_lbl  "MouseUp"   avgv_onMU
    dotNet.addEventHandler avgv_form "KeyDown"   avgv_onKey

    avgv_lblText()
    avgv_caddyPreview()       -- 현재 값으로 즉시 미리보기 (Show 전에 1회)
    avgv_lastPrevW = avgv_weight              -- 이후 드래그에서 값이 바뀔 때만 갱신
    avgv_form.Show()
    avgv_form.Activate()
    true
)

-- ===========================================================================
--  매크로 (Customize > Hotkeys / Toolbars, 카테고리 #MyKUI)
-- ===========================================================================
macroScript Average_Vertices
    category:"#MyKUI"
    tooltip:"Average Vertices"
( on execute do ( if (avgv_run != undefined) do avgv_run() ) )

macroScript Average_Vertices_Caddy
    category:"#MyKUI"
    tooltip:"Average Vertices(Caddy)"
( on execute do ( if (avgv_caddy != undefined) do avgv_caddy() ) )

format "averageVertices: 준비됨. Customize 에서 'Average Vertices' / 'Average Vertices (Caddy)'\n"
format "                 (카테고리 #MyKUI)에 단축키를 지정하세요.\n"

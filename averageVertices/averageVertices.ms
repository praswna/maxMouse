/*  averageVertices - Maya 의 "Average Vertices" 를 3ds Max 에 구현 (Editable Poly)
    ==========================================================================
    [개요]
    선택한 버텍스(또는 선택 엣지/페이스가 쓰는 버텍스)를 "이웃 버텍스들의 평균
    위치"로 이동시킵니다. = 릴렉스 / 라플라시안 스무딩. 반복할수록 더 매끄러워짐.
    Maya 의 Mesh > Average Vertices 와 동일한 동작.

    실행 방법 2가지 (둘 다 매크로 등록 -> Customize 에서 단축키 지정):
      1) "Average Vertices"        - 누르면 즉시 1회 적용 (현재 강도값 사용)
      2) "Average Vertices (Caddy)"- 커서 옆에 작은 창을 띄워 Weight/Iterations 를
         스피너로 실시간 미리보기하며 조절, OK 로 확정(단일 Undo) / Cancel 로 취소

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

-- 릴렉스 본체 (속도 최적화).
--   관련 버텍스(선택+이웃) 위치를 1회만 getVert 로 스냅샷 -> 반복은 전부 배열 안에서
--   계산(object I/O 없음) -> 마지막에 setVert 1회. Jacobi(이전 상태에서 계산).
fn avgv_relaxN o selBA selArr nbrLists w iters = (
    local involved = #{} + selBA                                      -- selBA 와 독립된 새 bitArray
    for nbrs in nbrLists do for n in nbrs do involved[n] = true        -- 선택 + 모든 이웃
    local nv = polyop.getNumVerts o
    local pos = #(); pos[nv] = undefined                              -- 인덱스 접근용 배열
    for vi in involved do pos[vi] = polyop.getVert o vi                -- 스냅샷 1회

    for iter = 1 to iters do (
        local newSel = for k = 1 to selArr.count collect (
            local nbrs = nbrLists[k]
            if nbrs.count == 0 then pos[selArr[k]]                     -- 고립 버텍스: 유지
            else (
                local s = [0,0,0]
                for n in nbrs do s += pos[n]
                local op = pos[selArr[k]]
                op + w * ((s / nbrs.count) - op)                       -- weight 만큼 평균으로
            )
        )
        for k = 1 to selArr.count do pos[selArr[k]] = newSel[k]        -- 다음 반복용으로 배열에 기록
    )
    polyop.setVert o selBA (for k = 1 to selArr.count collect pos[selArr[k]])   -- 1회 일괄 적용
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
    local nbrLists = avgv_neighborLists o selArr

    local okk = true
    theHold.Begin()
    try ( avgv_relaxN o selBA selArr nbrLists avgv_weight avgv_iterations )
    catch ( okk = false; format "averageVertices: 적용 실패: %\n" (getCurrentException()) )
    if okk then ( theHold.Accept "Average Vertices" ) else ( theHold.Cancel() )
    redrawViews()
    if okk do format "averageVertices: 버텍스 % 개, 반복 % 회 적용.\n" selArr.count avgv_iterations
    okk
)

-- ===========================================================================
--  캐디형 팝업 (커서 옆 작은 창, 실시간 미리보기)
-- ===========================================================================
global avgv_cO, avgv_cSelBA, avgv_cSelArr, avgv_cNbr, avgv_cOrig

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
    avgv_cNbr = avgv_neighborLists o selArr
    avgv_cOrig = for vi in selArr collect (polyop.getVert o vi)        -- 원본 스냅샷
    true
)

-- 미리보기: 원본 복원 후 현재 값으로 릴렉스(undo 없음)
fn avgv_caddyPreview = (
    if avgv_cO == undefined do return false
    try (
        polyop.setVert avgv_cO avgv_cSelBA avgv_cOrig                  -- 원본 복원
        avgv_relaxN avgv_cO avgv_cSelBA avgv_cSelArr avgv_cNbr avgv_weight avgv_iterations
        redrawViews()
    ) catch ( format "averageVertices: preview 실패: %\n" (getCurrentException()) )
)

-- 확정: 원본 복원 후 theHold 안에서 재적용 -> 단일 Undo
fn avgv_caddyCommit = (
    if avgv_cO == undefined do return false
    try (
        polyop.setVert avgv_cO avgv_cSelBA avgv_cOrig
        theHold.Begin()
        avgv_relaxN avgv_cO avgv_cSelBA avgv_cSelArr avgv_cNbr avgv_weight avgv_iterations
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

fn avgv_lblText = (
    if avgv_lbl != undefined do (
        local n = (avgv_weight * 12.0) as integer
        local bar = ""
        for i = 1 to 12 do bar += (if i <= n then "|" else ".")
        avgv_lbl.Text = ("  W " + (formattedPrint avgv_weight format:".2f") + "  [" + bar + "]")
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
        avgv_lblText()
        avgv_caddyPreview()
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

    dotNet.addEventHandler avgv_lbl  "MouseDown" avgv_onMD
    dotNet.addEventHandler avgv_lbl  "MouseMove" avgv_onMM
    dotNet.addEventHandler avgv_lbl  "MouseUp"   avgv_onMU
    dotNet.addEventHandler avgv_form "KeyDown"   avgv_onKey

    avgv_lblText()
    avgv_caddyPreview()       -- 현재 값으로 즉시 미리보기 (Show 전에 1회)
    avgv_form.Show()
    avgv_form.Activate()
    true
)

-- ===========================================================================
--  매크로 (Customize > Hotkeys / Toolbars, 카테고리 averageVertices)
-- ===========================================================================
macroScript Average_Vertices
    category:"averageVertices" buttontext:"Average Vertices"
    tooltip:"Average (relax) selected vertices - Maya style (instant)"
( on execute do ( if (avgv_run != undefined) do avgv_run() ) )

macroScript Average_Vertices_Caddy
    category:"averageVertices" buttontext:"Average Vertices (Caddy)"
    tooltip:"커서 옆 작은 창으로 Weight/Iters 실시간 조절"
( on execute do ( if (avgv_caddy != undefined) do avgv_caddy() ) )

format "averageVertices: 준비됨. Customize 에서 'Average Vertices' / 'Average Vertices (Caddy)'\n"
format "                 (카테고리 averageVertices)에 단축키를 지정하세요.\n"

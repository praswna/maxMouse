/*  averageVertices - Maya 의 "Average Vertices" 를 3ds Max 에 구현 (Editable Poly)
    ==========================================================================
    [개요]
    선택한 버텍스(또는 선택 엣지/페이스가 쓰는 버텍스)를 "이웃 버텍스들의 평균
    위치"로 이동시킵니다. = 릴렉스 / 라플라시안 스무딩. 반복할수록 더 매끄러워짐.
    Maya 의 Mesh > Average Vertices 와 동일한 동작.

    - 마우스 드래그가 아니라 "한 번 실행 = 한 번 평균" 명령입니다.
      단축키를 누를 때마다 한 번씩 적용됩니다(여러 번 누르면 더 스무딩).
    - 매크로 "Average Vertices"(카테고리: averageVertices)를 등록하므로,
      Customize > Hotkeys 에서 원하는 단축키를 직접 지정하세요.

    [독립성] 다른 모듈과 무관. 전역 접두사 avgv_. C#/후크 없음(MAXScript만).
    [실행] Scripting > Run Script -> averageVertices.ms  (매크로 등록)
    ==========================================================================
*/

global avgv_iterations               -- 한 번 실행 시 반복 횟수 (많을수록 더 스무딩)
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

-- 메인: 선택 버텍스를 이웃 평균 위치로 이동 (Jacobi 반복, 단일 Undo)
fn avgv_run = (
    local o = avgv_obj()
    if o == undefined do ( format "averageVertices: 단일 Editable Poly 를 선택하세요.\n"; return false )

    local lvl = try (subobjectLevel) catch (1)
    if lvl == undefined do lvl = 1
    if lvl < 1 do ( format "averageVertices: 서브오브젝트(버텍스/엣지/페이스) 레벨에서 선택하세요.\n"; return false )

    local selBA  = avgv_gatherVerts o lvl
    local selArr = selBA as array
    if selArr.count == 0 do ( format "averageVertices: 선택된 것이 없습니다.\n"; return false )

    -- 각 대상 버텍스의 "이웃 버텍스" 목록을 1회 계산 (토폴로지는 변하지 않음).
    --   이웃 = 엣지로 연결된 버텍스(선택 여부 무관) - 자기 자신
    local nbrLists = for vi in selArr collect (
        local e = polyop.getEdgesUsingVert o #{vi}
        ((polyop.getVertsUsingEdge o e) - #{vi}) as array
    )

    local okk = true
    theHold.Begin()
    try (
        for iter = 1 to avgv_iterations do (
            -- 새 위치를 모두 "현재(이전) 위치"에서 먼저 계산 -> 그 다음 일괄 적용(Jacobi).
            --   계산 중 polyop.getVert 는 아직 적용 전이라 옛 위치를 돌려줌.
            local newPos = for k = 1 to selArr.count collect (
                local nbrs = nbrLists[k]
                if nbrs.count == 0 then ( polyop.getVert o selArr[k] )   -- 고립 버텍스: 유지
                else (
                    local s = [0,0,0]
                    for n in nbrs do s += polyop.getVert o n
                    local avg  = s / nbrs.count
                    local orig = polyop.getVert o selArr[k]
                    orig + avgv_weight * (avg - orig)                    -- weight 만큼 평균으로
                )
            )
            polyop.setVert o selBA newPos                                -- bitArray + 위치배열로 1회 일괄 적용
        )
    ) catch ( okk = false; format "averageVertices: 적용 실패: %\n" (getCurrentException()) )
    if okk then ( theHold.Accept "Average Vertices" ) else ( theHold.Cancel() )
    redrawViews()
    if okk do format "averageVertices: 버텍스 % 개, 반복 % 회 적용.\n" selArr.count avgv_iterations
    okk
)

-- 단축키/툴바용 매크로 (Customize > Hotkeys 또는 Toolbars, 카테고리 averageVertices)
macroScript Average_Vertices
    category:"averageVertices"
    buttontext:"Average Vertices"
    tooltip:"Average (relax) selected vertices - Maya style"
(
    on execute do ( if (avgv_run != undefined) do avgv_run() )
)

-- ===========================================================================
--  설정 창 (강도 조절을 스크립트 수정 없이 스피너로)
-- ===========================================================================
rollout avgvSettingsRoll "Average Vertices" width:210
(
    spinner spnIter   "Iterations:" range:[1,100,1]      type:#integer fieldWidth:55 align:#right
    spinner spnWeight "Weight:"     range:[0.0,1.0,1.0]  type:#float scale:0.05 fieldWidth:55 align:#right
    button  btnApply  "Apply now"   width:190 align:#center offset:[0,4]
    label   lblHint   "(또는 지정한 단축키로 실행)" align:#center

    on avgvSettingsRoll open do ( spnIter.value = avgv_iterations; spnWeight.value = avgv_weight )
    on spnIter   changed v do avgv_iterations = v
    on spnWeight changed v do avgv_weight = v
    on btnApply  pressed   do ( if (avgv_run != undefined) do avgv_run() )
)

fn avgv_settings = (
    try ( destroyDialog avgvSettingsRoll ) catch ()
    createDialog avgvSettingsRoll
)

macroScript Average_Vertices_Settings
    category:"averageVertices"
    buttontext:"Avg Verts Settings"
    tooltip:"Average Vertices 강도(반복/가중치) 설정 창"
(
    on execute do ( if (avgv_settings != undefined) do avgv_settings() )
)

format "averageVertices: 준비됨. Customize 에서 'Average Vertices'(카테고리 averageVertices)에 단축키를 지정하세요.\n"
format "                 강도 조절: 리스너에서 avgv_iterations/avgv_weight 를 바꾸거나,\n"
format "                 avgv_settings() (또는 'Avg Verts Settings' 매크로)로 설정 창을 여세요.\n"


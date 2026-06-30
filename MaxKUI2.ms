/*  MaxKUI2.ms - 통합 단일 파일 (averageVertices + shiftVertexDrag + pivotZDrag)
    ==========================================================================
    개인 마스터 스크립트(MaxKUI)에 통합하기 위한 단일 파일 버전.

    [3개 모듈]
      1) averageVertices  : 선택 버텍스를 이웃 평균으로(릴렉스/스무딩). 순수 MAXScript.
                            매크로: Average Vertices / Average Vertices (Caddy)  (#MyKUI)
      2) shiftVertexDrag   : Shift + 중간드래그 = 버텍스를 화면 평면으로 이동.
      3) pivotZDrag        : Ctrl+Shift + 중간드래그 = 각 버텍스를 자기 법선으로 이동.

    [단일 파일 핵심]
      - shiftVertexDrag / pivotZDrag 의 C# 후크 소스를 이 파일 안에 "임베드"했다.
        -> 별도 .cs 컴패니언 파일이 필요 없으므로 Dropbox 등 어디에 둬도 동작한다.
        -> getThisScriptFilename 경로 의존/동기화 충돌 문제 제거.
      - 세 모듈은 전역 접두사(avgv_/svm_/pzd_)로 완전 격리. 서로의 전역을 공유하지 않음.
      - 각 모듈의 시작은 개별 try/catch 로 격리 -> 한 모듈 실패가 전체 로딩을 막지 않음.

    [실행] Scripting > Run Script -> MaxKUI2.ms  (또는 MaxKUI 마스터에서 fileIn)
    ==========================================================================
*/

-- ###########################################################################
-- ## [MODULE 1] averageVertices  (순수 MAXScript, 후크 없음)
-- ###########################################################################

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

-- 즉시 실행 (현재 강도값으로 1회, 단일 Undo)
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

-- 캐디형 팝업 (커서 옆 작은 창, 실시간 미리보기)
global avgv_cO, avgv_cSelBA, avgv_cSelArr, avgv_cNbr, avgv_cSelIdx, avgv_cOrig, avgv_cBase

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

fn avgv_caddyPreview = (
    if avgv_cO == undefined do return false
    try (
        local finalSel = avgv_relaxCompute avgv_cSelArr avgv_cSelIdx avgv_cNbr avgv_cBase avgv_weight avgv_iterations
        polyop.setVert avgv_cO avgv_cSelBA finalSel
        redrawViews()
    ) catch ( format "averageVertices: preview 실패: %\n" (getCurrentException()) )
)

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

fn avgv_caddyCancel = (
    if avgv_cO != undefined do (
        try ( polyop.setVert avgv_cO avgv_cSelBA avgv_cOrig; redrawViews() ) catch ()
        avgv_cO = undefined
    )
)

global avgv_form, avgv_lbl, avgv_scrubbing, avgv_startX, avgv_startW
global avgv_lastPrevW                 -- 마지막으로 미리보기한 weight (중복 갱신 방지)

fn avgv_setDB ctrl = (
    try (
        local bf = dotNetClass "System.Reflection.BindingFlags"
        local flags = dotNet.combineEnums bf.Instance bf.NonPublic    -- 안전한 플래그 결합(+ 보다 견고)
        local t  = ctrl.GetType()
        local pi = t.GetProperty "DoubleBuffered" flags
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

    -- MaxForm 은 3ds Max 메인 윈도우에 소유(owned)되어 z-순서/리드로우 시 가려짐·깜박임이 줄어든다.
    avgv_form = try (dotNetObject "MaxCustomControls.MaxForm") catch (dotNetObject "System.Windows.Forms.Form")
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

macroScript Average_Vertices
    category:"#MyKUI"
    tooltip:"Average Vertices"
( on execute do ( if (avgv_run != undefined) do avgv_run() ) )

macroScript Average_Vertices_Caddy
    category:"#MyKUI"
    tooltip:"Average Vertices(Caddy)"
( on execute do ( if (avgv_caddy != undefined) do avgv_caddy() ) )


-- ###########################################################################
-- ## [MODULE 2] shiftVertexDrag  (C# 후크 임베드)
-- ##   Shift + 중간드래그 = 선택 버텍스를 화면 평면으로 이동
-- ###########################################################################

global svm_hook                 -- C# 후크 인스턴스
global svm_asm                  -- 컴파일된 어셈블리
global svm_obj, svm_isPoly, svm_meshCopy, svm_sel, svm_selBA, svm_orig
global svm_center, svm_normal, svm_offset, svm_startLocal, svm_startWorld, svm_delta, svm_ok
global svm_held                 -- theHold(undo) 를 열어두었는지

-- [임베드] ShiftVertexHook.cs 소스를 문자열로 내장 (별도 .cs 파일 불필요).
--   C# 코드 안 큰따옴표는 MAXScript 문자열 규칙상 \" 로 이스케이프되어 있다.
global svm_cs = "// ShiftVertexMove - embedded mouse hook (Shift + middle-drag)
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ShiftVertexMove
{
    public class PointEventArgs : EventArgs
    {
        public int X;
        public int Y;
        public PointEventArgs(int x, int y) { X = x; Y = y; }
    }

    class MsgSink : NativeWindow
    {
        public const int WM_VSTART = 0x8000 + 1;
        public const int WM_VMOVE  = 0x8000 + 2;
        public const int WM_VEND   = 0x8000 + 3;
        public Action OnVStart, OnVMove, OnVEnd;

        public MsgSink()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_VSTART) { if (OnVStart != null) OnVStart(); return; }
            if (m.Msg == WM_VMOVE)  { if (OnVMove  != null) OnVMove();  return; }
            if (m.Msg == WM_VEND)   { if (OnVEnd   != null) OnVEnd();   return; }
            base.WndProc(ref m);
        }

        public void Close() { try { DestroyHandle(); } catch { } }
    }

    public class VertexDragHook
    {
        private const int WH_MOUSE_LL    = 14;
        private const int WM_MOUSEMOVE   = 0x0200;
        private const int WM_MBUTTONDOWN = 0x0207;
        private const int WM_MBUTTONUP   = 0x0208;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport(\"kernel32.dll\", SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport(\"user32.dll\")]
        private static extern short GetAsyncKeyState(int vKey);
        [DllImport(\"user32.dll\")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport(\"user32.dll\")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport(\"user32.dll\")]
        private static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        public bool Armed { get; set; }
        public int  Modifier { get; set; }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private MsgSink _sink;
        private readonly int _ourPid;

        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public VertexDragHook()
        {
            Armed = false;
            Modifier = 3;
            _ourPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _sink = new MsgSink();
            _sink.OnVStart = delegate {
                EventHandler<PointEventArgs> h = VertexDragStart;
                if (h != null) h(this, new PointEventArgs(_vStartX, _vStartY));
            };
            _sink.OnVMove = delegate {
                _vMovePosted = false;
                EventHandler<PointEventArgs> h = VertexDragMove;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
            };
            _sink.OnVEnd = delegate {
                EventHandler<EventArgs> h = VertexDragEnd;
                if (h != null) h(this, EventArgs.Empty);
            };
            _proc = HookCallback;
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        }

        public void Stop()
        {
            if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
            if (_sink != null) { _sink.Close(); _sink = null; }
            _vDrag = false;
        }

        private bool ModifierDown()
        {
            bool ctrl  = (GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt   = (GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
            switch (Modifier)
            {
                case 1:  return ctrl  && !alt  && !shift;
                case 2:  return alt   && !ctrl && !shift;
                case 3:  return shift && !ctrl && !alt;
                default: return !ctrl && !alt  && !shift;
            }
        }

        private bool MaxForeground()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return pid == (uint)_ourPid;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _sink != null)
            {
                int msg = wParam.ToInt32();
                bool want = (msg == WM_MBUTTONDOWN && Armed)
                         || (msg == WM_MBUTTONUP   && _vDrag)
                         || (msg == WM_MOUSEMOVE   && _vDrag);
                if (want && MaxForeground())
                {
                    MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    int px = data.pt.x, py = data.pt.y;
                    if (msg == WM_MBUTTONDOWN)
                    {
                        if (ModifierDown())
                        {
                            _vDrag = true; _vMovePosted = false;
                            _vStartX = px; _vStartY = py; _vCurX = px; _vCurY = py;
                            PostMessage(_sink.Handle, MsgSink.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;
                        }
                    }
                    else if (msg == WM_MBUTTONUP)
                    {
                        _vCurX = px; _vCurY = py; _vDrag = false;
                        PostMessage(_sink.Handle, MsgSink.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                    else
                    {
                        _vCurX = px; _vCurY = py;
                        if (!_vMovePosted)
                        {
                            _vMovePosted = true;
                            PostMessage(_sink.Handle, MsgSink.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
                        }
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
"

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
        case lvl of (
            1: (getVertSelection obj)
            2: (try (meshop.getVertsUsingEdge obj (getEdgeSelection obj)) catch (#{}))
            default: (try (meshop.getVertsUsingFace obj (getFaceSelection obj)) catch (#{}))
        )
    )
)

fn svm_onStart sender args = (
    svm_ok = false
    if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )   -- 이전 드래그 잔여 정리
    try (
        if selection.count != 1 do return false
        svm_obj = selection[1]
        local b = svm_obj.baseObject
        svm_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (svm_isPoly or isMesh) do return false

        svm_meshCopy = if isMesh then svm_obj.mesh else undefined
        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        svm_selBA = svm_gatherVerts svm_obj svm_isPoly lvl   -- bitArray (Poly 일괄 setVert용)
        svm_sel   = svm_selBA as array
        if svm_sel.count == 0 do return false

        svm_orig = for i in svm_sel collect (svm_getWorld i)
        local c = [0,0,0]; for w in svm_orig do c += w
        svm_center = c / svm_orig.count
        svm_normal = normalize ((inverse (viewport.getTM())).row3)

        svm_offset = [args.X, args.Y] - mouse.pos
        svm_startLocal = [args.X, args.Y] - svm_offset
        svm_startWorld = svm_planePt svm_startLocal
        svm_delta = [0,0,0]
        theHold.Begin()
        svm_held = true
        svm_ok = true
    ) catch (
        format "shiftVertexDrag: start failed: %\n" (getCurrentException())
        svm_ok = false
        if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    )
)

fn svm_onMove sender args = (
    if not svm_ok do return false
    try (
        local cur = [args.X, args.Y] - svm_offset
        svm_delta = (svm_planePt cur) - svm_startWorld
        if svm_isPoly then (
            local posArr = for k = 1 to svm_sel.count collect (svm_orig[k] + svm_delta)
            polyop.setVert svm_obj svm_selBA posArr node:svm_obj
        ) else (
            for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
            svm_commit()
        )
        redrawViews()
    ) catch ( format "shiftVertexDrag: move failed: %\n" (getCurrentException()) )
)

fn svm_onEnd sender args = (
    if not svm_ok do return false
    svm_ok = false
    try (
        if svm_held == true do (
            if (length svm_delta) > 1e-6 then theHold.Accept "Move Verts (screen)"
            else theHold.Cancel()
            svm_held = false
        )
        redrawViews()
    ) catch (
        format "shiftVertexDrag: commit failed: %\n" (getCurrentException())
        if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    )
)

fn svm_poll = (
    if svm_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    svm_hook.Armed = armed
)
fn svm_addCb evt = (
    try ( callbacks.addScript evt "if (svm_poll != undefined) do svm_poll()" id:#shiftVertexDrag ) catch ()
)

-- [임베드 컴파일] 파일을 읽지 않고 내장 문자열 svm_cs 를 컴파일
fn svm_compile = (
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(svm_cs)
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
    svm_hook.Modifier = 3     -- 트리거 수정자: 0=없음, 1=Ctrl, 2=Alt, 3=Shift

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
    if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    if svm_hook != undefined do ( try ( svm_hook.Stop() ) catch (); svm_hook = undefined )
    format "shiftVertexDrag: stopped.\n"
)

fn shiftVertexDrag_toggle = (
    if (svm_hook != undefined and svm_hook.IsRunning) then shiftVertexDrag_stop() else shiftVertexDrag_start()
)

macroScript shiftVertexDrag_Toggle
    category:"shiftVertexDrag" buttontext:"ShiftVertDrag" tooltip:"Toggle Shift+middle vertex drag"
( on execute do ( if (shiftVertexDrag_toggle != undefined) do shiftVertexDrag_toggle() ) )


-- ###########################################################################
-- ## [MODULE 3] pivotZDrag  (C# 후크 임베드)
-- ##   Ctrl+Shift + 중간드래그 = 각 버텍스를 자기 표면 법선으로 이동 (Editable Poly 전용)
-- ###########################################################################

global pzd_hook
global pzd_asm
global pzd_obj, pzd_sel, pzd_selBA, pzd_orig
global pzd_center, pzd_normal, pzd_axis, pzd_offset, pzd_startLocal, pzd_startWorld, pzd_ok
global pzd_invOTM                    -- inverse(objecttransform) 캐시 (드래그 중 불변)
global pzd_norm                      -- 각 버텍스의 (로컬) 법선 배열(sel 과 같은 순서)
global pzd_amt                       -- 이동량(스칼라)
global pzd_prevCoord                 -- 드래그 전 좌표계(끝나면 복원)
global pzd_prevPivotTM               -- 드래그 전 워킹 피벗 TM(끝나면 복원, 비파괴)
global pzd_switched                  -- 좌표계/피벗을 바꿨고 아직 복원 안 했는지
global pzd_held                      -- theHold(undo) 를 열어두었는지

-- [임베드] PivotZHook.cs 소스를 문자열로 내장 (별도 .cs 파일 불필요).
global pzd_cs = "// PivotZMove - embedded mouse hook (Ctrl+Shift + middle-drag)
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PivotZMove
{
    public class PointEventArgs : EventArgs
    {
        public int X;
        public int Y;
        public PointEventArgs(int x, int y) { X = x; Y = y; }
    }

    class MsgSink : NativeWindow
    {
        public const int WM_VSTART = 0x8000 + 1;
        public const int WM_VMOVE  = 0x8000 + 2;
        public const int WM_VEND   = 0x8000 + 3;
        public Action OnVStart, OnVMove, OnVEnd;

        public MsgSink()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_VSTART) { if (OnVStart != null) OnVStart(); return; }
            if (m.Msg == WM_VMOVE)  { if (OnVMove  != null) OnVMove();  return; }
            if (m.Msg == WM_VEND)   { if (OnVEnd   != null) OnVEnd();   return; }
            base.WndProc(ref m);
        }

        public void Close() { try { DestroyHandle(); } catch { } }
    }

    public class PivotZDragHook
    {
        private const int WH_MOUSE_LL    = 14;
        private const int WM_MOUSEMOVE   = 0x0200;
        private const int WM_MBUTTONDOWN = 0x0207;
        private const int WM_MBUTTONUP   = 0x0208;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport(\"kernel32.dll\", SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport(\"user32.dll\")]
        private static extern short GetAsyncKeyState(int vKey);
        [DllImport(\"user32.dll\")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport(\"user32.dll\")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport(\"user32.dll\")]
        private static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        public bool Armed { get; set; }
        public int  Modifiers { get; set; }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private MsgSink _sink;
        private readonly int _ourPid;

        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public PivotZDragHook()
        {
            Armed = false;
            Modifiers = 1 | 4;
            _ourPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _sink = new MsgSink();
            _sink.OnVStart = delegate {
                EventHandler<PointEventArgs> h = VertexDragStart;
                if (h != null) h(this, new PointEventArgs(_vStartX, _vStartY));
            };
            _sink.OnVMove = delegate {
                _vMovePosted = false;
                EventHandler<PointEventArgs> h = VertexDragMove;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
            };
            _sink.OnVEnd = delegate {
                EventHandler<EventArgs> h = VertexDragEnd;
                if (h != null) h(this, EventArgs.Empty);
            };
            _proc = HookCallback;
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        }

        public void Stop()
        {
            if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
            if (_sink != null) { _sink.Close(); _sink = null; }
            _vDrag = false;
        }

        private bool ModifiersMatch()
        {
            int cur = 0;
            if ((GetAsyncKeyState(0x11) & 0x8000) != 0) cur |= 1;
            if ((GetAsyncKeyState(0x12) & 0x8000) != 0) cur |= 2;
            if ((GetAsyncKeyState(0x10) & 0x8000) != 0) cur |= 4;
            return cur == Modifiers;
        }

        private bool MaxForeground()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return pid == (uint)_ourPid;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _sink != null)
            {
                int msg = wParam.ToInt32();
                bool want = (msg == WM_MBUTTONDOWN && Armed)
                         || (msg == WM_MBUTTONUP   && _vDrag)
                         || (msg == WM_MOUSEMOVE   && _vDrag);
                if (want && MaxForeground())
                {
                    MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    int px = data.pt.x, py = data.pt.y;
                    if (msg == WM_MBUTTONDOWN)
                    {
                        if (ModifiersMatch())
                        {
                            _vDrag = true; _vMovePosted = false;
                            _vStartX = px; _vStartY = py; _vCurX = px; _vCurY = py;
                            PostMessage(_sink.Handle, MsgSink.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;
                        }
                    }
                    else if (msg == WM_MBUTTONUP)
                    {
                        _vCurX = px; _vCurY = py; _vDrag = false;
                        PostMessage(_sink.Handle, MsgSink.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                    else
                    {
                        _vCurX = px; _vCurY = py;
                        if (!_vMovePosted)
                        {
                            _vMovePosted = true;
                            PostMessage(_sink.Handle, MsgSink.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
                        }
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
"

-- 좌표계/워킹 피벗을 드래그 전 상태로 복원 (전환했을 때만)
fn pzd_restoreCoord = (
    if pzd_switched == true do (
        if pzd_prevPivotTM != undefined do ( try ( WorkingPivot.setTM pzd_prevPivotTM ) catch () )
        if pzd_prevCoord  != undefined do ( try ( toolMode.coordsys pzd_prevCoord ) catch () )
        pzd_switched = false
    )
)

fn pzd_getWorld i = ( polyop.getVert pzd_obj i node:pzd_obj )
fn pzd_getObj   i = ( polyop.getVert pzd_obj i )

fn pzd_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir pzd_normal
    if (abs denom) < 1e-7 then pzd_center
    else ( local t = (dot (pzd_center - r.pos) pzd_normal) / denom; r.pos + t * r.dir )
)

fn pzd_tmFromZ zdir pos = (
    local z = normalize zdir
    local upv = if (abs (dot z [0,0,1])) > 0.99 then [1,0,0] else [0,0,1]
    local x = normalize (cross upv z)
    local y = normalize (cross z x)
    matrix3 x y z pos
)

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

fn pzd_onStart sender args = (
    pzd_ok = false
    pzd_restoreCoord()    -- 이전 드래그가 미완료로 좌표계를 바꿔놨다면 먼저 원복(원본 보존)
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    pzd_switched = false
    try (
        if selection.count != 1 do return false
        pzd_obj = selection[1]
        if (classof pzd_obj.baseObject != Editable_Poly) do return false   -- Editable Poly 전용

        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        pzd_selBA = pzd_gatherVerts pzd_obj lvl
        pzd_sel = pzd_selBA as array
        if pzd_sel.count == 0 do return false
        pzd_invOTM = inverse pzd_obj.objecttransform

        pzd_orig = for i in pzd_sel collect (pzd_getObj i)
        local wc = [0,0,0]
        for i in pzd_sel do wc += (pzd_getWorld i)
        pzd_center = wc / pzd_sel.count

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)

        pzd_norm = pzd_vertNormals pzd_obj pzd_sel
        local an = [0,0,0]; for nrm in pzd_norm do an += nrm
        pzd_axis = if (length an) > 1e-6 then (normalize an) else [0,0,1]

        local otm = pzd_obj.objecttransform
        local avgWorld = normalize ((pzd_axis * otm) - otm.row4)
        pzd_prevCoord   = try (getRefCoordSys()) catch (#world)
        pzd_prevPivotTM = try (WorkingPivot.getTM()) catch (undefined)
        try (
            WorkingPivot.setTM (pzd_tmFromZ avgWorld pzd_center)
            toolMode.coordsys #working_pivot
            pzd_switched = true
        ) catch ()

        pzd_offset = [args.X, args.Y] - mouse.pos
        pzd_startLocal = [args.X, args.Y] - pzd_offset
        pzd_startWorld = pzd_planePt pzd_startLocal
        pzd_amt = 0.0
        theHold.Begin()
        pzd_held = true
        pzd_ok = true
    ) catch (
        format "pivotZDrag: start failed: %\n" (getCurrentException())
        pzd_ok = false
        if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
        pzd_restoreCoord()
    )
)

fn pzd_amtFromDrag args = (
    local cur = [args.X, args.Y] - pzd_offset
    local d   = (pzd_planePt cur) - pzd_startWorld
    local dObj = (d * pzd_invOTM) - pzd_invOTM.row4
    dot dObj pzd_axis
)

fn pzd_applyAmt amt = (
    local posArr = for k = 1 to pzd_sel.count collect (pzd_orig[k] + amt * pzd_norm[k])
    polyop.setVert pzd_obj pzd_selBA posArr
)

fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        pzd_amt = pzd_amtFromDrag args
        pzd_applyAmt pzd_amt
        redrawViews()
    ) catch ( format "pivotZDrag: move failed: %\n" (getCurrentException()) )
)

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
    pzd_restoreCoord()
)

fn pzd_poll = (
    if pzd_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly)
    )
    pzd_hook.Armed = armed
)
fn pzd_addCb evt = (
    try ( callbacks.addScript evt "if (pzd_poll != undefined) do pzd_poll()" id:#pivotZDrag ) catch ()
)

-- [임베드 컴파일] 파일을 읽지 않고 내장 문자열 pzd_cs 를 컴파일
fn pzd_compile = (
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(pzd_cs)
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
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    pzd_restoreCoord()
    if pzd_hook != undefined do ( try ( pzd_hook.Stop() ) catch (); pzd_hook = undefined )
    format "pivotZDrag: stopped.\n"
)

fn pivotZDrag_toggle = (
    if (pzd_hook != undefined and pzd_hook.IsRunning) then pivotZDrag_stop() else pivotZDrag_start()
)

macroScript pivotZDrag_Toggle
    category:"pivotZDrag" buttontext:"PivotZDrag" tooltip:"Toggle Ctrl+Shift+middle move along vertex normals"
( on execute do ( if (pivotZDrag_toggle != undefined) do pivotZDrag_toggle() ) )


-- ###########################################################################
-- ## [시작] 각 모듈을 개별 try/catch 로 격리 시작 (한 모듈 실패가 전체를 막지 않음)
-- ###########################################################################
format "MaxKUI2: averageVertices 매크로 등록됨 (#MyKUI: 'Average Vertices' / 'Average Vertices (Caddy)').\n"

try ( shiftVertexDrag_start() )
catch ( format "MaxKUI2: shiftVertexDrag 시작 실패: %\n" (getCurrentException()) )

try ( pivotZDrag_start() )
catch ( format "MaxKUI2: pivotZDrag 시작 실패: %\n" (getCurrentException()) )

format "MaxKUI2: 준비 완료.\n"

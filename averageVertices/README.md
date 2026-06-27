# averageVertices

**3ds Max Editable Poly** 전용 **버텍스 평균화 / 릴랙스** 도구입니다.

선택한 버텍스를 **연결된 이웃 버텍스들의 평균 위치** 쪽으로 이동시켜 메시를 부드럽게 만듭니다.
반복 실행할수록 더 많이 스무딩됩니다.

순수 MAXScript — C# 없음, 마우스 훅 없음. **macroScript**를 등록하므로 원하는 단축키를 직접 지정하세요.

---

A **standalone** 3ds Max tool: **Average / Relax Vertices** (Laplacian smoothing) for **Editable Poly**.

It moves each selected vertex toward the **average position of its connected neighbour vertices**. Repeat to smooth more.

Pure MAXScript — no C#, no mouse hook. Registers a **macroScript** so you can bind your own hotkey.

---

## 기능 / What it does

- **서브오브젝트 레벨** (Vertex / Edge / Border / Polygon / Element) 어디서나 동작합니다. 에지·페이스 선택은 해당 버텍스로 자동 변환됩니다.
- 각 대상 버텍스의 새 위치 = 에지로 연결된 이웃 버텍스들의 평균 위치 × `avgv_weight` 블렌드.
- **야코비 반복(Jacobi iteration)** 사용 — 이전 상태에서 모든 새 위치를 먼저 계산한 뒤 한 번에 적용하므로 버텍스 순서에 무관합니다.
- 실행당 **언두 1회** (`Average Vertices`, `theHold` 사용). `polyOp.setVert` 배치 호출로 적용.

---

- Works at any **sub-object level**: Vertex / Edge / Border / Polygon / Element. Edge/face selections are converted to the vertices they use.
- For each target vertex, the new position is the average of the vertices connected to it by an edge, blended by `avgv_weight`.
- Uses **Jacobi iteration** (all new positions computed from the previous state, then applied at once) so the result doesn't depend on vertex order.
- One **undo** entry per run (`Average Vertices`, via `theHold`). Applied with a single batched `polyOp.setVert`.

---

## 설치 / 실행 / 단축키 지정

1. **Scripting > Run Script…** → `averageVertices.ms` 실행 (매크로 등록됨).
2. **Customize > Hotkeys** (또는 Toolbars) → 카테고리 **#MyKUI** → 아래 두 매크로 중 하나(또는 둘 다) 단축키 지정:
   - **Average Vertices** — 현재 강도로 즉시 적용.
   - **Average Vertices (Caddy)** — 커서 옆에 **테두리 없는** 미니 팝업이 뜨고, **좌우 드래그로 Weight를 실시간 스크럽**. 마우스 버튼을 놓으면 확정 (언두 1회).
3. Editable Poly를 선택 → 서브오브젝트 레벨 진입 → 버텍스/에지/페이스 선택 → 단축키 실행.
   (즉시 버전: 같은 선택 상태에서 반복 실행할수록 더 스무딩됩니다.)

자동 로드하려면 `fileIn` 명령으로 `…/scripts/startup/` 폴더의 파일에서 이 스크립트를 불러오세요.

---

## Install / run & assign a hotkey

1. **Scripting > Run Script…** → `averageVertices.ms` (registers the macros).
2. **Customize > Hotkeys** (or Toolbars) → category **#MyKUI** → pick one and assign your shortcut:
   - **Average Vertices** — apply instantly with the current strength.
   - **Average Vertices (Caddy)** — pop a tiny **borderless** strip next to the cursor and **drag left/right to scrub the Weight** with live preview; release to confirm (one undo).
3. Select an Editable Poly, enter a sub-object level, select verts/edges/faces, and press the key. (Instant version: press repeatedly to smooth more.)

To auto-load, `fileIn` the script from a file in your user `…/scripts/startup/`.

---

## 강도 조절 / Tuning

스크립트를 직접 편집하지 않아도 됩니다. 조절 방법:

1. **캐디 스크럽 (커서 옆)** — **Average Vertices (Caddy)** 매크로(카테고리 *#MyKUI*)를 바인딩하거나 `avgv_caddy()`를 실행하세요. 커서 옆에 **테두리 없는** 미니 스트립이 뜨고, **좌우 드래그로 Weight를 실시간 스크럽**합니다. 마우스를 놓으면 확정(언두 1회). **우클릭 / Esc**로 취소, **Enter**로 확정. (반복 횟수는 `avgv_iterations`에서 가져옴.)
2. **Listener** — 전역 변수 직접 설정: `avgv_weight = 0.5`, `avgv_iterations = 3` (즉시 실행 매크로에서 사용).

두 값의 의미:

- `avgv_iterations` — 한 번 실행 시 릴랙스 패스 횟수 (기본값 `1`). 높을수록 한 번에 더 많이 스무딩.
- `avgv_weight` — `0..1`, 각 버텍스가 이웃 평균 위치 쪽으로 얼마나 이동할지 (기본값 `1.0` = 완전히 이동; 낮을수록 부드럽게).

값은 세션 유지(3ds Max 재시작 시 초기화). **시작 기본값**을 바꾸려면 스크립트 상단의 두 줄을 직접 편집하세요.

---

You do **not** have to edit the script. Ways to adjust the strength:

1. **Caddy scrub (near the cursor)** — bind the **Average Vertices (Caddy)** macro (category *#MyKUI*) or run `avgv_caddy()`. A **borderless** mini strip pops up at the cursor; **left-drag horizontally to scrub Weight** with **live preview**. Release to confirm (one undo). **Right-click / Esc** cancels, **Enter** confirms.
2. **Listener** — set the globals directly: `avgv_weight = 0.5`, `avgv_iterations = 3`.

The two values:

- `avgv_iterations` — relax passes per application (default `1`). Higher = more smoothing at once.
- `avgv_weight` — `0..1`, how far each vertex moves toward its neighbour average (default `1.0` = move fully to the average; lower = gentler).

Values are per-session (reset when 3ds Max restarts). To change the **startup default**, edit the two lines at the top of the script.

---

## 참고 사항 / Notes

- **Editable Poly 전용.** (Editable Mesh는 Editable Poly로 변환하세요. Edit Poly 모디파이어는 지원하지 않습니다.)
- 이웃 버텍스에는 **미선택 버텍스도 포함**되므로, 선택 영역의 경계가 주변 메시와 자연스럽게 블렌딩됩니다 (선택 영역만 고정되지 않음).
- 연결된 에지가 없는 고립 버텍스는 이동하지 않습니다.
- **반복 실행 시 빠름:** 이웃 토폴로지와 버텍스→선택 인덱스가 (오브젝트, 버텍스 수, 선택 상태)별로 캐싱됩니다. 같은 선택에서 반복 실행 시 이웃 재수집을 건너뛰고, 전체 메시 복사 없이 선택 전용 배열로만 릴랙스를 수행합니다. 오브젝트·버텍스 수·선택이 바뀌면 캐시가 갱신됩니다.
- MAXScript를 지원하는 모든 3ds Max에서 동작. 캐디는 .NET WinForms 사용 (Windows).

---

- **Editable Poly only.** (Convert Editable Mesh to Editable Poly; Edit Poly modifier is not handled.)
- Neighbours include **unselected** connected vertices, so the boundary of your selection blends into the surrounding mesh.
- Isolated vertices (no connected edges) are left unchanged.
- **Fast on repeats:** the neighbour topology and a vertex→selection index are cached per (object, vertex count, selection), so pressing the key repeatedly on the same selection skips re-gathering neighbours; the relax runs on a compact per-selection array. The cache refreshes when the object, vertex count, or selection changes.
- Any 3ds Max with MAXScript; the caddy uses .NET WinForms (Windows).

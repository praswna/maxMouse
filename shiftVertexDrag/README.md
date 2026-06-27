# shiftVertexDrag

**3ds Max 독립 실행형 도구**: **Shift + 중간 버튼 드래그로 선택한 버텍스를 화면 평면 위에서 이동.**

독립형 도구 — 자체 런타임 C# 훅(네임스페이스 `ShiftVertexMove`), 자체 전역 변수(`svm_*`), 자체 콜백 ID와 매크로.
`pivotZDrag`(Ctrl+Shift)와 수식어 매칭이 정확하여 충돌하지 않습니다.

---

A **standalone** 3ds Max tool: **Shift + middle-drag moves the selected vertices in screen space.**

Self-contained and independent — its own runtime-compiled C# hook (namespace `ShiftVertexMove`), its own globals (`svm_*`), its own callback id and macro. It coexists with `pivotZDrag` (Ctrl+Shift) because the modifier match is exact, so Shift-only never triggers both.

---

## 기능 / What it does

**Editable Poly / Editable Mesh**가 **서브오브젝트 레벨** (Vertex / Edge / Border / Polygon / Element)에 있을 때, **Shift**를 누른 채 **중간 버튼을 드래그**하면 선택 영역이 화면에 평행한 평면 위에서 슬라이드됩니다 (선택 무게중심 통과). 에지·페이스 선택 시 해당 버텍스를 이동합니다. Shift를 누르는 동안 **뷰포트는 패닝되지 않습니다.**

- 중간 버튼 **단독**은 평소와 같이 패닝.
- **왼쪽** 버튼은 건드리지 않습니다.
- 드래그 전체가 **언두 1회**로 기록됩니다 (`Move Verts (screen)`).

---

When an **Editable Poly / Editable Mesh** is in a **sub-object level** (Vertex / Edge / Border / Polygon / Element), holding **Shift** and dragging with the **middle mouse button** slides the selection along a plane parallel to the screen (through the selection centroid). The viewport does **not** pan while Shift is held.

- Middle button **alone** pans as usual.
- The **left** button is never touched.
- The whole drag is committed as a **single undo** (`Move Verts (screen)`).

---

## 동작 원리 / How it works

1. `shiftVertexDrag.ms`가 동봉된 `ShiftVertexHook.cs`를 읽어 .NET `CSharpCodeProvider`로 메모리에 컴파일하고, **3ds Max가 포그라운드 프로세스일 때만** 동작하는 저수준 마우스 훅을 설치합니다.
2. MAXScript가 `#selectionSetChanged` / `#modPanelSubObjectLevelChanged` 이벤트(폴링 타이머 없음)로 훅의 `Armed` 플래그를 현재 서브오브젝트 레벨과 동기화합니다.
3. Shift + 중간 버튼 다운(무장 상태)이 감지되면, 훅이 중간 버튼 다운/업을 삼켜(패닝 방지) **메시지 전용 윈도우**(PostMessage, 셀프 코얼레싱)를 통해 드래그를 MAXScript로 스트리밍합니다. 훅 내부에서 MAXScript가 재진입하지 않으며, 마우스 이동은 절대 삼키지 않아 커서가 멈추지 않습니다.
4. MAXScript가 커서를 화면 평면에 투영(`mapScreenToWorldRay`)하여 월드 델타를 계산, 실시간으로 이동합니다. Editable Poly는 이동당 `polyOp.setVert <bitArray> <pointlist> node:` 배치 호출 1회(큰 선택도 빠름). Editable Mesh는 버텍스별 폴백 사용.

---

1. `shiftVertexDrag.ms` reads the companion `ShiftVertexHook.cs`, compiles it in memory with the .NET `CSharpCodeProvider`, and installs a low-level mouse hook that only acts while **3ds Max is the foreground process**.
2. MAXScript keeps the hook's `Armed` flag in sync with the current sub-object level (event-driven via `#selectionSetChanged` / `#modPanelSubObjectLevelChanged` — no polling timer).
3. On Shift + middle-down (armed), the hook swallows the middle down/up (no pan) and streams the drag to MAXScript through a **message-only window** (PostMessage, self-coalescing) — smooth, never re-entrant. Mouse moves are never swallowed (no cursor freeze).
4. MAXScript projects the cursor onto the screen plane (`mapScreenToWorldRay`) and moves the selection by the resulting world delta, live. Editable Poly writes all verts in one batched `polyOp.setVert <bitArray> <pointlist> node:` per move; Editable Mesh uses a per-vert fallback.

---

## 설치 / Install

1. `ShiftVertexHook.cs`와 `shiftVertexDrag.ms`를 **같은 폴더**에 보관하세요.
2. 3ds Max에서: **Scripting > Run Script…** → `shiftVertexDrag.ms` 선택. 즉시 시작되며 Listener에 `shiftVertexDrag: started …`가 출력됩니다.
3. 다시 실행하면 켜기/끄기 토글, 또는 **ShiftVertDrag** 매크로 사용 (Customize > Toolbars, 카테고리 *shiftVertexDrag*).

자동 로드하려면 `fileIn`으로 `…/scripts/startup/` 폴더의 파일에서 이 스크립트를 불러오세요.

---

1. Keep `ShiftVertexHook.cs` and `shiftVertexDrag.ms` **together** in the same folder.
2. In 3ds Max: **Scripting > Run Script…** → pick `shiftVertexDrag.ms`. It starts immediately and prints `shiftVertexDrag: started …`.
3. Run again to toggle off/on, or use the **ShiftVertDrag** macro (Customize > Toolbars, category *shiftVertexDrag*).

To auto-load, `fileIn` the script from a file in your user `…/scripts/startup/` folder.

---

## 설정 / Configuration

- **수식어 키:** `shiftVertexDrag_start()` 내에서 `svm_hook.Modifier` 설정 (`0` 없음, `1` Ctrl, `2` Alt, `3` Shift — 기본값 Shift).
- **Modifier:** in `shiftVertexDrag_start()` set `svm_hook.Modifier` (`0` none, `1` Ctrl, `2` Alt, `3` Shift — default Shift).

---

## 참고 사항 / Notes & caveats

- **Editable Poly**는 완전 지원 (`polyOp.getVert/setVert`, 월드 공간). **Editable Mesh**는 이동마다 `node.mesh`를 재할당하여 최선 지원 / 느릴 수 있음 — 랙이 있으면 Editable Poly로 변환하세요. 모디파이어(Edit Poly/Mesh)는 지원하지 않습니다.
- 중간 버튼 다운이 삼켜지므로 이미 활성화된 뷰포트에서 드래그하세요. 화면 평면 매핑은 **활성 뷰포트** 기준.
- 화면 평면 이동만 가능합니다 (깊이 이동, 축 구속, 스냅 없음).
- Windows 전용 (Win32 마우스 훅). Max 종료 시 또는 도구를 끌 때 훅이 제거됩니다.

---

- **Editable Poly** is solid (`polyOp.getVert/setVert`, world space). **Editable Mesh** reassigns `node.mesh` each move and is best-effort / slower — convert to Editable Poly if it lags. Modifiers (Edit Poly/Mesh) are not handled.
- Mapping uses the **active viewport**; since the middle-down is swallowed, drag in the viewport that is already active.
- Movement is within the screen plane only (no depth move, no axis/snap).
- Windows only (Win32 mouse hook). The hook is removed on Max shutdown and when you toggle the tool off.

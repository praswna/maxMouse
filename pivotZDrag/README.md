# pivotZDrag

**3ds Max 독립 실행형 도구**: **Ctrl+Shift + 중간 버튼 드래그로 선택한 버텍스를 각자의 서피스 노멀 방향으로 이동 (Inflate/Deflate).**

독립형 — 자체 런타임 C# 훅(네임스페이스 `PivotZMove`), 자체 전역 변수(`pzd_*`), 자체 콜백 ID와 매크로.

---

A **standalone** 3ds Max tool: **Ctrl+Shift + middle-drag moves the selected vertices along each vertex's own surface normal** (inflate / deflate).

Self-contained and independent — its own runtime-compiled C# hook (namespace `PivotZMove`), globals (`pzd_*`), callback id and macro.

---

## 기능 / What it does

**Editable Poly** (Editable Mesh는 **미지원**)가 **서브오브젝트 레벨** (Vertex / Edge / Border / Polygon / Element)에 있을 때, **Ctrl+Shift**를 누른 채 **중간 버튼을 드래그**하면 선택한 각 버텍스가 **자신만의 서피스 노멀** 방향으로 같은 거리만큼 이동합니다 (노멀 오프셋 / inflate).

복수 선택 시 각 버텍스가 자신의 방향으로 이동합니다. 에지·페이스 선택 시 해당 버텍스들이 각자의 노멀 방향으로 이동합니다 — 선택은 에지/페이스처럼 보이지만 실제 이동은 버텍스 단위로 발생합니다.

드래그 양(스칼라)은 **평균 노멀** 방향으로 투영된 화면 평면 이동량으로 결정됩니다 (바깥으로 드래그 = inflate, 안으로 = deflate). 시각적 피드백을 위해 워킹 피벗을 평균 노멀에 잠시 맞추고, 좌표계를 **Working Pivot**으로 전환하며, 마우스를 놓으면 **두 가지 모두 원래대로 복원**됩니다 (비파괴). 버텍스 노멀을 구할 수 없으면 해당 버텍스는 +Z로 폴백.

- 드래그는 **해당 축이 화면에 투영된 방향**으로 이동합니다 (Max의 축 구속 기즈모 드래그와 동일).
- 수식어 매칭이 **정확** (Ctrl+Shift만), Shift 단독 도구와 절대 충돌하지 않습니다. 중간 단독은 패닝, 왼쪽 버튼은 건드리지 않습니다.
- 드래그 전체가 **언두 1회** (`Move Verts (vertex normals)`, `theHold` 사용).

---

When an **Editable Poly** is in a **sub-object level** (Vertex / Edge / Border / Polygon / Element), holding **Ctrl+Shift** and dragging with the **middle mouse button** moves each selected vertex along **its own surface normal** by the same distance (normal offset / inflate).

With a multi-selection every vertex goes its own way; selecting a face or edge moves the vertices it uses, each along its own normal.

The drag amount (a scalar) is the screen-plane movement projected onto the **average** normal (drag out = inflate, drag in = deflate). The Working Pivot is briefly aligned to that average normal for visual feedback, then **restored** on release (non-destructive). If a vertex normal can't be found, that vertex falls back to +Z.

- Modifier match is **exact** (Ctrl+Shift only), so it never collides with a Shift-only tool. Middle alone pans; the left button is never touched.
- The whole drag is one undo (`Move Verts (vertex normals)`, via `theHold`).

---

## 동작 원리 / How it works

1. `pivotZDrag.ms`가 `PivotZHook.cs`를 메모리에 컴파일(`CSharpCodeProvider`)하고, **3ds Max가 포그라운드일 때만** 동작하는 저수준 마우스 훅을 설치합니다.
2. MAXScript가 `#selectionSetChanged` / `#modPanelSubObjectLevelChanged` 이벤트(폴링 없음)로 훅의 `Armed` 플래그를 서브오브젝트 레벨과 동기화합니다.
3. Ctrl+Shift + 중간 버튼 다운(무장 상태, 정확한 매칭) 감지 시, 훅이 중간 다운/업을 삼켜(패닝 방지) **메시지 전용 윈도우**(PostMessage, 셀프 코얼레싱)를 통해 스트리밍합니다 — 부드러운 이동, 재진입 없음, 커서 멈춤 없음.
4. MAXScript가 드래그 시작 시 각 버텍스의 **자체 로컬 노멀**(해당 버텍스를 사용하는 페이스 노멀의 합)과 **평균 노멀**을 한 번 계산합니다. 선택 무게중심을 통과하는 화면 평면에 커서를 투영하고, 평균 노멀 방향 성분을 스칼라로 추출하여 **각 버텍스를 자신의 노멀 방향으로** 그 양만큼 `polyOp.setVert` 배치 호출 1회로 이동 — 단일 `theHold` 언두 블록 내에서 실시간으로.

---

1. `pivotZDrag.ms` compiles `PivotZHook.cs` in memory (CSharpCodeProvider) and installs a low-level mouse hook that acts only while **3ds Max is foreground**.
2. MAXScript keeps the hook's `Armed` flag in sync with the sub-object level (event-driven via `#selectionSetChanged` / `#modPanelSubObjectLevelChanged` — no polling timer).
3. On Ctrl+Shift + middle-down (armed, exact match), the hook swallows the middle down/up (no pan) and streams the drag through a **message-only window** (PostMessage, self-coalescing) — smooth, never re-entrant, moves never swallowed (no cursor freeze).
4. MAXScript computes each vertex's **own local normal** (sum of the normals of the faces using it) once at drag start, plus the **average** normal. It projects the cursor onto a screen-plane through the selection, takes the component along the average normal to get a scalar, and moves **each vertex along its own normal** by that amount with one batched `polyOp.setVert` — live, inside a single `theHold` undo.

---

## 설치 / Install

1. `PivotZHook.cs`와 `pivotZDrag.ms`를 **같은 폴더**에 보관하세요.
2. **Scripting > Run Script…** → `pivotZDrag.ms`. 즉시 시작됩니다.
3. 다시 실행하면 토글, 또는 **PivotZDrag** 매크로 사용 (Customize > Toolbars, 카테고리 *pivotZDrag*).

---

1. Keep `PivotZHook.cs` and `pivotZDrag.ms` **together** in the same folder.
2. **Scripting > Run Script…** → `pivotZDrag.ms`. Starts immediately.
3. Run again to toggle, or use the **PivotZDrag** macro (Customize > Toolbars, category *pivotZDrag*).

---

## 설정 / Configuration

- **수식어 세트:** `pivotZDrag_start()` 내에서 `pzd_hook.Modifiers` 설정 — 정확한 비트마스크 `1=Ctrl, 2=Alt, 4=Shift` (기본값 `Ctrl+Shift` = `5`).
- **Modifier set:** in `pivotZDrag_start()` set `pzd_hook.Modifiers` — an exact bitmask of `1=Ctrl, 2=Alt, 4=Shift` (default `Ctrl+Shift` = `5`).

---

## 참고 사항 / Notes & caveats

- **Editable Poly 전용.** Editable Mesh는 지원하지 않습니다 (Editable Poly로 변환하세요). Edit Poly 모디파이어도 지원하지 않습니다 — 베이스 Editable Poly 오브젝트에 직접 작동합니다.
- 이동당 `polyOp.setVert <poly> <bitArray> <pos_array>` 배치 호출 1회 (큰 선택도 빠름).
- 화면↔월드 매핑은 **활성 뷰포트** 기준 — 활성 뷰포트에서 드래그하세요.
- 버텍스별 노멀 = 해당 버텍스를 사용하는 페이스 노멀의 합 (드래그 시작 시 로컬 공간에서 한 번 계산).
- `shiftVertexDrag`(Shift 단독)와 정확한 수식어 매칭으로 공존합니다 — Ctrl+Shift가 두 도구를 동시에 트리거하지 않습니다.
- Windows 전용.

---

- **Editable Poly only.** Editable Mesh is not supported (convert to Editable Poly). Edit Poly modifier is not handled either.
- Vertex writes use one batched `polyOp.setVert <poly> <bitArray> <pos_array>` call per move (fast on large selections).
- Uses the **active viewport** for screen↔world mapping; drag in the active viewport.
- Per-vertex normal = sum of the normals of the faces using that vertex (computed once at drag start, in local space).
- Coexists with `shiftVertexDrag` (Shift only) because the modifier match is exact — Ctrl+Shift never triggers both.
- Windows only.

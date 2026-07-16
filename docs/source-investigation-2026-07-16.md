# grok-delegate 소스 조사 노트 (2026-07-16)

xAI가 grok CLI를 오픈소스로 공개(`github.com/xai-org/grok-build`)한 것을 계기로,
grok-delegate 스킬에서 의심되던 동작을 소스로 직접 확인했다. 검토 대상 체크아웃은
오픈소스 버전 **0.2.101**, 로컬에 설치된 grok 실행본은 **0.2.99**
(`~/.local/bin/grok`, stable)다. 조사에 쓴 소스는 `vendor-grok-build/`로 클론했고
submodule이 아니라 `.gitignore`에 넣어 버전관리에서 제외했다.

---

## A. "research 모드가 막힌다" 버그 — 상류에서 이미 수정됨

### 배경
SKILL.md와 `scripts/grok-run.sh`는 grok **0.2.93**에서 확인된 버그를 겨눠 설계됐다.
`--tools`에 웹 툴을 넣으면(예: `read_file,grep,list_dir,web_search,web_fetch`) 세션
빌드가 실패하고 stderr에 `agent building failed … run_terminal_cmd …
auto_background_on_timeout`류 메시지가 났다. 그래서 wrapper는 `research` 모드를
이 에러에 한해 **fail-closed**시키고, 대신 write+shell을 쥔 `research-rw` /
`fix -w`를 명시적 승인 하에만 쓰도록 안내했다.

### 수정 시점 — CHANGELOG에 명시
`crates/codegen/xai-grok-shell/CHANGELOG.md`:

> **0.2.98 — 2026-07-12** · Bug Fixes
> **Web search** and X search no longer fail when both a local function tool and
> the backend hosted tool are active.

즉 문제의 뿌리(로컬 함수 툴 + 백엔드 호스티드 툴이 동시에 활성일 때 세션 빌드
실패)가 **0.2.98에서 수정**됐다. 관련 선행 변경으로 "Backend search is now enabled
by default for web_search and x_search"도 CHANGELOG에 있다(백엔드 호스티드 웹 검색이
기본값이 됨).

### 소스 메커니즘 (0.2.101 기준으로 재확인)
`--tools` allowlist는 base 툴셋을 **엄격히 좁히는 retain**이다:

- `crates/codegen/xai-grok-agent/src/builder.rs:920` 부근 —
  allowlist에 이름이 없고 kind가 `SearchTool`/`UseTool`도 아니고 `task(...)`
  지시도 없으면 `run_terminal_cmd`·`task`·`get_task_output`·`kill_task`·`wait_tasks`가
  전부 제거된다.
- `builder.rs:803` 부근 — `task`가 빠지고 background 가능한 bash 공급자가 없으면
  고아가 된 `get_task_output`/`wait_tasks`/`kill_task`를 정리한다.
- `builder.rs:994` 부근 — 비어있지 않은 allowlist에 `task(...)` 지시가 없으면
  살아남은 `run_terminal_cmd`를 `enabled_background=false` +
  `auto_background_on_timeout=false`로 강등한다.
- requirement 검사(`crates/codegen/xai-grok-tools/src/registry/types.rs:1803`)는
  `enabled_background`가 true일 때만 발동한다(`.unwrap_or(true)`). 강등되면 면제.

웹 툴 자체는 의존성이 없다:
- `web_fetch`: `requires_expr = Expr::True`
  (`…/implementations/grok_build/web_fetch/mod.rs:130`), `is_read_only: true`.
- `web_search`: `requires_expr = Expr::True`, kind `WebSearch`
  (`…/implementations/grok_build/web_search/mod.rs:44`).

따라서 `{read_file, grep, list_dir, web_search, web_fetch}` 조합은 requirement
검사를 전부 통과하고, 0.2.93식 빌드 실패가 구조적으로 발생할 수 없다.

### 라이브 실증 (0.2.99)
- wrapper 우회, 정확히 `--tools "read_file,grep,list_dir,web_search,web_fetch"`로
  직접 호출 → 빌드 성공, `web_fetch` 호출, exit 0.
- wrapper `research` 모드 연속 실행 → exit 0, 실제 웹 수집(`web_fetch`) 확인.

### 결론
wrapper는 "0.2.93 빌드 에러를 per-run 감지 → 새 grok에서 자동 복구"로 설계돼 있었고,
설계대로 **research 모드는 현재(0.2.98+) 그냥 동작한다.** 0.2.99를 쓰는 지금은
`research`가 정상 경로이며 `research-rw`로 우회할 이유가 없다.

---

## B. 실제로 걸려 있던 버그 — 수집 게이트 오탐 (수정 완료)

### 증상
첫 라이브 테스트에서 grok이 웹을 **실제로 호출했는데도**
(usage 트레일러: `tools=WebFetch,WebSearch`) wrapper가
`FAILED: research run made no web tool call`로 exit 1을 냈다. 성공한 research를
"수집 안 함"으로 오판한 것.

### 원인 — signals.json의 두 가지 이름 규칙
`~/.grok/sessions/.../signals.json`의 `toolsUsed`가 라우팅에 따라 다른 표기로 나온다:

- **로컬 함수 툴**: `web_fetch` / `web_search` (snake_case)
- **백엔드 호스티드 툴** (0.2.98부터 기본값): `WebFetch` / `WebSearch` (PascalCase)

실측 확인:
- 백엔드 경로 세션: `toolsUsed = ["WebFetch","WebSearch"]`
- 로컬 경로 세션: `toolsUsed = ["web_fetch", …]`

게이트 정규식은 대소문자 구분 + snake 전용이라 백엔드 표기를 못 잡았다:
`grep -qE '(^|,)web_(search|fetch)(,|$)'` → `WebFetch` 불일치 → 성공을 실패 처리.
백엔드 검색이 기본값이 된 지금은 **성공한 research가 상시 오탐**될 수 있었다.

### 수정 (적용됨)
`scripts/grok-run.sh` 게이트를 대소문자 무시 + 언더스코어 선택으로 교체:

```
- ! grep -qE  '(^|,)web_(search|fetch)(,|$)'  <<<"$GROK_TOOLSUSED"
+ ! grep -qiE '(^|,)web[_]?(search|fetch)(,|$)' <<<"$GROK_TOOLSUSED"
```

검증:
- 유닛: `WebFetch,WebSearch` · `web_fetch` · `web_search,web_fetch` · `WebSearch`
  전부 매칭, `list_dir,read_file` · `write`는 비매칭.
- 라이브: 수정 후 research 재실행 시 게이트 통과, 정상 수집 세션 exit 0.

주석에 두 이름 규칙의 근거를 함께 남겼다.

---

## C. 빌드에러 감지 브랜치의 일시오류 오탐 — 정체와 대응안

### 무엇이 "일시오류 오탐"인가
`scripts/grok-run.sh`의 빌드에러 감지(대략 249행):

```bash
if grep -qiE 'agent building failed|auto_background_on_timeout' <<<"$ERR"; then
  if [[ "$MODE" == "research" ]]; then
    echo "FAILED: research mode is unavailable on this grok build (0.2.93)."
    ...  # research-rw / fix -w 로 안내
```

grok stderr에 위 두 문자열 중 하나라도 있으면, wrapper는 그 실패를 **"0.2.93 버전
버그"로 단정**하고 write+shell 경로(`research-rw`)로 유도한다.

재현 중 관찰된 것:
- research 호출을 짧은 간격으로 연달아 돌리던 중 **두 번** 이 브랜치가 발동
  (`FAILED: research unavailable on 0.2.93` + `no signals.json — run likely
  failed before a session was built`).
- 3초 쉬고 재실행하면 **정상 exit 0**. 직접 grok 호출은 stderr 비어있고 exit 0.
- 앞선 A절에서 0.2.99는 그 버전 버그가 구조적으로 불가능함을 소스로 확인함.

→ 그 두 실패는 실제로 세션이 안 만들어진 건 맞지만, 원인은 **연속 호출로 인한
일시적 backend/rate-limit성 오류**로 보이고, wrapper는 이를 **0.2.93 버전 버그로
잘못 귀속**했다. 실패 자체가 오탐이 아니라, **실패의 "원인 진단과 그에 따른 안내"가
오탐**이다.

### 왜 위험한가
- 실제로는 "잠깐 뒤 재시도하면 되는 일시 오류"인데, 사용자/Claude에게는 "이 grok
  빌드에선 research가 안 되니 write+shell을 쥔 `research-rw`를 승인하라"고 읽힌다.
  불필요하게 **덜 안전한 경로로 에스컬레이션**을 유도한다.
- 0.2.98+에서는 그 버전 버그가 발생할 수 없으므로, 이 버전대에서 저 문구가 뜨면
  **거의 항상 오귀속**이다.
- 재현이 어렵다(간헐적, 부하 의존). 그래서 "정확한 트리거 조건"을 소스로 못 박기 힘들다.

### 대응안 (구현 부담·안전도 순, 아직 미적용)

1. **문구 완화 + 재시도 안내 (가장 낮은 위험, 권장 출발점)**
   - "research unavailable on this grok build (0.2.93)" 단정을 버리고,
     "grok이 세션을 만들지 못했다 — 이 빌드의 allowlist+web 버그이거나, 일시적
     backend/rate-limit 오류일 수 있다. 잠깐 뒤 한 번 재시도하고, 그래도 반복되면
     그때 research-rw/fix를 고려하라"로 바꾼다.
   - 진단을 단정하지 않으므로 오귀속이 사라진다. 동작 변화 없음(감지 로직 그대로).

2. **버전 게이트로 귀속 분기**
   - 런타임에 `grok --version`을 읽어, `< 0.2.98`일 때만 "0.2.93 버그"로 안내하고,
     `>= 0.2.98`에서는 같은 stderr라도 **일시 오류로 취급 → 재시도 권고**, research-rw로
     유도하지 않는다.
   - 버전대에 맞는 정확한 진단이 되지만, 버전 파싱/비교 로직이 추가된다.

3. **research 빌드 실패 시 1회 자동 재시도**
   - 빌드에러 브랜치에 걸리면 짧게 대기 후 한 번 자동 재실행하고, 그래도 실패할 때만
     최종 FAILED로 확정. 일시 오류(재시도로 회복)와 항구 버그(재시도로도 실패)를
     동작으로 구분한다.
   - 오탐을 실효적으로 없애지만, 호출당 지연·비용이 늘고 wrapper 흐름이 복잡해진다.
     (2번과 결합하면 가장 견고하다.)

4. **트리거 시그니처 협소화**
   - `agent building failed|auto_background_on_timeout` 대신 0.2.93 실패의 전체
     시그니처(예: `run_terminal_cmd` + `auto_background_on_timeout`가 함께 등장하는
     경우로 AND 조건)로 좁힌다.
   - 다만 재현 로그가 없어 "일시 오류가 어떤 문자열을 뱉는지"를 못 박기 어렵다.
     검증 불가한 추정 기반이라 이 방법만으로는 신뢰도가 낮다.

### 권고
현재 버전대(0.2.99)에서 이 브랜치의 진단은 사실상 오귀속이므로, **1번(문구 완화 +
재시도 안내)을 기본으로 하고, 여력이 되면 2번(버전 게이트)과 3번(1회 재시도)을 얹는
조합**이 안전·정확·비용의 균형이 좋다. 4번은 재현 로그가 확보되기 전에는 단독 채택
비권장.

---

## 부기: 실측 요약
- 설치 grok: **0.2.99** / 오픈소스 체크아웃: **0.2.101** / 수정 도입: **0.2.98**
- 이번에 적용한 코드 변경: `.gitignore`(vendor 제외), `scripts/grok-run.sh`
  게이트 정규식 대소문자·언더스코어 대응.
- 미적용(문서화만): SKILL.md의 "research fails-closed(0.2.93)" 서술 최신화,
  위 C절 오탐 대응안.

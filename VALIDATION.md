# Shortcup v0.1 실제 검증 결과

2026-10-08, 이 Mac의 macOS 26.6.2 / Apple Silicon / 한국어 Safari·Chrome·Finder에서 확인.

**고정 범위 완료: 대표 액션 입력 경로 32개 통과. 최종 자동 실행은 준비·동작 결과·안전성 검사를 포함해 62개 검사 통과, 실패 0개.** 완료 요약 행은 검사 개수에서 제외한다.

## 방법과 근거

사용자가 접근성 권한과 CGEvent 검증 입력을 명시적으로 허용했다. Computer Use로 권한 설정, 앱 UI, 최종 패널 화면을 확인했다. Computer Use의 좌표 클릭은 `noWindowsAvailable`로 실패했고, 의미 기반 메뉴 클릭은 실제 마우스 이벤트를 만들지 않아 감지 검증에 쓸 수 없었다. 이후 앱의 명시적 `--validate-once` 모드에서 CGEvent로 실제 마우스 down/up/drag와 키 입력을 보내고, 제품의 클릭 감지기가 만든 힌트를 실제 메뉴의 접근성 단축키와 대조했다.

메뉴의 숨겨진 Option 대체 항목을 기대값으로 잡지 않도록 클릭 좌표의 실제 요소를 기준으로 대조한다. 검증용 웹페이지와 파일은 `build/validation-fixtures` 아래에 만들었고, Finder의 생성·복제·열기는 매 실행마다 새로 만든 격리 폴더에서만 수행했다. 기존 사용자 파일은 수정·삭제하지 않았다. 검증용 창·탭과 테스트 파일은 남아 있다.

전체 기계 판독 결과: [validation-results.json](build/validation-results.json). 클릭 힌트 기록: [validation-events.jsonl](build/validation-events.jsonl). 힌트 기록에는 이전 디버깅 실행도 포함된다.

## 고정 액션 결과

아래 키는 이 환경에서 읽은 값이다. 제품은 이 값을 하드코딩하지 않고 실행 중인 앱 메뉴에서 읽는다.

| 입력 경로 | Safari | Chrome |
|---|---|---|
| 메뉴: 새 창 | ⌘N, 통과 | ⌘N, 통과 |
| 메뉴: 새 탭 | ⌘T, 통과 | ⌘T, 통과 |
| 메뉴: 탭 닫기 | ⌘W, 통과 | ⌘W, 통과 |
| 메뉴: 닫은 탭 다시 열기 | ⇧⌘T, 통과 | ⇧⌘T, 통과 |
| 버튼: 새 탭 | ⌘T, 통과 | ⌘T, 통과 |
| 주소창 클릭 | ⌘L, 통과 | ⌘L, 통과 |
| 버튼: 뒤로 | ⌘[, 통과 | ⌘[, 통과 |
| 버튼: 앞으로 | ⌘], 통과 | ⌘], 통과 |
| 버튼: 새로고침 | ⌘R, 통과 | ⌘R, 통과 |
| 메뉴: 확대 | ⌘+, 통과 | ⌘+, 통과 |
| 메뉴: 축소 | ⌘−, 통과 | ⌘−, 통과 |
| 메뉴: 찾기 | ⌘F, 통과 | ⌘F, 통과 |

| Finder 메뉴 | 관찰한 단축키 | 결과 |
|---|---|---|
| 새 창 | ⌘N | 통과 |
| 새 폴더 | ⇧⌘N | 통과, 폴더 생성 확인 |
| 열기 | ⌘O | 통과, 새 폴더가 열린 창 확인 |
| 정보 가져오기 | ⌘I | 통과 |
| 복제 | ⌘D | 통과, 테스트 파일 수 증가 확인 |
| 아이콘 보기 | ⌘1 | 통과 |
| 목록 보기 | ⌘2 | 통과 |
| 상위 폴더 | ⌘↑ | 통과 |

## 추가 확인

- 각 브라우저에서 ⌘T로 실제 창 제목이 테스트 페이지에서 새 탭으로 바뀌며, 마우스 힌트를 추가하지 않음.
- 웹 내부에 같은 이름의 ‘새 탭’ 버튼이 있어도 힌트 없음: 두 브라우저 통과.
- 도구 막대 버튼을 40px 드래그한 뒤 원위치에서 놓아도 힌트 없음: 두 브라우저 통과.
- 새 탭의 비활성 뒤로 버튼을 클릭해도 힌트 없음: 두 브라우저 통과.
- Finder ‘모두 앞으로 가져오기’에 실제 단축키가 없으며 ‘단축키 미지정’ 표시: 통과.
- ⌃⌥⌘H 접기·펼치기, Finder 포커스 유지, 일시정지 중 실제 메뉴 클릭 무시 및 재개: 통과.
- 빌드의 실행 가능한 assert 검사: 수정자·특수 키 포맷, 모호한 연결 거부, 미지정/비활성 명령 제외, 정확한 브라우저 라벨, 앱별 최근 3개와 중복 제거 통과.
- Computer Use 최종 화면: Finder의 최근 3개 ‘목록’, ‘모두 앞으로 가져오기’, ‘열기’와 키·출처·접기 안내가 잘리지 않고 표시됨.
- 권한이 없는 초기 상태에서 안내 패널 표시, 권한 부여 후 자동 감지 시작을 확인함.

## 검증 중 수정한 문제

1. 앱 전환 시 패널이 사라지는 문제: 비활성 패널의 `hidesOnDeactivate` 해제.
2. 클릭한 앱 대신 당시 활성 앱을 읽는 문제: hit-test 요소의 PID를 사용.
3. Chrome의 긴 동적 메뉴 때문에 단축키 탐색이 누락되는 문제: 필요한 메뉴 그룹과 정확한 명령 이름을 우선 탐색.
4. Safari의 한국어 새로고침 라벨 연결 누락: 실제 ‘이 페이지 다시 로드’/‘페이지 다시 로드’ 라벨 추가.
5. 원위치로 돌아오는 드래그를 클릭으로 취급하는 문제: 중간 drag 이벤트에서도 후보 취소.
6. 검증 준비 문제: Safari 로컬 파일 열기 확인 창 처리, 페이지가 열린 결과 확인, Finder의 숨겨진 대체 메뉴 항목을 클릭 기대값으로 사용하는 오류 수정.

## 한계와 후속 작업

이 버전은 단축키 학습을 돕는 앱이다. 새 단축키를 만들어 모든 마우스 작업을 대체하지 않는다. 웹 내부 작업, 드래그 대체, 그리기/타임라인, OS 제스처는 계획대로 제외했다. 다른 앱·언어·macOS 버전, 물리 트랙패드 입력, 다중 모니터·전체 화면은 실제 검증하지 않았다. 현재 빌드는 이 Mac의 SDK 기본 배포 대상으로 만들어져 macOS 26 이상이 필요하다. 이전 macOS와 Intel 배포는 별도 빌드·검증이 필요하다.

개발용 ad-hoc 서명이라 재빌드하면 접근성 권한을 다시 등록해야 할 수 있다. Developer ID 서명·공증과 배포 설치 프로그램은 만들지 않았다. 메뉴 접근성 정보나 앱 UI 라벨이 바뀌면 해당 연결을 다시 검증해야 한다. 일반 실행은 클릭을 관찰하며 키 입력 기록·화면 녹화·외부 전송을 하지 않는다. 검증용 진단 기록은 최종 확인 후 비활성화했다.

## 창 버튼 매핑

`zsh build.sh`의 순수 함수 검사. 단축키 문자열은 메뉴 항목에서 온 값을 포맷한 결과다.

- 표준 창의 버튼 참조와 클릭 요소가 같을 때만 힌트를 낸다. 탭·시트의 닫기 버튼은 제외한다.
- ⇧+⌘+W 포맷은 `⇧⌘ W`. 전체 화면 식별자에 ⌘가 있는 단축키와 ⌘ 없는 F가 같이 있으면 ⌘가 있는 쪽만 보여 준다. ⌘ 없는 F만 있으면 힌트 없음. `🌐F`는 쓰지 않는다.
- 식별자가 있고 단축키가 없으면(Chrome의 `performZoom:`) 제목으로 다시 찾지 않는다.
- 식별자가 없으면 파일·윈도우·보기 메뉴의 제목으로 찾는다. Finder가 이 경우다.
- 창 버튼 경로는 `validation-events.jsonl`과 `validation-state.json`에 힌트와 프로브를 쓰지 않는다.
- 글리프 99(Caps Lock)와 103(Help)는 힌트가 없다. Home은 102, End는 105다. 가상 키 0은 없는 값으로 본다.

실제 클릭으로 힌트가 뜨는지는 v0.1의 62개 검사에 포함되지 않는다. 이 워크스페이스에서는 아직 트래픽 라이트 클릭을 확인하지 못했다.

### 메뉴 식별자 덤프

터미널에만 찍는다. 파일로 저장하지 않는다. 열은 식별자, 단축키, 대응하는 subrole이다. 메뉴 제목, 창 제목, 버튼 이름, 글자 내용은 출력하지 않는다. 손쉬운 사용 권한이 이 빌드에 있어야 한다.

```sh
# 앱이 실행 중이어야 한다. 번들 ID를 생략하면 현재 앞 앱을 본다.
build/Shortcup.app/Contents/MacOS/Shortcup --dump-window-menu-ids com.apple.finder
build/Shortcup.app/Contents/MacOS/Shortcup --dump-window-menu-ids com.apple.Safari
build/Shortcup.app/Contents/MacOS/Shortcup --dump-window-menu-ids com.google.Chrome
build/Shortcup.app/Contents/MacOS/Shortcup --dump-window-menu-ids com.microsoft.VSCode
build/Shortcup.app/Contents/MacOS/Shortcup --dump-window-menu-ids com.apple.MobileSMS
```

Juhyeon의 Mac(macOS 26.6.2) 덤프:

- Chrome 154: `performClose:`는 ⇧⌘W 하나(충돌 없음). `performMiniaturize:`는 ⌘M. `toggleFullScreen:`은 ⌃⌘F와 ⌘ 없는 F 둘. `performZoom:`는 단축키 없음.
- Finder: 닫기·최소화·전체 화면 항목에 `AXIdentifier`가 없다. 제목 폴백이 필요하다.

Safari의 탭 닫기가 `performClose:`인지는 이 덤프에 없다. 실제 버튼 클릭은 아직이다. 손쉬운 사용에 이 워크스페이스의 `build/Shortcup.app`을 넣은 뒤, 표준 창의 닫기·최소화·전체 화면을 눌러 패널 힌트를 확인하면 된다. 애드혹 서명이라 다시 빌드하면 권한을 다시 줘야 할 수 있다. `~/shortcup`의 앱과는 다른 경로다.

## 빠른 검증

`zsh verify.sh`는 앱을 열지 않는다. 클릭도 보내지 않는다. 스냅샷 재생, 제품 바이너리에 개발용 자가시험이 없는 것, 전용 키체인 서명, 결과 JSON 형식, 디스크의 카나리 문자열만 본다. 창을 띄우는 검사는 `zsh verify.sh --live` 뒤에만 있다. 그 플래그는 화면에 경고를 찍은 뒤 오른쪽 아래 모서리에 작은 픽스처 창을 연다. 기본 명령으로는 실행하지 않는다. `--direct-launch`만 주고 `--live`를 빼면 아무 앱도 시작하지 않는다.

서명은 로그인 키체인이 아니라 `~/Library/Keychains/shortcup-dev.keychain-db`의 `Shortcup Dev` 인증서를 쓴다. 비밀번호 파일은 `~/.config/shortcup/keychain-password`(모드 600)이고 저장소에 넣지 않는다. 비밀번호는 argv로 넘기지 않는다. `scripts/keychain.py`가 그 파일을 읽어 키체인을 연다. SAFE 모드는 `build/Shortcup Dev.app`에만 서명하고 `~/Applications`로 복사하지 않는다. `--live`이면서 실행 방법이 `open`일 때만, 설치본이 없거나 바이너리가 다를 때 `~/Applications/Shortcup Dev.app`으로 복사한다. 실행 중인 개발 앱은 끝내지 않고 서명 단계를 실패로 둔다. 번들 ID는 `com.shortcup.dev`라서 `~/shortcup`의 앱과 권한이 섞이지 않는다. `codesign -d -r-`에 `certificate leaf`가 있어야 재빌드 뒤에도 같은 권한으로 남는다.

`--selftest`와 합성 클릭은 `-D SHORTCUP_DEV` 빌드에만 들어간다. 제품 빌드에는 컴파일하지 않는다. 클릭은 픽스처 창 프레임 안이고, 시스템 전역 hit의 pid가 픽스처와 같을 때만 검사한다. pid가 다르면 다른 속성을 읽지 않고 `skip`으로 남긴다. 닫기·최소화·전체 화면·확대(줌) 버튼은 클릭하지 않는다. 케이스 결과는 `pass`, `fail`, `skip`이다. `skip`은 통과가 아니다.

이 Mac의 기본 실행은 `open -g -n -W`다. `-g`는 앱을 앞으로 가져오지 않는다. GitHub의 macos-26 러너에서는 bash가 직접 시작한 프로세스가 손쉬운 사용을 받고, `open -g`로 띄운 애드혹 앱은 LaunchServices가 그 앱을 책임 프로세스로 만들어서 못 받을 수 있다. 러너에서는 `zsh verify.sh --live --direct-launch` 또는 `SHORTCUP_LAUNCH=direct zsh verify.sh --live`를 쓴다. 이 Mac에서 바이너리를 직접 실행하면 터미널이나 Cursor의 손쉬운 사용을 물려받으므로, 여기서의 기본은 `open -g`다. Terminal이나 Cursor에 손쉬운 사용을 주지 않는다.

두 방식 모두 개발 앱과 픽스처는 `LSUIElement`이고 Dock 아이콘이 없다. `activate`를 부르지 않고, 키 윈도우가 되지 않는다. 모달 시트 대신 활성화되지 않는 패널을 쓴다. 개발 앱은 결과 JSON에 자기 `AXIsProcessTrusted()` 값(`axTrusted`)과 실행 방법(`launchMethod`: `open` 또는 `direct`)을 적는다. `verify.sh`가 개발 앱에 `--launch-method open|direct`를 넘기고, 그 값이 JSON에 들어간다. 멈춘 실행은 quit 파일을 만든 뒤, 그 실행이 기록한 pid만 종료한다.

Chrome·Finder 스냅샷은 위의 메뉴 덤프를 재생용 JSON으로 옮긴 것이다. 라이브 녹화는 개발 앱의 손쉬운 사용이 생긴 뒤에야 가능해서, 아직 그 앱으로 다시 받지는 않았다. 글리프 99(Caps Lock)와 103(Help)는 힌트가 없다. 이 규칙은 바꾸지 않았다. 이 Mac의 일반 창은 `AXFullScreenButton`을 주지 않는다(오류 -25212). Chrome의 전체 화면 단축키 `⌃⌘ F`는 스냅샷으로 확인한다.

KNOWN-FAIL 두 개는 실패로 세지 않고, 통과로 치지도 않는다. 예전 `--validate-once`가 주소 칸 값을 쓰는 것, 메뉴·도구막대 검증 로그에 명령 제목이 남는 것이다. 이번 검사에서는 그 모드를 실행하지 않는다.

### 나중에 `--live`를 켤 때 한 번만 할 일

1. 저장소에서 `zsh setup-dev-signing.sh`. 전용 키체인에 인증서를 만든다. 이 Mac에는 이미 만들어져 있다. 로그인 키체인 암호 창이 뜨면 취소한다. 서명에 그 창은 필요 없다.
2. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 **Shortcup Dev** (`/Users/juhyeon/Applications/Shortcup Dev.app`, `com.shortcup.dev`)만 켠다. 켠 뒤 그 앱을 끝내고 다시 연다.
3. 스위치는 켜져 있는데 `verify.sh --live`가 여전히 권한 없음이면, 그 번들만 `tccutil reset Accessibility com.shortcup.dev` 하고 다시 켠다. 다른 앱은 리셋하지 않는다.
4. Terminal과 Cursor에는 손쉬운 사용을 주지 않는다.

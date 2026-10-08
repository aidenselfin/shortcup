# Shortcup

트랙패드로 실행한 메뉴·창 버튼·브라우저 버튼의 단축키를 왼쪽 패널에 표시하는 macOS 네이티브 앱.

## 실행

```sh
cd ~/shortcup
zsh build.sh
open build/Shortcup.app
```

빌드에는 macOS Command Line Tools의 Swift만 필요합니다. 추가 패키지는 없습니다. 현재 제공 빌드는 Apple Silicon / macOS 26 이상이며, 이 Mac에서 검증했습니다.

시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Shortcup을 허용하세요. 패널의 '접근성 설정 열기' 버튼으로 이동할 수 있습니다.

개발 빌드는 ad-hoc 서명입니다. 재빌드 후 설정에는 권한이 켜져 있는데 패널에 권한 안내가 계속 나오면 목록의 Shortcup을 제거한 뒤 현재 `build/Shortcup.app`을 다시 추가하세요. 배포용 Developer ID 서명과 공증은 별도 작업입니다.

## 사용

- 메뉴 항목을 마우스로 실행하면 해당 메뉴의 실제 단축키를 표시합니다.
- 표준 창의 닫기·최소화·전체 화면 버튼을 누르면, 그 앱의 파일·윈도우·보기 메뉴에 있는 실제 단축키를 표시합니다. 메뉴 식별자로 찾고, 식별자가 없을 때만 제목으로 찾습니다. 못 찾으면 표시하지 않습니다.
- Safari·Chrome의 새 탭, 뒤로, 앞으로, 새로고침과 주소창은 앱 메뉴의 단축키와 연결합니다.
- 앱마다 최근 3개 힌트를 표시합니다. 같은 작업은 중복되지 않습니다.
- ⌃⌥⌘H로 패널을 접거나 펼칩니다. 메뉴 막대 `⌘ SC`에서 일시정지·종료할 수 있습니다.
- 단축키가 없는 메뉴는 '단축키 미지정'으로 표시합니다. 모르는 버튼에는 추측한 키를 표시하지 않습니다.

앱이 제공하는 접근성 정보가 지원 범위를 결정합니다. 영어·한국어 브라우저 라벨을 지원하며 다른 언어의 버튼 연결은 추가해야 합니다. 웹사이트 내부 버튼, 드래그, 캔버스 작업은 지원 범위에 포함하지 않습니다.

## 개인정보 및 권한

일반 실행은 마우스 클릭 down/up 및 드래그 이동을 수동 관찰하고, 클릭한 요소와 메뉴의 이름·단축키를 읽습니다. 키 입력·주소창 내용·문서 내용을 기록하지 않으며 화면 녹화와 외부 전송은 없습니다. 힌트는 메모리에만 남고 종료 시 지워집니다. 접근성 권한 자체는 UI 제어도 허용하는 넓은 OS 권한이므로 필요하지 않을 때는 해제할 수 있습니다.

## 검증

`zsh build.sh`는 단축키 포맷·모호한 연결 거부·비활성 명령 제외·최근 힌트 검사를 실행합니다.

실제 입력 검증은 **별도 명시적 실행**입니다. Safari·Chrome·Finder의 테스트 창을 조작하므로 다른 작업을 잠시 멈추고 실행하세요.

```sh
touch build/validation-enabled
open -n build/Shortcup.app --args --validate-once
```

이미 실행 중인 Shortcup은 먼저 메뉴 막대에서 종료하세요. 검증 모드만 CGEvent로 실제 클릭과 단축키를 보냅니다. 일반 실행에는 입력 생성이 없습니다. 검증 파일은 `build/validation-fixtures`에 생성하며 결과는 `build/validation-results.json`, 힌트는 `build/validation-events.jsonl`, 상태는 `build/validation-state.json`에 남습니다. 검증 기록에는 명령 이름과 단축키만 들어갑니다. `build/validation-enabled`를 삭제하면 일반 실행의 진단 기록을 중단합니다.

고정 범위와 완료 기준은 [PLAN.md](PLAN.md), 실제 검증 결과는 [VALIDATION.md](VALIDATION.md)를 참조하세요.

## 개인정보 검사

GitHub Actions의 `privacy-scan`이 모든 push와 PR에서 개인 경로, 키·인증서 파일, 토큰을 검사합니다. 결과에는 파일·줄·규칙만 남습니다.

푸시 전에 같은 검사를 로컬에서 돌리려면 이 저장소에만 pre-push 훅을 설치하세요. 전역 git 설정은 바꾸지 않습니다.

```sh
cd ~/shortcup
bash scripts/install-pre-push-hook.sh
```

- 훅은 푸시하는 커밋만 검사합니다. 작업 폴더는 보지 않으며, `scripts/`가 없는 브랜치에서도 동작합니다.
- 기존 pre-push 훅이 있으면 설치를 멈춥니다. 바꾸려면 `--force`를 붙이세요.
- [gitleaks](https://github.com/gitleaks/gitleaks)가 필요합니다. 없으면 푸시를 거부합니다. 잠시 건너뛰려면 `SHORTCUP_PRIVACY_SKIP_GITLEAKS=1 git push`를 쓰세요. 경고가 출력됩니다.
- 검사 스크립트를 고친 뒤에는 `--force`로 다시 설치하세요.

`.gitleaks.toml`의 과거 커밋 SHA 허용 목록은 squash 또는 merge commit으로 합치는 것을 전제로 합니다. rebase로 그 커밋의 SHA가 바뀌면 허용이 풀리고 검사가 다시 실패할 수 있습니다.

이 검사가 실제로 막으려면 저장소 주인이 GitHub에서 `privacy-scan`을 필수 검사로 두고, 코드 오너 리뷰를 켜 두어야 합니다. 워크플로 파일만으로는 강제되지 않습니다.

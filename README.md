# CONTRL 환경 준비

제안서 자동화 harness를 쓰기 위한 개발 환경을 한 번에 준비합니다. git과 GitHub CLI를 설치하고, GitHub 접근 토큰을 저장한 뒤, 저장소를 받아올 수 있는지 확인합니다.

## 시작하기 전에

아래 3단계가 끝나야 설치가 됩니다. 순서를 건너뛰면 마지막에 실패합니다.

1. GitHub 계정을 만듭니다 (이미 있으면 그대로 씁니다).
2. 계정 ID를 담당자에게 알려줍니다.
3. 초대 메일을 받으면 수락합니다.

## 설치

**macOS · Linux** — 터미널에서:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.sh)"
```

**Windows** — 시작 메뉴에서 Windows PowerShell을 열고:

```
irm https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.ps1 | iex
```

실행 중 GitHub 토큰을 입력하는 화면이 나옵니다. 토큰 발급 페이지가 자동으로 열리므로, 생성된 값을 복사해 붙여넣으면 됩니다. 입력한 값은 보안상 화면에 표시되지 않습니다.

## 잘 안 될 때

설치 실패 메시지에서 가장 흔한 원인은 두 가지입니다. 토큰을 만들 때 `repo` 항목을 체크하지 않았거나, 초대 메일을 아직 수락하지 않은 경우입니다. 둘 다 확인했는데도 실패하면 담당자에게 화면에 나온 메시지를 그대로 전달해 주세요.

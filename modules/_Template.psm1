<#
  새 탭 만들기 템플릿
  1) 이 파일을 modules\ 안에서 복사해 이름을 바꿉니다. 예) modules\MyTool.psm1  (이름이 _ 로 시작하면 무시됨)
  2) Title / Order 를 바꾸고 New-UtilTab 안에 화면을 만듭니다.
  3) UtilMonster 를 다시 실행하면 탭이 생깁니다.

  규칙
  - Get-UtilTabInfo : Title(탭 이름), Order(작을수록 왼쪽), Eager(true 면 시작할 때 바로 만듦 - 백그라운드 기능용)
  - New-UtilTab     : 탭을 처음 선택할 때 한 번 호출됨. $Page 에 컨트롤을 추가한다.
  - Stop-UtilTab    : (선택) 프로그램 종료 때 호출됨. 타이머/뮤텍스 정리용.
  - $Ctx.ConfigDir  : 설정 파일을 둘 폴더      $Ctx.Form : 메인 창      $Ctx.AppDir : UtilMonster 폴더
  - $Ctx.KeepAlive['이름'] = $true  : 창을 닫아도 트레이에서 계속 실행 (백그라운드 감시 등)
  - 모듈마다 변수/함수가 따로 격리되므로 다른 탭과 이름이 겹쳐도 괜찮다.
  - 이벤트 핸들러 안에서는 지역 변수 대신 $script:변수 를 쓴다.
  - 파일은 UTF-8 (BOM 포함) 으로 저장해야 한글이 깨지지 않는다 (Windows PowerShell 5.1).
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Get-UtilTabInfo { @{ Title = '템플릿'; Order = 900; Eager = $false } }

function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = '여기에 화면을 만드세요.'
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $Page.Controls.Add($label)
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab

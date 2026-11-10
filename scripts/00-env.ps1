# =============================================================
# EKS MSP Lab - 공통 환경 변수 / 템플릿 렌더 함수
# 사용법: 실습 폴더에서 점(.)을 붙여 실행해야 변수가 현재 창에 남음
#   . .\00-env.ps1
# =============================================================

# 1) 실습 계정 프로필 지정
#    다른 창에서 설정된 키 환경 변수가 있으면 AWS_PROFILE보다 우선하므로 먼저 제거
Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY, Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
$env:AWS_PROFILE = "team-user"

# 계정/역할 확인 (비밀 값은 출력되지 않음)
aws sts get-caller-identity
if ($LASTEXITCODE -ne 0) { throw "AWS 자격 증명 확인 실패. 'aws configure list --profile team-user'로 프로필 설정(액세스 키 유효 여부)을 확인하세요." }

# 2) 실습 변수
$CLUSTER_NAME        = "msp-lab"
$REGION              = "ap-northeast-2"
$K8S_VERSION         = "1.34"
$KARPENTER_VERSION   = "1.15.1"      # https://karpenter.sh/docs/getting-started/ 기준
$KARPENTER_NAMESPACE = "kube-system"
$ACCOUNT_ID          = (aws sts get-caller-identity --query Account --output text).Trim()
$MY_IP               = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()

$env:AWS_REGION = $REGION

# 3) 템플릿 치환 값 (__KEY__ 형태로 YAML에 들어 있음)
$VARS = @{
  CLUSTER_NAME = $CLUSTER_NAME
  REGION       = $REGION
  K8S_VERSION  = $K8S_VERSION
  ACCOUNT_ID   = $ACCOUNT_ID
  MY_IP        = $MY_IP
}

# __변수__ 자리를 채워서 out\ 폴더에 BOM 없는 UTF-8로 저장하고 경로 반환
function Render([string]$Path) {
  $src = (Resolve-Path $Path).Path
  $t = [IO.File]::ReadAllText($src)
  foreach ($k in $VARS.Keys) { $t = $t.Replace("__${k}__", [string]$VARS[$k]) }
  $outDir = Join-Path $PSScriptRoot "out"
  New-Item -ItemType Directory -Force $outDir | Out-Null
  $out = Join-Path $outDir (Split-Path $src -Leaf)
  [IO.File]::WriteAllText($out, $t, (New-Object System.Text.UTF8Encoding($false)))
  return $out
}

Write-Host ""
Write-Host "CLUSTER_NAME = $CLUSTER_NAME"
Write-Host "REGION       = $REGION"
Write-Host "K8S_VERSION  = $K8S_VERSION"
Write-Host "KARPENTER    = $KARPENTER_VERSION"
Write-Host "MY_IP        = $MY_IP"

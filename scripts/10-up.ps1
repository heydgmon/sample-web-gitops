# =============================================================
# EKS MSP Lab - 전체 구성 한 번에 생성
#   .\10-up.ps1          (확인 질문 후 진행)
#   .\10-up.ps1 -Yes     (질문 없이 진행)
#
# 멱등: 이미 있는 리소스는 건너뛰므로 중간에 실패해도 다시 실행하면 이어서 진행됨
# 순서: Karpenter IAM/SQS(CFN) → 클러스터 → access entry → 노드 SG 태그 → Karpenter
#       → AWS Load Balancer Controller → ArgoCD → 앱(04) → game-2048 IP 제한
# 소요: 클러스터를 새로 만들면 약 25~30분
# 로그: out\up-<시각>.log (계정 ID, IP 포함 / 옮기지 말 것)
#
# ※ 이 파일은 BOM 포함 UTF-8로 유지 (Windows PowerShell 5.1 한글 깨짐 방지)
# =============================================================
param([switch]$Yes)

# 5.1에서 Stop으로 두면 네이티브 명령(aws, kubectl)의 stderr가 예외가 됨 → 종료 코드로 직접 판단
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
Set-Location $PSScriptRoot

# ---- 버전 (README와 맞출 것) ----
$LBC_VERSION          = "3.6.2"     # aws-load-balancer-controller 차트/앱 버전
$ARGOCD_CHART_VERSION = "10.17.1"

# ---- 공통 함수 ----
function Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Check([string]$what) { if ($LASTEXITCODE -ne 0) { throw "실패: $what (exit $LASTEXITCODE)" } }
function Wait-Until([scriptblock]$Cond, [string]$What, [int]$TimeoutSec = 600, [int]$IntervalSec = 10) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    if (& $Cond) { Info "$What 완료 ($([int]$sw.Elapsed.TotalSeconds)s)"; return }
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "시간 초과: $What (${TimeoutSec}s)" }
    Start-Sleep $IntervalSec
  }
}
# 공인 IP가 바뀌었으면 API 허용 IP를 갱신하고 kubeconfig를 만든 뒤 접속될 때까지 대기
function Ensure-ApiAccess {
  $cidrs = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.publicAccessCidrs" --output text
  if (-not (($cidrs -split "\s+") -contains "$MY_IP/32")) {
    Info "API 허용 IP 갱신: [$cidrs] → $MY_IP/32 (몇 분 걸림)"
    eksctl utils set-public-access-cidrs --cluster $CLUSTER_NAME --region $REGION "$MY_IP/32" --approve; Check "set-public-access-cidrs"
  }
  aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION | Out-Null; Check "update-kubeconfig"
  Wait-Until { kubectl get --raw /readyz 2>$null | Out-Null; $LASTEXITCODE -eq 0 } "EKS API 접속" 300
}

New-Item -ItemType Directory -Force "$PSScriptRoot\out" | Out-Null
$log = "$PSScriptRoot\out\up-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Start-Transcript -Path $log | Out-Null
$total = [Diagnostics.Stopwatch]::StartNew()

try {
  . "$PSScriptRoot\00-env.ps1"
  if (-not $CLUSTER_NAME) { throw "00-env.ps1 변수가 비어 있음 (BOM 확인: README A-2)" }

  $LBC_POLICY_NAME     = "AWSLoadBalancerControllerIAMPolicy-$CLUSTER_NAME"
  $LBC_POLICY_ARN      = "arn:aws:iam::${ACCOUNT_ID}:policy/$LBC_POLICY_NAME"
  $KARPENTER_NODE_ROLE = "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-$CLUSTER_NAME"

  Write-Host ""
  Write-Host "생성 대상: 계정 $ACCOUNT_ID / $REGION / 클러스터 $CLUSTER_NAME / 내 IP $MY_IP" -ForegroundColor Yellow
  if (-not $Yes) {
    $a = Read-Host "위 계정에 EKS 실습 환경을 생성합니다 (요금 발생). 계속할까요? (y/N)"
    if ($a -ne "y") { Write-Host "취소함"; return }
  }

  # ---------------------------------------------------------
  Step "1/9 Karpenter IAM/SQS 스택 (Karpenter-$CLUSTER_NAME)"
  $st = aws cloudformation describe-stacks --stack-name "Karpenter-$CLUSTER_NAME" --region $REGION --query "Stacks[0].StackStatus" --output text 2>$null
  if ($LASTEXITCODE -eq 0 -and $st -in @("CREATE_COMPLETE", "UPDATE_COMPLETE")) {
    Info "있음 ($st), 건너뜀"
  } else {
    Info "없음 → 배포"
    Invoke-WebRequest "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v$KARPENTER_VERSION/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" -OutFile "$PSScriptRoot\out-karpenter-cfn.yaml" -UseBasicParsing
    aws cloudformation deploy --stack-name "Karpenter-$CLUSTER_NAME" --template-file "$PSScriptRoot\out-karpenter-cfn.yaml" --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "ClusterName=$CLUSTER_NAME" --region $REGION
    Check "Karpenter CFN 배포"
  }

  # ---------------------------------------------------------
  Step "2/9 EKS 클러스터 ($CLUSTER_NAME)"
  aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query cluster.status --output text 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Info "없음 → 생성 (15~20분)"
    eksctl create cluster -f (Render "$PSScriptRoot\01-cluster.yaml"); Check "eksctl create cluster"
  } else {
    Info "있음, 생성 건너뜀"
  }
  Ensure-ApiAccess
  $VPC_ID = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text; Check "VPC ID 조회"
  Info "VPC: $VPC_ID"
  $kpia = aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $REGION --namespace kube-system --service-account karpenter --query "associations[0].associationId" --output text
  if (-not $kpia -or $kpia -eq "None") { throw "kube-system/karpenter Pod Identity 없음 → README 트러블슈팅 'Pod Identity 스택만 ROLLBACK_COMPLETE' 참고" }

  # ---------------------------------------------------------
  Step "3/9 Karpenter 노드 조인 권한 (access entry)"
  $ae = aws eks list-access-entries --cluster-name $CLUSTER_NAME --region $REGION --query "accessEntries" --output text
  if (($ae -split "\s+") -contains $KARPENTER_NODE_ROLE) {
    Info "있음, 건너뜀"
  } else {
    aws eks create-access-entry --cluster-name $CLUSTER_NAME --region $REGION --principal-arn $KARPENTER_NODE_ROLE --type EC2_LINUX | Out-Null
    Check "create-access-entry"
  }

  # ---------------------------------------------------------
  Step "4/9 Karpenter 노드 SG에 클러스터 태그 (없으면 ALB 타깃 unhealthy)"
  $sg = aws ec2 describe-security-groups --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eksctl-$CLUSTER_NAME-cluster-ClusterSharedNodeSecurityGroup-*" --query "SecurityGroups[0].GroupId" --output text
  if (-not $sg -or $sg -eq "None") { throw "ClusterSharedNodeSecurityGroup을 찾지 못함" }
  aws ec2 create-tags --region $REGION --resources $sg --tags "Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=owned"; Check "SG 태그"
  Info "$sg 태그 적용"

  # ---------------------------------------------------------
  Step "5/9 Karpenter $KARPENTER_VERSION (Helm) + NodePool"
  aws iam get-role --role-name AWSServiceRoleForEC2Spot 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { aws iam create-service-linked-role --aws-service-name spot.amazonaws.com | Out-Null; Check "Spot 서비스 연결 역할" }
  helm registry logout public.ecr.aws 2>$null | Out-Null   # 로그인 안 돼 있으면 에러 → 무시
  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version $KARPENTER_VERSION --namespace $KARPENTER_NAMESPACE --set "settings.clusterName=$CLUSTER_NAME" --set "settings.interruptionQueue=$CLUSTER_NAME" --set controller.resources.requests.cpu=500m --set controller.resources.requests.memory=512Mi --set controller.resources.limits.cpu=1 --set controller.resources.limits.memory=1Gi --wait
  Check "Karpenter 설치"
  kubectl apply -f (Render "$PSScriptRoot\02-karpenter-nodepool.yaml"); Check "NodePool/EC2NodeClass"

  # ---------------------------------------------------------
  Step "6/9 AWS Load Balancer Controller $LBC_VERSION"
  aws iam get-policy --policy-arn $LBC_POLICY_ARN 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Info "IAM 정책 없음 → 생성"
    Invoke-WebRequest "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v$LBC_VERSION/docs/install/iam_policy.json" -OutFile "$PSScriptRoot\out\alb-iam-policy.json" -UseBasicParsing
    aws iam create-policy --policy-name $LBC_POLICY_NAME --policy-document "file://out/alb-iam-policy.json" | Out-Null; Check "LBC IAM 정책"
  } else { Info "IAM 정책 있음" }
  $lpia = aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $REGION --namespace kube-system --service-account aws-load-balancer-controller --query "associations[0].associationId" --output text
  if (-not $lpia -or $lpia -eq "None") {
    eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION --namespace kube-system --service-account-name aws-load-balancer-controller --role-name "$CLUSTER_NAME-alb-controller" --permission-policy-arns $LBC_POLICY_ARN
    Check "LBC Pod Identity (스택이 남아 AlreadyExists면 README '실패/보호된 스택 삭제')"
  } else { Info "Pod Identity 있음" }
  helm repo add eks https://aws.github.io/eks-charts --force-update | Out-Null
  helm repo update eks | Out-Null
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version $LBC_VERSION -n kube-system --set "clusterName=$CLUSTER_NAME" --set "region=$REGION" --set "vpcId=$VPC_ID" --set nodeSelector.role=system --set replicaCount=1 --wait
  Check "LBC 설치"

  # ---------------------------------------------------------
  Step "7/9 ArgoCD (차트 $ARGOCD_CHART_VERSION)"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update | Out-Null
  helm repo update argo | Out-Null
  helm upgrade --install argocd argo/argo-cd --version $ARGOCD_CHART_VERSION -n argocd --create-namespace -f "$PSScriptRoot\03-argocd-values.yaml" --wait
  Check "ArgoCD 설치"
  $pw = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>$null
  if ($LASTEXITCODE -eq 0 -and $pw) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pw)) | Set-Clipboard
    Info "ArgoCD 초기 비밀번호(ID admin)를 클립보드에 복사함 (화면/로그에는 출력하지 않음)"
  } else { Info "초기 비밀번호 Secret 없음 (이미 변경/삭제됨)" }
  Remove-Variable pw -ErrorAction SilentlyContinue

  # ---------------------------------------------------------
  Step "8/9 ArgoCD Application 배포 (04-argocd-apps.yaml)"
  kubectl apply -f "$PSScriptRoot\04-argocd-apps.yaml"; Check "Application 적용"

  # ---------------------------------------------------------
  Step "9/9 game-2048 ALB 주소 대기 + 내 IP로 접근 제한"
  $lbHost = $null
  if (Select-String -Path "$PSScriptRoot\04-argocd-apps.yaml" -Pattern "name: game-2048" -Quiet) {
    Wait-Until { kubectl get ingress game-2048 -n game-2048 -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>$null } "ALB 주소 할당" 900 15
    $lbHost = kubectl get ingress game-2048 -n game-2048 -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
    $nowIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()   # 공인 IP가 바뀌어 직전에 다시 조회
    kubectl -n game-2048 annotate ingress game-2048 --overwrite "alb.ingress.kubernetes.io/inbound-cidrs=$nowIp/32" | Out-Null
    Check "inbound-cidrs 적용"
    Info "inbound-cidrs = $nowIp/32"
    try {
      Wait-Until { (curl.exe -s -o NUL -m 5 -w "%{http_code}" "http://$lbHost") -eq "200" } "game-2048 HTTP 200 응답" 420 15
    } catch {
      Write-Warning "아직 응답 없음. DNS 전파/타깃 등록 대기 중이거나 공인 IP가 바뀌었을 수 있음 (README 트러블슈팅)"
    }
  } else { Info "04-argocd-apps.yaml에 game-2048 없음, 건너뜀" }

  # ---------------------------------------------------------
  Step "완료 ($([int]$total.Elapsed.TotalMinutes)분)"
  kubectl get nodes -L role,karpenter.sh/capacity-type
  kubectl get applications -n argocd
  if ($lbHost) { Write-Host ""; Write-Host "game-2048 : http://$lbHost" -ForegroundColor Green }
  Write-Host "ArgoCD    : kubectl -n argocd port-forward svc/argocd-server 8080:80  →  http://localhost:8080 (admin / 클립보드)" -ForegroundColor Green
}
catch {
  Write-Host ""
  Write-Host "중단됨: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "원인 확인 후 .\10-up.ps1 을 다시 실행하면 완료된 단계는 건너뜀" -ForegroundColor Red
}
finally {
  Stop-Transcript | Out-Null
  Write-Host "로그: $log" -ForegroundColor DarkGray
}

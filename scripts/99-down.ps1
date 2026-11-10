# =============================================================
# EKS MSP Lab - 클러스터 삭제 (다음 날 10-up.ps1로 다시 만들 수 있게 일부는 남김)
#   .\99-down.ps1        (클러스터 이름 입력으로 확인 후 진행)
#   .\99-down.ps1 -Yes   (확인 없이 진행)
#
# 지우는 것: ArgoCD 앱 → 로드밸런서(ALB/CLB) → Karpenter 노드 → Helm 릴리스
#            → eksctl 스택(클러스터, VPC, 노드그룹, Pod Identity 역할) → Launch Template
# 남기는 것: CFN Karpenter-<클러스터>(IAM/SQS/EventBridge), LBC IAM 정책,
#            CloudWatch 로그 그룹(7일 보관), GitHub 저장소
# 완전 정리(남긴 것까지)는 README '정리' 참고
# 소요: 약 20~25분 / 로그: out\down-<시각>.log
#
# ※ 이 파일은 BOM 포함 UTF-8로 유지 (Windows PowerShell 5.1 한글 깨짐 방지)
# =============================================================
param([switch]$Yes)

$ErrorActionPreference = "Continue"   # 네이티브 명령 stderr 예외 방지, 종료 코드로 판단
$ProgressPreference    = "SilentlyContinue"
Set-Location $PSScriptRoot

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
function Ensure-ApiAccess {
  $cidrs = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.publicAccessCidrs" --output text
  if (-not (($cidrs -split "\s+") -contains "$MY_IP/32")) {
    Info "API 허용 IP 갱신: [$cidrs] → $MY_IP/32 (몇 분 걸림)"
    eksctl utils set-public-access-cidrs --cluster $CLUSTER_NAME --region $REGION "$MY_IP/32" --approve; Check "set-public-access-cidrs"
  }
  aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION | Out-Null; Check "update-kubeconfig"
  Wait-Until { kubectl get --raw /readyz 2>$null | Out-Null; $LASTEXITCODE -eq 0 } "EKS API 접속" 300
}
# 클러스터 VPC 안에 남은 로드밸런서 (ALB/NLB + CLB). 남아 있으면 VPC 삭제가 막힘
function Get-VpcLbs {
  $a = aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerName" --output text
  $b = aws elb describe-load-balancers --region $REGION --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text
  ("$a $b" -replace "None", "").Trim()
}
# Karpenter가 띄운 EC2 (클러스터 VPC 안, running/pending)
function Get-KarpenterInstances {
  $r = aws ec2 describe-instances --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=karpenter.sh/nodepool" "Name=instance-state-name,Values=pending,running,stopping,shutting-down" --query "Reservations[].Instances[].InstanceId" --output text
  ("$r" -replace "None", "").Trim()
}
function Get-EksctlStacks {
  $r = aws cloudformation describe-stacks --region $REGION --query "Stacks[?starts_with(StackName,'eksctl-$CLUSTER_NAME-')].StackName" --output text
  @(("$r" -replace "None", "") -split "\s+" | Where-Object { $_ })
}

New-Item -ItemType Directory -Force "$PSScriptRoot\out" | Out-Null
$log = "$PSScriptRoot\out\down-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Start-Transcript -Path $log | Out-Null
$total = [Diagnostics.Stopwatch]::StartNew()

try {
  . "$PSScriptRoot\00-env.ps1"
  if (-not $CLUSTER_NAME) { throw "00-env.ps1 변수가 비어 있음 (BOM 확인: README A-2)" }

  Write-Host ""
  Write-Host "삭제 대상: 계정 $ACCOUNT_ID / $REGION / 클러스터 $CLUSTER_NAME 와 그 안의 모든 앱, 로드밸런서, 노드, VPC" -ForegroundColor Yellow
  Write-Host "남기는 것: CFN Karpenter-$CLUSTER_NAME, IAM 정책 AWSLoadBalancerControllerIAMPolicy-$CLUSTER_NAME, 로그 그룹" -ForegroundColor Yellow
  if (-not $Yes) {
    $a = Read-Host "되돌릴 수 없습니다. 진행하려면 클러스터 이름($CLUSTER_NAME)을 입력"
    if ($a -ne $CLUSTER_NAME) { Write-Host "취소함"; return }
  }

  aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query cluster.status --output text 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $VPC_ID = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text
    Info "VPC: $VPC_ID"
    Ensure-ApiAccess

    # -------------------------------------------------------
    Step "1/6 ArgoCD Application 삭제 (finalizer로 하위 리소스까지)"
    kubectl get crd applications.argoproj.io 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      kubectl delete application -n argocd --all --wait=false 2>$null | Out-Null
      Wait-Until { -not (kubectl get applications -n argocd -o name 2>$null) } "Application 삭제" 600
    } else { Info "ArgoCD 없음, 건너뜀" }

    # -------------------------------------------------------
    Step "2/6 로드밸런서 삭제 (Ingress, LoadBalancer Service)"
    kubectl delete ingress --all --all-namespaces --wait=false 2>$null | Out-Null
    $lbSvcs = kubectl get svc -A -o jsonpath="{range .items[?(@.spec.type=='LoadBalancer')]}{.metadata.namespace}/{.metadata.name}{'\n'}{end}" 2>$null
    foreach ($s in @($lbSvcs | Where-Object { $_ })) {
      $ns, $name = $s.Trim() -split "/"
      Info "Service 삭제: $ns/$name"
      kubectl delete svc $name -n $ns --wait=false | Out-Null
    }
    Wait-Until { -not (Get-VpcLbs) } "VPC 내 로드밸런서 삭제 (AWS 기준 확인)" 600 15

    # -------------------------------------------------------
    Step "3/6 Karpenter 노드 삭제"
    kubectl delete nodepool --all --wait=false 2>$null | Out-Null
    Wait-Until { (-not (kubectl get nodeclaims -o name 2>$null)) -and (-not (Get-KarpenterInstances)) } "NodeClaim/EC2 삭제" 600 15

    # -------------------------------------------------------
    Step "4/6 Helm 릴리스 제거"
    foreach ($r in @(@("argocd", "argocd"), @("aws-load-balancer-controller", "kube-system"), @("karpenter", $KARPENTER_NAMESPACE))) {
      helm status $r[0] -n $r[1] 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { helm uninstall $r[0] -n $r[1] | Out-Null; Check "helm uninstall $($r[0])"; Info "$($r[0]) 제거" }
      else { Info "$($r[0]) 없음" }
    }

    # -------------------------------------------------------
    Step "5/6 eksctl 스택 종료 보호 해제 → 클러스터 삭제 (15~20분)"
    foreach ($s in Get-EksctlStacks) {
      aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name $s --region $REGION | Out-Null
      Info "종료 보호 해제: $s"
    }
    eksctl delete cluster --name $CLUSTER_NAME --region $REGION --wait; Check "eksctl delete cluster"
  } else {
    Info "클러스터 $CLUSTER_NAME 없음 → 클러스터 단계 건너뛰고 잔여물만 정리"
  }

  # ---------------------------------------------------------
  Step "6/6 잔여물 정리"
  $lts = aws ec2 describe-launch-templates --region $REGION --filters "Name=tag:karpenter.k8s.aws/cluster,Values=$CLUSTER_NAME" --query "LaunchTemplates[].LaunchTemplateName" --output text
  foreach ($lt in @(("$lts" -replace "None", "") -split "\s+" | Where-Object { $_ })) {
    aws ec2 delete-launch-template --launch-template-name $lt --region $REGION | Out-Null
    Info "Launch Template 삭제: $lt"
  }
  # eksctl delete가 못 지운 스택 (Pod Identity 역할 스택 등). 남으면 내일 AlreadyExists 발생
  foreach ($s in Get-EksctlStacks) {
    Info "남은 스택 삭제: $s"
    aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name $s --region $REGION | Out-Null
    aws cloudformation delete-stack --stack-name $s --region $REGION
    aws cloudformation wait stack-delete-complete --stack-name $s --region $REGION
    if ($LASTEXITCODE -ne 0) { Write-Warning "스택 삭제 실패: $s (CloudFormation 콘솔에서 원인 확인)" }
  }

  # ---------------------------------------------------------
  Step "완료 ($([int]$total.Elapsed.TotalMinutes)분) - 남은 리소스 확인"
  $left = Get-EksctlStacks
  if ($left.Count -eq 0) { Info "eksctl 스택: 없음" } else { Write-Warning "eksctl 스택 남음: $($left -join ', ')" }
  $ec2 = aws ec2 describe-instances --region $REGION --filters "Name=tag:purpose,Values=msp-lab" "Name=instance-state-name,Values=pending,running" --query "Reservations[].Instances[].InstanceId" --output text
  if ("$ec2".Trim() -and "$ec2".Trim() -ne "None") { Write-Warning "실행 중 EC2 남음: $ec2" } else { Info "실행 중 EC2: 없음" }
  $kst = aws cloudformation describe-stacks --stack-name "Karpenter-$CLUSTER_NAME" --region $REGION --query "Stacks[0].StackStatus" --output text 2>$null
  Info "남겨둔 스택 Karpenter-${CLUSTER_NAME}: $kst"
  Write-Host ""
  Write-Host "내일 다시 만들기: .\10-up.ps1" -ForegroundColor Green
}
catch {
  Write-Host ""
  Write-Host "중단됨: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "원인 확인 후 .\99-down.ps1 을 다시 실행하면 이미 지워진 단계는 건너뜀" -ForegroundColor Red
}
finally {
  Stop-Transcript | Out-Null
  Write-Host "로그: $log" -ForegroundColor DarkGray
}

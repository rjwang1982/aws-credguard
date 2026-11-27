#!/bin/bash
# 只读盘点：每个 profile 的身份与权限（profile 列表取自 ~/.aws/config）
# 注意：aws-cred 输出未带 MFA 的 GetSessionToken 临时凭证，IAM 接口会被拒绝，
#       此时级别显示 UNKNOWN_NO_IAM_READ；权限请以控制台 IAM 凭证报告为准。
# 未缓存的 profile 每个会弹一次 Touch ID。
export AWS_MAX_ATTEMPTS=1 AWS_PAGER=""
O="--cli-connect-timeout 5 --cli-read-timeout 15 --output text"
one() {
  p="$1"
  r=$(aws configure get region --profile "$p" 2>/dev/null); r=${r:-us-east-1}
  arn=$(aws sts get-caller-identity --profile "$p" --region "$r" $O --query Arn 2>/dev/null)
  if [[ "$arn" != arn:* ]]; then printf "%s\t%s\tINVALID\t-\t-\n" "$p" "$r"; return; fi
  if [[ "$arn" == *":root" ]]; then printf "%s\t%s\t%s\tROOT\tROOT\n" "$p" "$r" "$arn"; return; fi
  u=${arn##*/}
  pol=$(aws iam list-attached-user-policies --user-name "$u" --profile "$p" --region "$r" $O --query 'AttachedPolicies[].PolicyName' 2>/dev/null | tr '\t' ',')
  inl=$(aws iam list-user-policies --user-name "$u" --profile "$p" --region "$r" $O --query 'PolicyNames' 2>/dev/null | tr '\t' ',')
  gp=""
  for g in $(aws iam list-groups-for-user --user-name "$u" --profile "$p" --region "$r" $O --query 'Groups[].GroupName' 2>/dev/null); do
    gp+="$g:[$(aws iam list-attached-group-policies --group-name "$g" --profile "$p" --region "$r" $O --query 'AttachedPolicies[].PolicyName' 2>/dev/null | tr '\t' ',')] "
  done
  all="$pol $inl $gp"
  lvl=OTHER
  [[ -z "${all// /}" ]] && lvl=UNKNOWN_NO_IAM_READ
  [[ "$all" == *ReadOnly* || "$all" == *ViewOnly* ]] && lvl=READONLY
  [[ "$all" == *PowerUser* ]] && lvl=POWERUSER
  [[ "$all" == *AdministratorAccess* ]] && lvl=ADMIN
  printf "%s\t%s\t%s\t%s\tattached=%s inline=%s groups=%s\n" "$p" "$r" "$arn" "$lvl" "$pol" "$inl" "$gp"
}
export -f one; export O
grep -E '^\[' ~/.aws/config | sed -E 's/^\[(profile )?//; s/\]$//' | xargs -P 8 -I{} bash -c 'one "$@"' _ {} > "$1.tmp"
sort "$1.tmp" > "$1"; rm -f "$1.tmp"; echo DONE >> "$1.done"

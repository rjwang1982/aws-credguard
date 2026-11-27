#!/bin/bash
# AWS CredGuard 安装：编译 aws-se，部署 aws-cred 与管理函数（不迁移密钥）
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "需要 Xcode Command Line Tools: xcode-select --install"; exit 1; }
mkdir -p ~/.aws/bin ~/.aws/vault/cache; chmod 700 ~/.aws/bin ~/.aws/vault ~/.aws/vault/cache
swiftc -O src/aws-se.swift -o ~/.aws/bin/aws-se
# 签名：默认 adhoc（-）。adhoc 每次编译签名都会变，钥匙串会再次弹密码；可用固定证书：
#   CREDGUARD_SIGN_ID="<证书名或SHA1>" ./install.sh   （查询：security find-identity -p codesigning -v）
codesign -f -s "${CREDGUARD_SIGN_ID:--}" ~/.aws/bin/aws-se
install -m 700 bin/aws-cred ~/.aws/bin/aws-cred
[ -f ~/.aws/aws_profile_manager.sh ] && cp -p ~/.aws/aws_profile_manager.sh ~/.aws/aws_profile_manager.sh.bak_$(date +%Y%m%d_%H%M%S)
install -m 600 shell/aws_profile_manager.sh ~/.aws/aws_profile_manager.sh
grep -q 'aws_profile_manager.sh' ~/.zshrc || echo 'source ~/.aws/aws_profile_manager.sh' >> ~/.zshrc
[ -f ~/.aws/vault/se-key.bin ] || ~/.aws/bin/aws-se init
echo "安装完成。新开终端后执行 aws-help；用 aws-add 添加 profile。"

#!/bin/bash
# ============================================================
# AWS Profile 快捷管理函数（Secure Enclave / Touch ID 版，2026-11-26）
# 密钥：~/.aws/vault/<name>.enc（SE 密钥加密，解密需 Touch ID）
# 凭证：config 中 credential_process = ~/.aws/bin/aws-cred <name>
# 用法: source ~/.aws/aws_profile_manager.sh
# ============================================================

AWS_CONF="$HOME/.aws/config"
AWS_VAULT_DIR="$HOME/.aws/vault"
AWS_SE="$HOME/.aws/bin/aws-se"
AWS_CRED_BIN="$HOME/.aws/bin/aws-cred"

# 内部：列出 config 中的 profile（不含 -src）
_aws_profiles() {
    grep -E '^\[(default|profile [^]]+)\]' "$AWS_CONF" | sed -E 's/^\[(profile )?//; s/\]$//' | grep -v -- '-src$'
}

# 内部：取 region
_aws_region() {
    local name="$1" hdr
    [ "$name" = "default" ] && hdr="[default]" || hdr="[profile $name]"
    awk -v h="$hdr" '$0==h{f=1;next} /^\[/{f=0} f && /^region/{sub(/^region *= */,"");print;exit}' "$AWS_CONF"
}

# 内部：从 config 删除某段
_aws_conf_drop() {
    local hdr="$1"
    python3 - "$AWS_CONF" "$hdr" <<'PY'
import sys
p,h=sys.argv[1],sys.argv[2]
out=[];skip=False
for l in open(p).read().split('\n'):
    if l.startswith('['): skip=(l.strip()==h)
    if not skip: out.append(l)
open(p,'w').write('\n'.join(out))
PY
}

# ============================================================
# aws-ls: 列出 profile（🔐=已加密存储）
# ============================================================
aws-ls() {
    echo "📋 AWS Profiles (🔐=Touch ID 加密存储):"
    _aws_profiles | while read -r p; do
        local mark="  "; [ -f "$AWS_VAULT_DIR/$p.enc" ] && mark="🔐"
        printf "  %s %-26s %s\n" "$mark" "$p" "$(_aws_region "$p")"
    done
}

# ============================================================
# aws-add <name> <access_key_id> [region]
# Secret Key 交互输入（不回显、不进 history）
# ============================================================
aws-add() {
    local name="$1" ak="$2" region="${3:-ap-southeast-1}" sk
    if [ -z "$name" ] || [ -z "$ak" ]; then
        echo "用法: aws-add <profile_name> <access_key_id> [region]"
        echo "示例: aws-add newclient AKIA... us-east-1   （随后提示输入 Secret Key）"
        return 1
    fi
    if _aws_profiles | grep -qx "$name" || [ -f "$AWS_VAULT_DIR/$name.enc" ]; then
        echo "❌ Profile '$name' 已存在，请先删除: aws-rm $name"; return 1
    fi
    printf "Secret Access Key: "; read -rs sk; echo
    [ -z "$sk" ] && { echo "❌ Secret Key 为空"; return 1; }

    # 写入前先验证密钥可用（不落盘）
    local arn
    arn=$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_REGION="$region" \
          AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
          aws sts get-caller-identity --query Arn --output text 2>/dev/null)
    if [[ "$arn" != arn:* ]]; then
        unset sk; echo "❌ 密钥验证失败（检查 AK/SK 和 region，中国区用 cn-north-1/cn-northwest-1）"; return 1
    fi

    if ! printf '%s %s' "$ak" "$sk" | "$AWS_SE" encrypt "$name"; then
        unset sk; echo "❌ 加密写入失败"; return 1
    fi
    unset sk
    printf "\n[profile %s]\nregion = %s\noutput = text\ncredential_process = %s %s\n" \
        "$name" "$region" "$AWS_CRED_BIN" "$name" >> "$AWS_CONF"
    echo "✅ 已添加: $name (region: $region)"
    echo "   身份: $arn"
    echo "   提醒: 请同步把 AK/SK 存入 SafeInCloud 作为备份"
}

# ============================================================
# aws-rm <name>: 删除 profile（加密文件 + 缓存 + config）
# ============================================================
aws-rm() {
    local name="$1"
    [ -z "$name" ] && { echo "用法: aws-rm <profile_name>"; return 1; }
    [ "$name" = "default" ] && { echo "⚠️  不能删除 default profile"; return 1; }
    printf "确认删除 '%s'？此操作不可恢复（需从 SafeInCloud 重新添加）[y/N] " "$name"
    local c; read -r c; [ "$c" = "y" ] || { echo "已取消"; return 1; }

    if [ -f "$AWS_VAULT_DIR/$name.enc" ]; then
        rm -P "$AWS_VAULT_DIR/$name.enc" && echo "✅ 已删除加密密钥: $name"
    else
        echo "⚠️  未找到加密密钥: $name"
    fi
    rm -f "$AWS_VAULT_DIR/cache/$name.json"
    rmdir "$AWS_VAULT_DIR/cache/$name.lock" 2>/dev/null
    if grep -q "^\[profile $name\]$" "$AWS_CONF"; then
        _aws_conf_drop "[profile $name]"; echo "✅ 已从 config 删除: $name"
    fi
    grep -q "^\[profile $name-src\]$" "$AWS_CONF" && _aws_conf_drop "[profile $name-src]"
    return 0
}

# ============================================================
# aws-show <name>: 查看配置（不显示密钥）
# ============================================================
aws-show() {
    local name="$1" hdr
    [ -z "$name" ] && { echo "用法: aws-show <profile_name>"; return 1; }
    [ "$name" = "default" ] && hdr="[default]" || hdr="[profile $name]"
    echo "📌 Profile: $name"
    echo "🔑 加密密钥: $([ -f "$AWS_VAULT_DIR/$name.enc" ] && echo 已存储 || echo 未存储)"
    local cf="$AWS_VAULT_DIR/cache/$name.json"
    if [ -s "$cf" ]; then
        echo "⏱  临时凭证缓存到期: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("Expiration","-"))' "$cf" 2>/dev/null)"
    fi
    echo "⚙️  Config:"
    awk -v h="$hdr" '$0==h{f=1;next} /^\[/{f=0} f && NF{print "   "$0}' "$AWS_CONF"
}

# ============================================================
# aws-region <name> <new_region>
# ============================================================
aws-region() {
    local name="$1" new_region="$2"
    if [ -z "$name" ] || [ -z "$new_region" ]; then
        echo "用法: aws-region <profile_name> <new_region>"; return 1
    fi
    if [ "$name" = "default" ]; then
        sed -i '' "/^\[default\]$/,/^\[/{s/^region = .*/region = $new_region/;}" "$AWS_CONF"
    else
        sed -i '' "/^\[profile $name\]$/,/^\[/{s/^region = .*/region = $new_region/;}" "$AWS_CONF"
    fi
    rm -f "$AWS_VAULT_DIR/cache/$name.json"   # region 变了，旧临时凭证作废
    echo "✅ $name 的 region 已改为: $new_region"
}

# ============================================================
# aws-test [name|--all]: 验证（首次/过期会弹 Touch ID）
# ============================================================
aws-test() {
    if [ "$1" = "--all" ]; then
        echo "🔍 批量测试（未缓存的 profile 每个弹一次 Touch ID）..."
        _aws_profiles | while read -r p; do
            local arn; arn=$(aws sts get-caller-identity --profile "$p" --query Arn --output text 2>/dev/null </dev/null)
            if [[ "$arn" == arn:* ]]; then printf "  ✅ %-26s %s\n" "$p" "$arn"
            else printf "  ❌ %-26s %s\n" "$p" "invalid"; fi
        done
    else
        local name="${1:-default}"
        echo "🔍 测试: $name (region: $(_aws_region "$name"))"
        aws sts get-caller-identity --profile "$name" --output text
    fi
}

# ============================================================
# aws-use <name> [命令...]: 用该 profile 执行命令；不带命令则设为当前 shell 默认
# ============================================================
aws-use() {
    [ -z "$1" ] && { echo "用法: aws-use <profile> [command...]"; return 1; }
    local name="$1"; shift
    if [ $# -eq 0 ]; then
        export AWS_PROFILE="$name"; echo "✅ 当前 shell 已切换到: $name（unset AWS_PROFILE 恢复）"
    else
        AWS_PROFILE="$name" "$@"
    fi
}

# ============================================================
# aws-lock: 清除所有临时凭证缓存（下次调用重新 Touch ID）
# ============================================================
aws-lock() {
    rm -f "$AWS_VAULT_DIR"/cache/*.json && echo "🔒 已清除临时凭证缓存"
}

# ============================================================
# 帮助
# ============================================================
aws-help() {
    cat << 'EOF'
AWS Profile 管理（Touch ID 加密版）
  aws-ls                         列出 profile（🔐=加密存储）
  aws-add <name> <ak> [region]   添加（SK 交互输入，先验证再加密）
  aws-rm <name>                  删除（加密密钥 + 缓存 + config，需确认）
  aws-show <name>                查看配置与缓存到期时间（不显示密钥）
  aws-region <name> <region>     修改 region
  aws-test [name|--all]          验证
  aws-use <name> [cmd...]        用该 profile 执行命令 / 设为当前 shell 默认
  aws-lock                       清除临时凭证缓存，强制下次 Touch ID
注意：增删 Mac 指纹会使 SE 密钥失效，需从 SafeInCloud 恢复后重新 aws-add
EOF
}

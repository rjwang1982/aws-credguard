# AWS CredGuard

**Keep AWS access keys off disk in plaintext on macOS. Every new use requires Touch ID; tools only ever receive 1-hour STS credentials.**

在 macOS 上把 AWS 长期密钥（AKSK）交给 **Secure Enclave** 加密，每次启用都要按 **Touch ID**，交给工具的只有 **1 小时有效的 STS 临时凭证**。`--profile` 用法不变，AWS CLI、SDK、Terraform、MCP Server 和 AI 编码智能体（如 Kiro）都不用改。

> 图文版（含架构图和时序图）：https://rjwang1982.github.io/aws-credguard/ （源文件 [`docs/AWS_CredGuard.html`](docs/AWS_CredGuard.html)）

---

## 为什么需要

AWS CLI 默认把长期 AKSK 明文写在 `~/.aws/credentials`。一个恶意 npm/pip 包、一个浏览器插件、一次云盘同步，就能把所有账号的密钥一起带走。本地跑的 AI 智能体越多，这个文件被读到的机会就越大。

| 风险 | 默认做法 | CredGuard |
|---|---|---|
| 明文存储 | `credentials` 里存着全部 AKSK | 只有 Secure Enclave 加密的密文 |
| 文件被读走 | 读一个文件就能拿走全部密钥 | 只能拿到密文，私钥在芯片里导不出来 |
| 同步和备份 | 明文被带走 | 带走的是密文，离开本机芯片无法解密 |
| 智能体静默使用 | 随时可用，本人不知情 | 每个 profile 每小时首次使用时弹 Touch ID |
| 长期密钥外泄 | 工具直接拿到长期 AK | 工具只拿到 1 小时有效的临时凭证 |

## 工作原理

```
aws CLI / SDK / Terraform / MCP / Kiro
        │  --profile prod-a
        ▼
~/.aws/config
  [profile prod-a]
  region = us-east-1
  credential_process = ~/.aws/bin/aws-cred prod-a
        │
        ▼
aws-cred
  ├─ 缓存有效（剩余 > 5 分钟）→ 直接返回
  ├─ 加锁：并发调用排队，只弹一次指纹
  ├─ aws-se decrypt prod-a ──► Touch ID ──► Secure Enclave
  ├─ 在内存中调用 STS GetSessionToken（1 小时，按 profile 的 region）
  └─ 写缓存 ~/.aws/vault/cache/prod-a.json（600），输出 JSON
```

| 组件 | 作用 |
|---|---|
| `src/aws-se.swift` | 在 Secure Enclave 里生成 P-256 密钥；用 ECIES（ECDH + HKDF-SHA256 + AES-256-GCM）加密和解密 AKSK。解密时必须按 Touch ID |
| `bin/aws-cred` | 供 `credential_process` 调用：解密 → 换取临时凭证 → 缓存 |
| `shell/aws_profile_manager.sh` | `aws-ls / add / rm / show / region / test / use / lock` |
| `scripts/audit_permissions.sh` | 只读盘点每个 profile 的 IAM 权限 |

Secure Enclave 密钥的访问控制是 `privateKeyUsage + biometryCurrentSet`，并设为 `WhenUnlockedThisDeviceOnly`：只能在本机、屏幕解锁时使用，绑定当前录入的指纹。

## 要求

- macOS，Apple Silicon（T2 芯片的 Intel Mac 推测也可用，未测试）；`install.sh` 尚未在全新机器上完整验证，欢迎反馈
- 已录入 Touch ID
- Xcode Command Line Tools（`xcode-select --install`）
- AWS CLI v2
- zsh

## 安装

```bash
git clone https://github.com/rjwang1982/aws-credguard.git
cd aws-credguard
./install.sh
source ~/.zshrc
aws-help
```

`install.sh` 做的事：
1. 编译 `aws-se`，放到 `~/.aws/bin/`。
2. 部署 `aws-cred` 和管理函数。
3. 在 `~/.zshrc` 里加一行 `source`。
4. 初始化 Secure Enclave 密钥。

它不会读取或修改你现有的 `credentials`。

## 使用

```bash
# 添加（Secret Key 交互输入，不回显、不进 history；先验证 STS，再加密）
aws-add prod-a AKIA................ us-east-1

# 原有用法不变；首次弹 Touch ID，1 小时内不再弹
aws sts get-caller-identity --profile prod-a

aws-ls                      # 列出 profile（🔐=加密存储）
aws-show prod-a             # 配置和缓存到期时间（不显示密钥）
aws-use prod-a aws s3 ls    # 用该 profile 执行一条命令
aws-lock                    # 清空缓存，下次重新按指纹
aws-rm prod-a               # 删除（需确认）
```

### 从现有 `~/.aws/credentials` 迁移

1. **先把 AKSK 备份到离线的密码管理器。** Secure Enclave 密钥失效后，只能靠这份备份恢复。
2. 对每个 profile 执行 `aws-add <name> <AK> <region>`，并删除 `credentials` 里对应的段。AWS CLI 会优先读 `credentials`，不删的话不会走 Touch ID。
3. 验收：
   ```bash
   grep -rlE 'AKIA[0-9A-Z]{16}' ~/.aws | grep -v /vault/ || echo "无明文"
   ```

> ⚠️ 不要在 shell 里设置全局 `AWS_REGION`。它会覆盖 profile 自己的 region，导致中国区账号访问海外 STS 地址，报 `InvalidClientTokenId`。

## 安全边界

**防得住**
- 恶意包、插件扫描 `~/.aws`
- 云盘同步、备份、磁盘被拷走
- 智能体在你不知情时启用新的 profile
- 工具在日志或报错里打印出长期 AK

**防不住**
- 按过指纹后 1 小时内，以你身份运行的进程能读取缓存的临时凭证
- 智能体被提示词注入后，在已授权窗口内滥用权限。这要靠 IAM 最小权限控制，可以先用 `scripts/audit_permissions.sh` 盘点
- root 密钥换不了 STS 临时凭证，`aws-cred` 会直接输出长期密钥（不落盘）。建议删除 root 的 Access Key

## 故障与恢复

| 现象 | 处理 |
|---|---|
| `Error when retrieving credentials from custom-process` | `aws-lock` 后重试；或执行 `bash -x ~/.aws/bin/aws-cred <name>` 查看卡在哪一步 |
| `InvalidClientTokenId` | 检查 `env \| grep AWS_REGION`；用 `aws-test <name>` 验证 |
| 增删指纹后全部无法解密 | Secure Enclave 密钥已失效：`mv ~/.aws/vault ~/.aws/vault.old && ./install.sh`，再从离线备份用 `aws-add` 恢复 |
| 换了新 Mac | Secure Enclave 密钥不能迁移：同上，在新机器上重建 |
| 智能体卡住 | 屏幕已锁定，或指纹窗口没人处理 |

## 与其他方案的比较

| 方案 | 不存明文 | 指纹 | 免费 | 说明 |
|---|---|---|---|---|
| `~/.aws/credentials` | ✗ | ✗ | ✓ | 默认做法 |
| aws-vault + Keychain | ✓ | ✗（输密码） | ✓ | 可以；智能体调用时要输入钥匙串密码 |
| aws-vault + 1Password | ✓ | ✓ | ✗ | 需要订阅 |
| IAM Identity Center（SSO） | ✓ | ✓（Passkey） | ✓ | 最佳，但需要每个账号都配置 |
| **CredGuard** | ✓ | ✓ | ✓ | 只支持 macOS |

## 作者

**RJ Wang**

- GitHub：[@rjwang1982](https://github.com/rjwang1982)
- Email：renjun.wang@vstecs.com

问题和建议欢迎提 [Issue](https://github.com/rjwang1982/aws-credguard/issues)。

## License

MIT。本项目不是 AWS 官方工具，使用风险自负。

# 维护与发布

- 项目名称：macOS AI 额度菜单栏（`QuotaBar`）
- 仓库地址：`https://github.com/hcmango/macos-quota-menubar`
- 工程名 / 应用名：`QuotaBar`（`QuotaBar.app`）
- Bundle ID：`com.hcmango.QuotaBar`
- 维护者：[hcmango](https://github.com/hcmango)

## 日常维护

日常功能开发与修复在 `main` 分支进行，验证通过后推送至 `origin/main`。提交按功能或修复拆分，采用 Conventional Commits，提交说明使用中文。

普通改动先记入 [CHANGELOG.md](CHANGELOG.md) 的「未发布」小节；发版时同步更新 `script/build_and_run.sh` 和 `script/package_dmg.sh` 中的 `VERSION`、[README.md](README.md) 中的产物名称和 [CHANGELOG.md](CHANGELOG.md)，并打上对应版本 tag（如 `v1.0.0`）。

## 构建与自动化验证

在仓库根目录执行：

```bash
swift test
swift build -c release
bash -n script/build_and_run.sh
bash -n script/package_dmg.sh
./script/build_and_run.sh --verify
```

`--verify` 会重启 `dist/QuotaBar.app` 并确认进程已启动；菜单栏布局、点击响应、抽屉动画与深浅色系统外观需在桌面实际目视检查。

自动化测试覆盖：

- Codex 额度窗口映射、app-server 初始化顺序、分段响应、提前退出与启动/查询阶段超时识别。
- Grok 当前账号缓存隔离、登录状态、schema 2 / 3 兼容、过期时间与试用额度。
- Antigravity CLI (`agy`) 用量与 `AI Credits` JSON 解析、未登录中断、超时与可执行文件发现。
- 单独安装、任意组合安装、均未安装及安装状态变化时的按需拉取与显示。
- 单个数据源超时或报错时，其余数据源仍能独立更新。
- 今日预算结转、超用负数、本机零点增量、最多七份封顶、颜色阈值、重置卡 72 小时临期与偏好持久化。

## 界面验收清单

| 场景 | 预期结果 |
| :--- | :--- |
| 三个工具均已安装 | 顶栏依次并排展示对应图标与指标；左键展开 `320pt` 原生 `NSPopover` 面板，各区域清晰分隔 |
| 仅安装其中部分工具 | 仅查询并显示已安装的应用 |
| 均未安装 | 自动隐藏状态栏项 |
| 右键菜单 | 支持「立即刷新」、切换「进度条 / 双行极简」并持久化、「退出」 |
| 有周额度及重置时间 | 进度条模式下主数值为今日预算 `D`、下方显示周剩余进度条；双行极简模式显示 `D` / `W` |
| Codex 重置卡 | 默认折叠为单行摘要，点击平滑展开明细；距到期不足 72 小时标红 |
| 今日预算颜色阈值 | `> 50%` 绿色，`20%～50%` 琥珀橙（顶栏文字跟随系统前景色），`< 20%` 或负数标红 |
| 周剩余 / `5H` 颜色阈值 | `> 50%` 绿色，`21%～50%` 琥珀橙，`≤ 20%` 标红 |
| Grok 试用额度 / 缓存过期 | 试用额度不推算日预算；过期或未登录时显示 `--` 并给出明确提示 |
| Antigravity (`agy`) | 面板并排展示 Gemini 与 Claude / GPT 双池的 `5H` 与周额度，头部显示 `AI Credits` |
| 面板展开交互 | 点击外部区域或按 `Esc` 收起；展开期间每 30 秒刷新倒计时与相对更新时间 |
| 浅色 / 深色菜单栏 | 默认文字与进度条轨道跟随系统前景色，图标与状态色清晰可辨 |

## 构建本机自用 DMG

```bash
./script/package_dmg.sh
```

当前输出：

```text
dist/QuotaBar.app
dist/QuotaBar-1.0.0.dmg
```

构建脚本会使用 release 模式编译并执行 ad-hoc 签名，同时把 SwiftPM 资源包 `QuotaBar_QuotaBar.bundle` 复制到 `.app/Contents/Resources/`。检查应用包时确认以下三个图标均存在：

```text
Contents/Resources/QuotaBar_QuotaBar.bundle/Contents/Resources/CodexProvider.png
Contents/Resources/QuotaBar_QuotaBar.bundle/Contents/Resources/GrokProvider.icns
Contents/Resources/QuotaBar_QuotaBar.bundle/Contents/Resources/AgyProvider.png
```

安装或升级时，先从菜单栏退出旧版，再将完整 `QuotaBar.app` 复制到 `/Applications` 并打开，不要只替换内部二进制。

## 对外分发签名与公证

本仓库默认提供源码由用户本机构建。ad-hoc 签名的 DMG 仅适合本机自用；若要向其他 macOS 用户直接分发 `.dmg`，需完成：

1. 使用 Apple Developer ID Application 证书对 `.app` 签名并开启 hardened runtime；
2. 使用 Apple Developer ID 对 `.dmg` 签名；
3. 提交 Apple notarization 并执行 `xcrun stapler staple`；
4. 使用 `spctl` 验证 Gatekeeper 通过，并在干净的 macOS 环境完成启动与界面验收。

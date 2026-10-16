# Clio 开发说明

## 本地构建

需要 Apple Silicon Mac 和 Apple Command Line Tools。构建脚本直接调用 Swift 编译器，生成应用包及原生 CodexHelper，并将辅助程序资源打包至应用内。

```bash
git clone https://github.com/UreMySunshine/clio.git
cd clio
bash Scripts/build.sh
```

构建产物为 `build/Clio.app`。`Package.swift` 提供 SwiftPM 项目配置；仅安装 Command Line Tools 时，清单编译可能因工具链环境失败，优先使用构建脚本。脚本会在当前 SDK 需要 SwiftUI 宏插件、但工具链未提供该插件时选择可用的旧 SDK。

若默认编译缓存目录不可写，可将缓存设在项目内：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
SWIFT_MODULECACHE_PATH="$PWD/build/ModuleCache" \
bash Scripts/build.sh
```

## 打包与签名

```bash
bash Scripts/package.sh
```

安装包为 `build/Clio-<版本>.dmg`，版本取自 `Resources/Info.plist`。默认使用临时签名，不包含 Apple 开发者公证。

使用 Apple Developer Program 账号进行分发签名与公证：

```bash
export CLIO_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
xcrun notarytool store-credentials clio --apple-id <邮箱> --team-id <TEAMID> --password <应用专用密码>
export CLIO_NOTARY_PROFILE=clio
bash Scripts/package.sh
```

`CLIO_SIGN_IDENTITY` 指定分发签名身份，`CLIO_NOTARY_PROFILE` 指定公证凭据。构建脚本签名应用及辅助程序，打包脚本提交安装包公证并装订票据。

## 回归测试

| 命令 | 验证范围 |
| --- | --- |
| `bash Scripts/test-usage-periods.sh` | 自然日周期和合并统计 |
| `bash Scripts/test-refresh.sh` | 刷新请求合并、统计缓存失效、额度重置及日志变更 |
| `bash Scripts/test-usage.sh` | 历史每日记录恢复、日志读取、计时补全、休眠扣除、双来源额度冲突、窗口重置、用量聚合及里程碑 |
| `bash Scripts/test-codex-usage.sh` | Codex 额度与重置次数、登录状态、只读协议及超时 |
| `bash Scripts/test-quota-ring.sh` | 菜单栏额度比例 |
| `bash Scripts/test-menubar.sh` | 菜单栏资源与截图 |
| `bash Scripts/test-ccusage-alignment.sh` | 日志去重、累计差值及周一边界 |
| `bash Scripts/test-codex-helper.sh` | 辅助服务安装、修复、升级、移除与回滚 |
| `bash Scripts/test-codex-helper-state.sh` | 辅助服务操作入口的状态判断 |

CodexHelper 测试使用临时文件与随机本机端口，不修改系统安装实例。

`bash Scripts/test-codex-usage.sh --live` 额外使用本机 Codex 的现有登录状态验证只读额度查询。

## 截图与数据检查

```bash
build/Clio.app/Contents/MacOS/Clio --dump
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots --sample-only -usageScope combined
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/claude --sample-only -usageScope claudeCode
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/codex --sample-only -usageScope codex
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/menubar --menubar-only
```

常规截图模式读取本机数据并检测辅助服务状态；`--sample-only` 使用内置示例数据，跳过数据刷新和服务检测。`sample-light.png`、`sample-dark.png` 为示例主面板，`panel-light.png`、`panel-dark.png` 为当前数据主面板。设置截图包含完整内容，不受实际窗口高度限制。离屏截图采用背景填充，不能体现实时桌面上的玻璃折射效果。

README 主面板使用示例图；设置使用常规模式生成的图片，以保持服务状态和按钮一致。使用应用包内可执行文件生成图片，可读取随包提供的图标。

## CodexHelper 版本与安装资源

辅助程序的独立版本定义在 `Tools/CodexHelper/Info.plist` 的 `CFBundleVersion`，使用整数。需要发布辅助程序更新时递增该值；仅修改 Clio 界面、安装脚本或重新构建时保留该值。

更新判断比较已安装与内置辅助程序版本，仅内置版本更高时提示更新。可识别的旧式服务保留迁移入口。文件摘要、文件权限及应用签名用于识别安装实例和验证完整性，不用于判断新版本。

安装涉及 Codex 用户目录中的 `.env`、系统 `hosts` 的受管理区块，以及 `local.codex.backend-relay` 后台服务。原生辅助程序安装在 `/Library/Application Support/CodexBackendRelay/CodexHelper.app`，仅监听本机 IPv4、IPv6 地址的 443 端口。系统 Python 用于安装、检测及移除，常驻转发由原生程序执行。

安装记录和备份位于服务目录。`helper-build.json` 保存文件摘要；安装失败时恢复本次变更，移除时保留用户后来修改的配置。Clio 支持目录中的 `codex-helper-result.txt` 保存最近一次操作结果。

## 统计与更新边界

用量解析按本机 ccusage 20.0.26 的源码核对：Claude Code 按消息与请求去重，Codex 优先使用请求增量，缺失时读取累计量的非负差值。统计仅包含现存本地日志。

输出速度参考 [CC Switch 的会话日志估算口径](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/4-proxy/4.4-usage.md)，显示为 `≈ xx tok/s`，不足每秒 1 Token 时保留两位有效数字，其他速度显示整数。按所选时段内有效请求的输出 Token 总和除以耗时总和汇总，包含首字等待，并扣除系统电源记录中与请求重叠的休眠区间。仅纳入输出至少 200 Token、清醒耗时 1 秒至 1 小时的记录。它表示历史请求的平均输出速度；日志没有完整计时或历史明细已丢失时显示 `—`。

macOS 电源历史通过 `pmset -g log` 读取，解析已完成的 Sleep 区间并合并重叠记录。历史在进程内共享缓存；普通刷新不启动子进程，系统清醒运行时间与墙上时钟的差值变化超过 1 秒时重新读取。休眠历史变化会重建两个 reader 的计时并使统计缓存失效，Token 与请求身份不变。系统历史只覆盖其实际保留的记录，且时间精度为秒；未保留的历史休眠无法校正。CC Switch 目前通过丢弃超过 1 小时的时间戳差过滤疑似休眠，我们在应用这个上限前先扣除可确认的休眠。

Claude Code 沿首个回复块的父链找到请求起点，跳过 attachment，并等到完整回复才计时。同 Token 总量的后续块仅更新耗时，保留原时间戳、模型、会话和去重身份，避免跨午夜补全计时造成每日记录重复。Codex 以用户消息、turn context 或工具结果作为请求边界，优先使用用量匹配的 `token_usage_record` 作为终点；用量在工具结果同批写入时退回最后一条模型输出，避免将工具执行时间计入。下一次请求保留工具结果或响应实际结束的时间作为起点，延迟写入的用量通知不会将起点后移。零 Token 快照可以更新额度和累计基线，但不结算或重置请求计时。重复日志可补全缺失计时，并使统计缓存失效，Token 总量和请求身份保持不变。计时状态按日志文件隔离，保留至下次增量刷新，重建日志时清空。

速度在「模型明细」右侧以独立一列展示，与模型名、Token、费用保持同一行，随日期范围和工具选择更新；悬停显示估算口径与有效样本数。同一模型跨工具合并时，仍按输出总量除以耗时总和计算。`--dump` 同时输出整体和各模型的速度与有效样本数。

自动更新校验 GitHub 提供的文件摘要、应用标识和版本号。未使用开发者签名的分发包，其来源可信度依赖发布仓库。

## 日志扫描性能

每轮刷新先为所有日志根目录各读取一次文件元数据，再用同一份快照检查删除、截断、替换和压缩归档变动，并从上次完整行的字节偏移继续读取。未压缩日志使用 256 KiB 缓冲区，只有跨块的单行才额外保留；半行留待下次追加，暂时不可读的文件保留偏移后重试。压缩归档仍在整份解码验证成功后才输出记录。重建时所有根目录统一重置，避免活跃文件与归档副本重复累计。

Codex 参考 [CC Switch 的行头分类方式](https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/services/session_usage_codex.rs)，从大记录的前 1 KB 读取事件类型与计时字段，跳过无关事件的大段正文。响应仅取计时需要的时间、类型和角色；字段不在行头、使用转义或记录包含模型字段时，回退完整 JSON 解析。用量、额度和请求开始/中断事件仍通过原有解析流程处理。字节标记筛选优先匹配响应，减少反复搜索完整工具输出。

性能对比使用固定日志快照、新建 reader 实例测全量扫描，再测无变动的增量刷新；不计入价格或额度联网查询。验证需逐条比对 Token 明细、模型、会话身份、时间戳、去重键、请求耗时和额度快照，仅比较总 Token 不足以验证计时与归属。

2026-10-15 本机固定快照约 1.53 GB，包含 50,348 条用量记录：全量日志扫描约 13.3 秒降至 5.9 秒，无变动刷新约 20 毫秒降至 16 毫秒；优化后峰值内存约 400 MB。用量与计时字段、额度快照逐项对比一致。

# Codex 审查合并检查

解析器接受 Codex GitHub App 发布的 `codex-review-state:v1` 汇总。代码审查必须明确完成，完整提交 SHA 必须等于 PR 最新提交，两项问题标志必须均为 `false`。已启动的安全审查也必须满足相同条件。

机器人账号、App 标识和最后编辑者都必须匹配。评论缺失、点赞、旧提交、未知字段结构、失败、额度不足及无法解析的返回均不通过。已有问题即使被标为解决，也需要一次无问题的重新审查。

适配层通过 REST 分页读取本 PR 评论，再用 GraphQL 获取编辑者；两次读取的评论标识、正文和更新时间必须一致，否则拒绝该次评估。

离线测试：`node --test .github/codex-gate/*.test.cjs`。测试中的无问题结果为合成数据；线上完成信号需要独立验证。

## 发布者与分支保护

main 的必需检查为 `Codex Review App / current-head`，发布者绑定 GitHub App `clio-codex-review-gate`（App ID `5340137`）。分支保护要求通过 PR 合并、分支为最新状态，并对管理员执行检查要求；禁止强制推送和删除。

检查由独立的 [codex-review-gate 服务](https://github.com/UreMySunshine/codex-review-gate)发布。服务仅读取 PR 元数据和可信审查结果，不执行 PR 中的代码。此目录的解析器及测试用于协议验证，不负责发布必需检查。

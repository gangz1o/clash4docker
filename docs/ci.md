# CI 检查

本项目的 Pull Request CI 是只读的分层校验，合并门禁使用唯一稳定检查名：`CI Gate`。

## 检查层次

- **Shell tests**：运行 `tests/test_mode.sh` 和 `tests/test_reload.sh`，覆盖启动配置和订阅热加载行为。
- **AMD64 runtime smoke**：构建并启动 `linux/amd64` 镜像，使用仓库内非敏感 fixture 检查容器健康状态、`/version`、`/ui/`，以及调用方安全路径和内置 `/app/ui` 是否同时保留。
- **Platform builds**：无发布地构建 `linux/amd64`、`linux/arm64` 和 `linux/arm/v7`。
- **CI Gate**：汇总上述层的结果。它是唯一需要加入分支保护的状态检查；其他 job 名称用于定位失败原因。

## 文档-only 变更

workflow 始终触发，不使用会让 required check 永久 pending 的路径过滤。变更分类器把仅包含 Markdown 文件或 `docs/**` 的变更视为文档-only：Shell tests 仍运行，AMD64 smoke 和三平台构建可跳过，`CI Gate` 仍必须以成功等终态结束。包含任何其他路径时按 runtime 变更处理。新提交会取消同一 Pull Request 的旧运行。

## Pull Request 安全边界

Pull Request workflow 明确使用只读仓库权限，checkout 不保留写入凭据，不读取 Docker Hub 或生产环境 secrets，也不执行镜像推送。来自 fork 的代码按同一边界验证；GitHub 可能要求维护者先批准运行，但批准不应授予发布权限。

发布仍只由 `.github/workflows/docker-build.yml` 负责。核对发布边界时，应确认该文件是唯一包含 `docker/login-action`、`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` 和 `push: true` 的 workflow，并继续发布三种目标架构。CI workflow 必须保持无 Docker Hub 登录和无推送步骤。

## 配置 master 合并门禁

维护者需要在 GitHub 仓库设置中完成以下配置：

1. 打开 **Settings -> Rules -> Rulesets**（旧版界面可使用 **Settings -> Branches**），针对 `master` 新建或编辑规则。
2. 启用 **Require a pull request before merging**，并要求 **code-owner review**；启用 **Dismiss stale pull request approvals when new commits are pushed**。
3. 启用 **Require status checks to pass before merging**，等待本分支首次成功运行后，选择来源为 **GitHub Actions** 的精确检查名 `CI Gate`。

不要选择相似的 worker job，也不要依赖模糊匹配。重命名 workflow 或 job（尤其是 `CI Gate`）会改变状态检查名并使既有规则失效，需要重新选择精确检查。

`.github/workflows/**` 已由 `.github/CODEOWNERS` 指定仓库 owner `@gangz1o`。因此 workflow 改动需要 `@gangz1o` 的 code-owner approval，即使该 workflow 自身报告成功也不能绕过评审。

分支规则是 GitHub 仓库设置，不由本文件自动声明。若当前账号没有 administration 权限，不能完成上述设置时，请将未完成的 master 规则配置交给拥有仓库管理权限的维护者，并在合并前确认 `CI Gate` 已显示为 required。

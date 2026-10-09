# sing-box Alpine NAT Manager

非官方 Alpine 管理工具设计与实现。sing-box 由 GitHub Actions 从固定的上游 `v1.14.2` 源码编译；NAT 主机只下载、校验和运行，不安装 Go，也不在本机编译。

本项目面向 Alpine、低内存 NAT 场景。**64 MiB 实机的长期稳定性未经验证**，配置通过校验或 CI 启动不代表已经证明适用于所有 64 MiB 实例。目标服务需由用户自行配置内部到外部端口的映射。

## 版本与产物

发布流水线只接受 sing-box `v1.14.2`，并校验上游标签精确指向提交 `af6e64c3b69e6132ebaee0e1a3d24e93903f6709`。该标签在 GitHub 上标记为 immutable release。[上游发布记录](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2)。每次项目发布为 `amd64`、`arm64`、`386`、`armv7` 生成静态 Linux 二进制压缩包和 SHA-256。更新版本必须先更新版本锁、上游提交、工具链和验收，再发新版本；禁止追随 `latest`。

## 目标管理功能

管理器运行一个 sing-box 进程和多个入口，可创建、编辑名称/端口、删除 SS2022、VLESS Reality、Hysteria2 节点，逐节点导出 Nikki/Mihomo YAML，轮换所选节点凭据，编辑原始 JSON，恢复配置备份，并管理 OpenRC 服务和手动更新二进制。服务启停影响所有入口。SS2022 首版仅 TCP；Reality 使用 TCP；Hysteria2 使用 UDP。端口只指内部监听端口，外部地址和端口必须由用户填入客户端配置。更改配置前先检查、原子替换，并在服务启动/重启失败时回滚。

## Alpine 安装

在实例上预先安装 `curl`、`jq`、`openssl`、`util-linux`（提供 `flock`）、`coreutils`（提供 `sha256sum`）、`iproute2`（提供 `ss`）、`xxd`；此项目不会在低内存主机上安装 Go 或编译 sing-box。先从 GitHub Releases 下载与 CPU 架构匹配的压缩包，再运行包内 `install.sh`。脚本下载二进制和校验文件、验证 SHA-256 与版本，并在替换前检查磁盘空间。成功安装后运行：

```sh
/usr/local/sbin/singbox-manager
```
菜单 5 可交互导出客户端配置：选择节点后输入服务器地址与 NAT 外部映射端口，脚本从本机配置读取凭据并生成可复制的 YAML。

OpenRC 环境不可用时安装停止。新建节点前菜单会显示可读到的 cgroup 内存限制；读不到时不会把宿主机内存当成容器限额。NAT 的端口转发由用户在服务商面板设置；Hysteria2 必须配置 UDP 映射。

凭据、配置和私钥仅保存在本机受限权限目录。不要提交真实配置、凭据或证书。公开仓库与 Release 不包含用户密钥。

## 构建与发布

推送项目版本 tag `v1.0.x` 启动 Actions。当前上游 sing-box 锁定为 `v1.14.2`；升级上游版本需经代码评审调整版本锁。构建原样读取该上游提交内的 `release/DEFAULT_BUILD_TAGS_OTHERS` 和 `release/LDFLAGS`，`CGO_ENABLED=0`，使用 Go `1.25.5`。所有第三方 Actions 固定到完整 commit SHA。CI 检查架构格式、版本信息、三个协议的配置以及本地 TCP/UDP 监听；Release 只在所有架构构建成功后发布。

## 验证范围与限制

CI 的协议启动验收在 `amd64` runner 上执行；其余架构做构建、ELF 架构与版本信息检查。它不证明实际 NAT 端口转发、Nikki 的所有版本兼容性、长期负载下内存占用或 64 MiB 的稳定性。首版不设节点数量上限；64 MiB 下可运行节点数须在目标实例上实测。配置变更可能重启整个服务并短暂中断现有连接。

## License

本项目脚本采用 MIT License。sing-box 是独立上游项目，遵循其自身许可；上游源码和许可：[SagerNet/sing-box](https://github.com/SagerNet/sing-box)。本仓库不隶属于 SagerNet。

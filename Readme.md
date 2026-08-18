# 妙妙屋X 开心版

去掉授权校验的妙妙屋X，**全功能免费**，套餐显示「妙妙屋开心版」。

TG 频道：<https://t.me/fuck_miaomiaowux>

> 本仓库只放安装脚本，编译好的程序在 [Releases](../../releases) 里。

---

## 安装面板

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo bash
```

装完浏览器打开 `http://<你的服务器IP>:12889`，走初始化向导创建管理员账号。

**换端口 / 数据目录**（只在首次安装时生效）：

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo bash -s -- --port 8080 --data-dir /opt/mmwx/data
```

**装指定版本**：

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo bash -s -- --version mmwx-v0.4.8-beta.18
```

**国内网络**连不上 GitHub，加个加速前缀：

```bash
export MMWX_GH_PROXY=https://你的加速前缀/
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo -E bash
```

## 更新面板

**推荐：直接在面板里点。** 系统设置 → 检查更新 → 立即更新，会自己下载新版本、替换、重启，带进度条。

命令行更新（面板打不开时用）：

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo bash -s update
```

两种方式都不会动 systemd 配置和数据目录，换二进制失败会自动回滚。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | sudo bash -s uninstall
```

只删程序和服务，**数据目录保留**，确认不要了自己 `rm -rf /etc/mmwx`。

---

## 添加子服务器（Agent）

面板里「服务器管理 → 添加服务器」，把生成的一键命令拷到子服务器上执行就行 ——
自动装 xray、写配置、配开机自启、连回主控，Agent 程序会自动从本仓库的 Release 下载。

### 升级 Agent

到子服务器上跑：

```bash
curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/upgrade-agent.sh | sudo bash
```

只换程序 + 重启，配置和 xray 都不动，起不来会自动回滚。

---

## 常见问题

**面板装在哪？**
程序 `/usr/local/bin/mmwx`，服务 `mmwx`，数据默认 `/etc/mmwx/data`。
常用命令：`systemctl status mmwx` / `systemctl restart mmwx` / `journalctl -u mmwx -n 50`。

**忘记管理员密码？**
面板数据在 SQLite 里，暂时只能通过重置脚本处理，或者删掉数据目录重新初始化（会丢配置）。

**「检查更新」提示 API 限流？**
GitHub 匿名接口每小时只有 60 次。等一会儿再试，或给服务加个 token：
在 `/etc/systemd/system/mmwx.service` 的 `[Service]` 段加一行
`Environment="MMWX_GH_TOKEN=你的token"`，然后 `systemctl daemon-reload && systemctl restart mmwx`。

**想让面板彻底不联网检查更新？**
同样在 service 文件里加 `Environment="MMWX_UPDATE_REPO=off"`，重启后「检查更新」会永远显示已是最新。

### 面板支持的环境变量

写在 `/etc/systemd/system/mmwx.service` 的 `[Service]` 段里，改完 `systemctl daemon-reload && systemctl restart mmwx`。

| 变量 | 作用 |
| --- | --- |
| `PORT` | 监听端口，默认 12889 |
| `MMWX_DATA_DIR` | 数据目录，默认 `/etc/mmwx/data` |
| `MMWX_GH_PROXY` | GitHub 加速前缀，面板自更新和 Agent 下载都会用 |
| `MMWX_GH_TOKEN` | GitHub token，只为提高 API 限额 |
| `MMWX_UPDATE_REPO` | 面板从哪个仓库更新；设 `off` 关掉在线更新 |
| `MMWX_AGENT_GITHUB_REPO` | Agent 从哪个仓库下载；设 `off` 关掉 |
| `MMWX_AGENT_DOWNLOAD_BASE` | 自建镜像源，取 `{base}/mmwx-agent-linux-{arch}` |

---

## 说明

- 本项目基于妙妙屋X 修改，去除了授权校验，仅供学习交流使用。
- 源码不公开，本仓库只提供脚本和编译好的程序。
- 出问题去 TG 频道反馈。


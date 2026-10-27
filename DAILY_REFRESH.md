# 每日数据刷新

## 快速使用

### 方式 1：双击运行（Windows，最简单）
双击 `daily_refresh.bat`，等待完成即可。

### 方式 2：PowerShell（Windows）
```powershell
.\bin\daily-refresh.ps1
```

### 方式 3：手动命令
```powershell
$env:Path = "C:\Ruby34-x64\bin;" + $env:Path
$env:TDX_DATA_PATH = "C:\new_tdx\vipdoc"
cd C:\Users\huntl\work\stockstave
bundle exec rails daily_refresh
```

## 前提条件

1. **通达信数据已更新** — 先打开通达信，下载当日日线数据
2. **Ruby 3.4 可用** — 脚本已内置路径设置

## 频率建议

- **交易日每天一次** — 收盘后、次日开盘前运行
- **不要重复运行** — `daily_refresh` 有锁机制，同一天不会重复处理
- **只装一个调度器** — systemd 定时器和旧版 cron 安装器二选一。两者同时存在会在
  同一时刻启动两次刷新，互相覆盖 `tmp/tdx-update/hsjday.zip.part`，导致下载的
  压缩包损坏。`bin/daily-refresh.sh` 现在用 `flock`（锁文件
  `tmp/daily-refresh.lock`）串行化整个流程，重复启动会打印
  `Another Stock Stave refresh already holds the lock` 后直接跳过；
  安装 systemd 定时器时也会自动删掉遗留的 cron 条目

## 信号邮件通知

每次 `daily_refresh` 完成后，会自动对比最近两个交易日的信号快照，把信号家族
发生变化的股票（新进入买入区、新的卖出警报、跌回观望区）汇总成一封邮件。
未配置收件人时不会发送，只在日志里打印摘要。

需要设置以下环境变量（详见 README 的 "Signal email notifications"）：

- `STAVE_NOTIFY_EMAIL` — 收件邮箱；设置后才真正发送
- `STAVE_SMTP_ADDRESS` / `STAVE_SMTP_PORT` — SMTP 服务器，如 QQ 邮箱 `smtp.qq.com:587`
- `STAVE_SMTP_USER` / `STAVE_SMTP_PASSWORD` — 邮箱账号和授权码
- `STAVE_HOST` — 可选，让邮件里的个股链接可点击

发送失败只记录日志，不影响刷新本身的成功状态。手动预览：

```powershell
bundle exec rails signal_notify       # 打印摘要；已配置时同时发送
bundle exec rails "signal_notify[sz]" # 只看某个市场
```

## 基本面数据（可选）

策略要求公司体质良好，可以从东方财富公开接口拉取基本面做初筛：

```powershell
bundle exec rails fundamentals_refresh       # 全部市场
bundle exec rails "fundamentals_refresh[sz]" # 单个市场
```

每周跑一次即可（财报按季度更新）。数据包括 PE(TTM)、PB、市值、最新报告期的
加权 ROE、营收同比、净利同比。筛选阈值可用环境变量调整：`FUND_ROE_MIN`
（默认 8，按报告季度年化）、`FUND_REVENUE_YOY_MIN`（默认 0）、
`FUND_PROFIT_YOY_MIN`（默认关闭，置空字符串即关闭某项）。

买入候选卡片上会显示基本面徽标（绿色合格 / 红色存疑 / 灰色无数据），个股详情页
有完整基本面面板。不运行此任务不影响其他功能。

## 什么时候可以回测

连续运行 **20 个交易日** 后，才能看到回测报告：

```powershell
bundle exec rails backtest[sz]
bundle exec rails backtest[sh]
bundle exec rails simulate_strategy[sz]   # 等权 vs 网格仓位对比
```

`backtest` 每个信号族会同时打印绝对收益和**相对当日模型池的超额收益**：
信号在信号日收盘之后的第一个收盘价入场，基线是当天所有有模型的股票（无论
有没有出信号）的同期平均收益，两者按交易日等权相减。所以"只是跟着大盘涨了"
的信号族，超额会接近零甚至为负。`simulate_strategy` 会同时跑等权和网格两种
仓位模式并打印对比（收益、回撤、胜率、以及网格仓位按深度的分布）。网格按建仓
当天的五线谱档位加权：跌破 -2SD 悲观线（档位 -3）权重 2.0，-1SD ~ -2SD 之间
（档位 -2）权重 1.5，其余 1.0。指定单一模式可以看到每日权益曲线，例如
`bundle exec rails "simulate_strategy[sz,grid]"`。

## 定时自动运行（Windows）

以 PowerShell 安装每日 20:30 运行的任务计划：

```powershell
.\bin\install-daily-refresh-task.ps1
```

## 定时自动运行（Linux）

systemd 用户定时器是主要方式，默认每天 20:30 刷新，每周清理日志：

```sh
bin/install-daily-refresh-timer.sh
systemctl --user list-timers stave-daily-refresh.timer stave-retention.timer
```

如果系统不支持 systemd 用户服务，仍可使用已弃用的 cron 兼容安装器：

```sh
bin/install-daily-refresh-cron.sh
```

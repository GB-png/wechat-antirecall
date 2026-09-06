# 红包调用链：macOS 微信 269624

2026-09-06，IDA Professional 9.4 / Hex-Rays arm64，静态分析本机微信 4.1.13.56（269624）的安装前备份。

实现状态：已接入消息 hook、原生接收/拆包任务、串行队列和 GUI/CLI 开关。编译及离线检查通过，**尚未进行真实红包领取验证**。默认关闭，只适配这个构建。这里记录的是红包业务调用链，未重写微信的登录、加密传输或支付认证协议。

## 样本

- 完整 universal dylib SHA-256：`fe0ce66a8972a5eec9df2238ea93ae07f41f288c6367cd635f6efe7d5d4e1c00`
- 原始 arm64 切片 SHA-256：`7cf3d4effabc96bdb23fd2da21486388cbcea5fa1f6dfd72a872e0deba60d601`
- 下列地址为切片虚拟地址，进程内需要加 ASLR slide。
- 字符串常量有分片及运行时解码；函数名多数已哈希化。单独扫描字符串不足以判断能力。

## 请求与回包

`0x40BD584` 注册实际使用的三个请求：

| 操作 | 业务请求编号 | CGI 路径 |
| --- | ---: | --- |
| 接收红包信息 | 1581 | `/cgi-bin/mmpay-bin/receivewxhb` |
| 拆红包 | 1685 | `/cgi-bin/mmpay-bin/openwxhb` |
| 查询详情 | 1585 | `/cgi-bin/mmpay-bin/qrydetailwxhb` |

二进制中的共享路由 XML 还包含旧的 623/625 编号；这不是当前 Mac 服务注册表中的请求编号，不能据此构造当前请求。

接收请求体组装在 `0x40C1594`，拆包请求体组装在 `0x40C7E2C`。可见 `sendId`、`channelId`、`nativeUrl` 等字段；拆包另外携带首次回包的 `timingIdentifier`。实现调用微信自己的服务，让客户端处理账户、传输、请求序列和结果解析。

回包公共字段解析：`0x40D5DD8`；接收结果额外字段解析：`0x40D65C8`。

| 字段 | 结果对象偏移 | 类型 |
| --- | --- | --- |
| `retcode` | `+0x08` | int32 |
| `retmsg` | `+0x10` | libc++ string |
| `sendId` | `+0x28` | libc++ string |
| `isSender` | `+0x58` | bool |
| `receiveStatus` | `+0x78` | int32 |
| `hbStatus` | `+0x7C` | int32 |
| `hbType` | `+0x98` | int32 |
| `timingIdentifier`（接收结果） | `+0x130` | libc++ string |

`0x126FAE4` 是红包封面的可拆状态判断：对于类型 0、1、3，需要 `receiveStatus == 0` 且 `hbStatus` 为 2 或 3。自动化另外要求 `retcode == 0`、不是发送者、`sendId` 对应当前任务且 `timingIdentifier` 非空。未知类型和未知状态全部跳过。

## 两种消息对象

现有 hook 的 `0x494AEDC` 接收网络 Message，其网络构造函数为 `0x4949B84`。它将服务端 ID 写入 `+0xF8`，原始 XML 写入 `+0x130`，类型写入 `+0x0C`，服务端创建时间（秒）写入 `+0x114`。

红包服务需要 **848 字节的 display model**。`0x494E760` 将网络 Message 转换为该模型，返回地址通过 arm64 的 **x8** 传入；`0x38BC54` 负责析构。模型包含深复制的字符串和保留引用的消息扩展。

网络 Message 和 display model 的 vtable、字段布局和大小不同。直接将 hook 收到的指针传给红包服务会错误读取对象。

运行时在原 finalizer 返回后调用转换函数，此时红包扩展已解析。随后把独立模型转交主队列，原 Message 指针不会跨线程保留。

## 服务、任务与 ABI

| 入口 | 地址 |
| --- | --- |
| AppContext getter | `0x4316F84` |
| Context → account context | vtable `+0x68`，返回 shared_ptr |
| account context → service center | vtable `+0x30`，返回 shared_ptr |
| GetService | `0x421E59C` |
| 红包服务描述符 vtable | `0x97640D0` |
| ReceiveRedEnvelope | `0x40DD2CC` → `0x40BDE00` |
| OpenRedEnvelope | `0x40DD2D4` → `0x40BE1FC` |
| 任务订阅 | `0x4DDEA0` → `0x4DECA0` |
| 普通回包基类 RTTI | `0x9768EB8` |
| 接收结果 RTTI | `0x99B8D38` |
| 拆包结果 RTTI | `0x99B8DB8` |

界面调用方 `0x4DD620` / `0x708594` 调用接收；`0x126FD1C` 调用拆包。回调 `0x4DFBB0`、`0x1271970` 均接收指向 `shared_ptr` 的参数，并通过 RTTI 检查结果类型。

原生任务是惰性的：仅调用 Receive/Open 工厂不会执行请求，必须订阅。任务布局 56 字节：32 字节 function、16 字节 weak_ptr、8 字节附加状态。订阅结果 40 字节：8 字节 ID、两个 shared_ptr。来源信息结构 32 字节。

`NativeSRet.S` 显式设置 x8，避免 C++ 编译器按平凡字节结构复制含有字符串或容器的原生返回值。离线 ABI 测试跨这个桥接检查五个参数、任务返回、回调、shared_ptr / weak_ptr 生命周期。

## 运行策略

- 仅在 269624 且九处原生函数指纹一致时初始化；其他构建不调用这些地址。
- 只处理模式 1、类型 49、红包 appmsg 类型 2001 和普通 `receivehongbao` URL。
- 开启后才接受新消息，消息年龄不超过 60 秒；来自未来的时间戳、历史消息、自己发送及账户不匹配的消息被忽略。
- XML 大小、层级和字段长度有上限；拒绝 DTD、实体声明、重复关键字段和重复 URL 参数。
- 按 `sendid` 去重，至多 32 个待处理项目、1024 个去重项。去重项保存时间长于消息接受窗口；满载时拒绝新任务。
- 顺序执行“接收 → 检查状态 → 拆包”，每个红包最多各发起一次；没有失败重试或凭据缓存到磁盘。
- 超时、关闭开关、切换账户后，不再从迟到的接收回包发起拆包。已经发出的请求无法凭本地开关撤销。
- 日志只记录状态词，不记录聊天内容、账户名、红包 URL 或领取凭据。

配置保存在所选微信 bundle 自己的 plist 的 `WeChatAntiRecall_RedPacket` 字典。GUI 更新组件复用现有备份和重签名流程；自动化运行依赖自定义提示模式的消息 hook。

## 检查与复现

```sh
swift test --filter 'RedPacketTests|RuntimeRewriteTests|InlineHookEngineTests|InstallReportStateTests'
```

本轮上述 75 项测试通过；另将九处原生指纹与原始切片逐字节比对，全部一致。静态分析和离线 ABI 测试不能证明真实微信运行中的完整兼容性，也不能证明实际领取成功。

用 `Scripts/research/inspect-red-packet-269624.py --binary <原始 dylib> --out <新目录>` 可重建关键函数的 IDA 导出。需要已配置可用许可证的 [IDA / idalib](https://docs.hex-rays.com/user-guide/idalib)，脚本不会读取账户数据或发起网络请求。

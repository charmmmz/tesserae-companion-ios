# Tesserae 蓝牙能力矩阵与 Companion 直传方案

日期：2026-10-21（Asia/Shanghai）。状态：**源码审计与拟议方案；未实现通用传图，未新增实机验证。**

后续实施见 [Photo v2 实施与硬件验收交接](2026-10-21-ble-photo-v2-implementation.md)。本文保留审计时固定的 1.51.0 源码状态；实际实验 checkout 已是 1.52.0（421d51a）。后续本地实验实现不改变下表的已发布能力结论。

## 结论

可以把 Companion 的蓝牙照片功能设计成通用能力，但不能把“芯片支持 BLE”当作“现有固件支持收图”，也不能用屏幕型号决定唯一字节格式。

建议共用照片编辑、构图、色彩处理、能力模型与任务状态；保留三个协议适配器：现有 PicPak Photo v1、拟新增 Tesserae Photo v2、OpenDisplay。统一 ESP-IDF 固件使用一套板型无关的收图核心，逐板验证后启用。其他框架可以遵循同一应用协议，但仍需各自的蓝牙/存储/电源后端。

本次扫描服务器 **61 个 hardware JSON 条目、13 个 device kind**，并记录 **23 个仓库快照**。61 是目录条目数，包含灰阶变体和同一硬件的不同固件，不是 61 款独立设备，也不表示全部经过硬件验证。

- 统一固件：30 个目录条目可对应其板型，其中 15 个构建已启用 BLE 设置/维护；这 15 个全部尚无照片接收命令。
- PicPak：有独立的蓝牙收图协议，当前 Companion 已有专用实现；不等同于已完成本次实机验收。
- OpenDisplay：固件生态原生提供图片上传；Companion 尚无其蓝牙驱动。两种服务器 device kind 共用同一设备侧协议适配器。
- NOTE4C、CrossInk、TRMNL、Pico、Linux Pi、Inkplate 社区固件、KOReader 等：不能因芯片有蓝牙或支持离线显示就显示“蓝牙发图”按钮。
- Bloomin8：已找到 BLE 唤醒实现，图像仍通过 HTTP 上传；应单列“蓝牙唤醒 + 局域网传图”，不能宣称纯蓝牙传图。

## 1. 审计范围与证据等级

服务器 main 快照：6e16ea402d9d41be8616c73de4cc2b3529c9b43b。统一固件 main / 最新正式发布 v1.51.0 均为 1e5a1be5b26ffa46fecc87475ee4945292c2c54f。Companion 本地基线：d430a60a80b04258924bcb39069c0e1092192fca。

优先检查 data-only manifest、PlatformIO 构建、板级定义、GATT 服务和命令分发，再参考 README。上游说明存在滞后，例如统一固件 BLE 编号表遗漏或保留了后来已占用的编号。矩阵中的“已启用”指发布源码/构建配置，而非每板实测连接成功。

对 Linux/封闭设备或通用 kind，无法从型号或协议插件证明其蓝牙外设能力时，标为依设备/未知；“没有收图实现”不等于“物理上没有蓝牙”。自定义面板、浏览器镜像以及不在目录中的任意硬件，没有可穷举的型号集合。

事实来源：
- [硬件目录说明](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/docs/compatibility.md)、[客户端路线](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/docs/install/clients.md)。
- [统一固件实际构建](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/platformio.ini)、[GATT 与命令实现](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/src/ble_setup.c)。
- [Espressif BLE 能力表](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/bt-architecture/overview.html)：经典 ESP32、S3、C3、C6 支持 BLE；与应用固件启用状态分开。
- [Pico W / Pico 2 W 官方无线能力](https://www.raspberrypi.com/documentation/microcontrollers/raspberry-pi-pico.html)：无线芯片具备 BLE，不代表本次检查的 Pico 应用启用了 GATT。

完整目录快照与板级宏另存于同目录的 2026-10-21-bluetooth-hardware-audit.sources.json。

## 2. A 组：统一固件已经启用 BLE 的 15 个构建

以下全部使用 ESP32-S3 + PSRAM，链接 sdkconfig.ble.defaults；可共用拟新增的 NimBLE 收图核心。当前服务只有设备信息、QR/Passkey 控制和事件；命令分发不包含 photo_begin、photo_end 或图片数据入口。现有模型/固件信息也没有完整图片能力描述。

原生尺寸以**该固件实际接收的行宽**为准。字节数是默认格式的原始完整帧，不含协议/认证开销，不代表压缩后大小。

| 板型/构建 | 实际 BLE code | 接收缓冲尺寸 | 默认编码 | 原始字节 | 当前状态 |
| --- | ---: | --- | --- | ---: | --- |
| [Seeed reTerminal E1001](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1001.h) | 1 | 800×480 | 1bpp 黑白 | 48,000 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal E1001 (4-level grayscale)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1001_gray.h) | 1 | 800×480 | 2bpp 四灰 | 96,000 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal E1001 (4-level grayscale, legacy glass)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1001_gray_legacy.h) | 1 | 800×480 | 2bpp 四灰 | 96,000 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal E1002](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1002.h) | 2 | 800×480 | 4bpp Spectra 6 | 192,000 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal E1003](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1003.h) | 3 | 1872×1404 | 4bpp 十六灰 | 1,314,144 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal E1004](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_e1004.h) | 4 | 1200×1600 | 4bpp Spectra 6 | 960,000 | 设置/维护已编译；收图未实现 |
| [Seeed reTerminal Sticky](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_reterminal_sticky.h) | 8 | 480×800 | 2bpp 四灰 | 96,000 | 设置/维护已编译；收图未实现 |
| [Seeed XIAO ePaper EE02 (13.3")](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_ee02.h) | 5 | 1200×1600 | 4bpp Spectra 6 | 960,000 | 设置/维护已编译；收图未实现 |
| [Seeed XIAO ePaper EE03 (10.3" mono)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_ee03.h) | 11 | 1872×1404 | 4bpp 十六灰 | 1,314,144 | 设置/维护已编译；收图未实现 |
| [Seeed XIAO ePaper EE04 (7.5" mono)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_ee04_75.h) | 6 | 800×480 | 1bpp 黑白 | 48,000 | 设置/维护已编译；收图未实现 |
| [Seeed XIAO ePaper EE04 (7.3" Spectra 6)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_ee04_73e6.h) | 7 | 800×480 | 4bpp Spectra 6 | 192,000 | 设置/维护已编译；收图未实现 |
| [Seeed XIAO ePaper EE05 (2.13" BWRY)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_ee05.h) | 9 | 128×250 | 2bpp 黑白黄红 | 8,000 | 设置/维护已编译；收图未实现 |
| [M5Stack PaperMono](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/m5stack_papermono.h) | 12 | 480×800 | 2bpp 四灰 | 96,000 | 设置/维护已编译；收图未实现 |
| [Good Display ESP32-133C02 (13.3")](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/gooddisplay_esp32_133c02.h) | 18 | 1200×1600 | 4bpp Spectra 6 | 960,000 | 设置/维护已编译；收图未实现 |
| [Soldered Inkplate 13SPECTRA](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/soldered_inkplate_13spectra.h) | 19 | 1200×1600 | 4bpp Spectra 6 | 960,000 | 设置/维护已编译；收图未实现 |

原生固件已经具备屏幕驱动，因此新增收图模块不应逐板重新实现 SPI/波形。驱动之间的双控制器、镜像、转置和刷新差异仍由驱动负责，只有需要在发送端完成的变换进入能力描述。

这 15 个构建并不全都经过实机验证。例如 EE05 的可见列偏移与色序仍有待自测确认；不能因为 BLE 编译成功就发布为“已支持蓝牙照片”。E1001 普通灰阶与 legacy 玻璃构建也不能合并成一个波形设置。

## 3. B 组：统一固件另外 15 个目录条目

以下 MCU 具备 BLE；当前构建未启用上述 NimBLE 设置服务，不能由 App 单方面解锁传图。

| 板型 | MCU/内存 | 当前 BLE 收图 | 额外适配 |
| --- | --- | --- | --- |
| [Elecrow CrowPanel 5.79" E-Paper](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/elecrow_crowpanel_579.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [epdiy v7 + ED133UT2 13.3"](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/epdiy_v7.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [M5Stack M5Paper](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/m5stack_m5paper.h) | 经典 ESP32，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [M5Stack PaperS3](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/m5stack_papers3.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [paperlesspaper OpenPaper 7](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/paperlesspaper_openpaper_7.h) | ESP32-C6，无 PSRAM | 无已启用收图服务 | 需内存/镜像容量审计和独立物理授权入口 |
| [paperlesspaper OpenPaper L](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/paperlesspaper_openpaper_l.h) | ESP32-C6，无 PSRAM | 无已启用收图服务 | 须先新增暂存/校验路径；现为 HTTP 分块直送屏幕 |
| [Seeed XIAO ePaper 7.5" (S3, mono)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_xiao_epaper_75.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Seeed XIAO ePaper 7.5" (black/white/red)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_xiao_epaper_75_bwr.h) | ESP32-S3，有 PSRAM（继承 mono 板定义） | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Seeed XIAO 7.5" ePaper Panel (C3)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/seeed_xiao_epaper_75_c3.h) | ESP32-C3，无 PSRAM | 无已启用收图服务 | 需内存/镜像容量审计和独立物理授权入口 |
| [Waveshare PhotoPainter 7.3"](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/waveshare_photopainter_73.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Waveshare 10.85" e-Paper HAT+ (G) (ESP32-S3 Zero)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/waveshare_1085g.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Waveshare 13.3" Spectra E6 (ESP32-S3)](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/waveshare_133e6.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Waveshare 7.3" e-Paper (F) on an ESP32-S3](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/waveshare_epaper_73f.h) | ESP32-S3，有 PSRAM | 无已启用收图服务 | 可复用拟新增收图核心；需增加 BLE 构建与授权入口 |
| [Waveshare E-Paper ESP32 Driver Board + 7.5" B/W](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/waveshare_esp32_driver_75.h) | 经典 ESP32，无 PSRAM | 无已启用收图服务 | 需内存/镜像容量审计和独立物理授权入口 |
| [Xteink X4](https://github.com/dmellok/tesserae-device-firmware/blob/1e5a1be5b26ffa46fecc87475ee4945292c2c54f/boards/xteink_x4.h) | ESP32-C3，无 PSRAM | 无已启用收图服务 | 需内存/镜像容量审计和独立物理授权入口 |

共用范围是“收图状态机 + 校验 + 板驱动接口”。增加 BLE 的同时必须解决物理授权入口、会话时限、堆内存/镜像容量和唤醒方式。没有 Refresh 键的设备不能直接套用当前 ble_setup.c：它有 BOARD_BTN_REFRESH_PIN 编译门槛。

OpenPaper L 是单独风险：当前没有完整帧 RAM 缓冲，HTTP 路径分块直送控制器。若要求“校验失败或中途取消不显示半张图”，必须先提供可验证的暂存或明确的控制器提交语义；不能直接让 BLE 分包写屏就宣称与 PSRAM 板行为等价。其 16 MB NAND / SD 在 Tesserae 中尚未被用作这条暂存路径。OpenPaper 7、C3 板和无 PSRAM 的经典 ESP32，也需单独测量无线栈与帧缓冲同时存活时的资源余量。

## 4. 其他固件与通用设备路线

下表补足 A/B 外的 31 个目录条目，并补充没有单独 hardware JSON 的 OpenDisplay、Bloomin8、通用客户端。Inkplate 13SPECTRA、X4、Sticky 的多固件路径特意重复说明。

| 设备/路线 | 硬件 BLE | 当前固件暴露的蓝牙功能 | 图片是否能纯 BLE 到屏幕 | 复用与适配判断 |
| --- | --- | --- | --- | --- |
| PicPak 4.2 / varanu5 PicPak | ESP32-C3，支持 | 认证维护 + Photo v1 | **有协议与实现** | 保留 PicPakV1 适配器；图像底行优先、2bpp、400×300；将来可升级能力协议 |
| ZecTrix NOTE4C / varanu5 | ESP32-S3，支持 | README 明确 Bluetooth 未实现 | 否 | 不能因 picpak_client HTTP kind 相同推定 BLE 相同；可移植通用核心，但需该仓库新增服务/密钥/模式管理；其帧是顶行优先 |
| Inky Frame 7.3 Spectra / ACeP，partridgeworks | Pico W / Pico 2 W 无线芯片支持 | 本次源码没有收图 GATT | 否 | 需要 Pico SDK / BTstack 后端，复用应用协议与图像管线；不可直接链接 ESP-IDF NimBLE 模块 |
| Pico Plus 2 W + Inky 13.3，dmellok | 无线芯片支持 | 现有网络收图，无收图 GATT | 否 | 与上行相同，但固件仓库、屏幕缓冲与旋转路径分别处理 |
| Inky Impression 4（含 ACeP），及 Pi 客户端支持的 2/3/6/7 色 HAT | HAT 本身无 BLE；依 Pi 主机/USB 适配器 | Pi daemon 走 REST/MQTT | 否 | 若做，新增 Linux BlueZ peripheral 服务，利用已有图像绘制；属独立主机后端 |
| Inkplate 10 / partridgeworks | ESP32-WROVER，支持 | 网络客户端，未见收图 GATT | 否 | Arduino BLE 后端；注意八灰的 4bpp 容器及灰阶映射 |
| Inkplate 6COLOR / ripking | 经典 ESP32，支持 | 网络客户端，未见收图 GATT | 否 | Arduino 后端，七色 ACeP；产品名里的 6COLOR 不能用来推断六色协议 |
| Inkplate 13SPECTRA / ripking | ESP32-S3，支持 | 网络客户端，未见收图 GATT | 否 | Arduino 后端接收 **1600×1200**；统一固件是 **1200×1600**，须按固件能力选行宽 |
| Xteink X3、X4、X4 Pro / CrossInk；Sticky 的 CrossInk 构建 | C3 / S3，支持 | Nearby 使用 **ESP-NOW**；构建忽略 BLE 库 | 否 | ESP-NOW 不能由 iPhone CoreBluetooth 直接发送；需 CrossInk 自身新增 BLE 服务和屏幕任务仲裁 |
| TRMNL OG、X、Seeed C3 BYOS，以及 reTerminal 的 TRMNL 构建 | OG/C3 与 X/S3 等具备 BLE | 本次检查没有照片 GATT；X/E1004 的 sdkconfig 明确关闭 CONFIG_BT_ENABLED | 否 | 依赖 TRMNL 上游固件扩展；不能用 Companion 的 Tesserae 设置协议操作 stock TRMNL |
| Kindle 六个目录条目、Kobo 六个目录条目 / KOReader | 依型号/系统，不统一确认 | Tesserae 插件走 REST；音频蓝牙不能证明能做自定义 GATT 外设 | 无已实现路径 | 要新增系统/插件收图服务，受系统权限和驱动约束；当前保留网络路径 |
| reMarkable 1、2、Paper Pro / AppLoad | 未在本次建立统一可用的 BLE 外设能力 | Go/Qt 网络应用 | 无已实现路径 | 独立系统后端；不能按 esp32_client kind 推断它是 ESP32 |
| Waveshare 4.2 B/W / 旧 esp32-bw 客户端 | 取决于配套 ESP32 板；所查目标支持 BLE | MQTT 客户端，无收图 GATT | 否 | 可迁移/移植通用接收核心；面板本身不提供蓝牙 |
| 旧 Waveshare 13.3 esp32-bin、旧 PhotoPainter 独立固件 | ESP32-S3，支持 | MQTT/HTTP，无收图 GATT | 否 | 优先迁移到统一固件路线，避免维护重复蓝牙栈 |
| OpenDisplay / 两种 Tesserae 接入方式 | ESP32、nRF、Silabs 等依板 | 原生图片上传、配置、可选认证 | **有** | 一个 OpenDisplay 适配器覆盖不同屏幕能力；协议与 Tesserae/PicPak 不同 |
| Bloomin8 Canvas（两种尺寸）/ 厂商固件 | 已有可连接 BLE 唤醒路径 | BLE 写唤醒脉冲，然后 HTTP 上传图片 | 没有由本次证据确认的纯 BLE 收图协议 | 若提供手机直连，先明确为 BLE 唤醒 + 同网 HTTP，独立于本次纯 BLE 发图 |
| CircuitPython 通用设备 | 依具体 MCU、运行时和板包 | 当前通用客户端走 REST | 无统一实现 | 需单独运行时后端；不能对整个 circuitpython_generic kind 作支持承诺 |
| CrossPoint sleep-screen 通用 kind | manifest 未给出可核验的统一芯片/固件仓库 | 服务器定义的是 LAN BMP 拉取 | **未知/无已发布接入依据** | 不从 CrossInk 或相似名称推断；拿到具体实现与 GATT 合同后再纳入 |
| Browser mirror / 任意平板浏览器 | 依终端 | HTTP 页面 | 无纯 BLE 屏幕收图实现 | 不纳入固件改造清单 |

关键来源：
- [PicPak 完整 Photo v1 合同](https://github.com/varanu5/picpak-tesserae-client/blob/539731c3537ed68ac2df0e6c29645c2270ea452c/docs/ble-photo.md)。
- [NOTE4C 尚未实现 Bluetooth](https://github.com/varanu5/zectrix-note4c-devkit-tesserae-client/blob/7ce23c9c36ab5ccad05cef84111e1af0820634f2/README.md)。
- [CrossInk 的 ESP-NOW](https://github.com/dmellok/CrossInk/blob/15b2a91a19fee8a0202a62b5cabe62b51d44b42c/docs/nearby-file-transfer.md)、[CrossInk 构建](https://github.com/dmellok/CrossInk/blob/15b2a91a19fee8a0202a62b5cabe62b51d44b42c/platformio.ini)。
- [Inkplate 社区绘制路径（源文件快照链接）](https://github.com/ripking/inkplate-tesserae-driver/blob/688a5839ed12c63c95cfcceb202988661c277b18/firmware/src/frame_painter.cpp)。
- [TRMNL X 实际配置](https://github.com/usetrmnl/trmnl-firmware/blob/4ee1b610751e42135f2c2d55e388f76ab3659cb5/sdkconfigs/sdkconfig.TRMNL_X)、[TRMNL E1004 实际配置](https://github.com/usetrmnl/trmnl-firmware/blob/4ee1b610751e42135f2c2d55e388f76ab3659cb5/sdkconfigs/sdkconfig.seeed_reTerminal_E1004)。
- [Bloomin8 BLE 唤醒](https://github.com/ARPOBOT-BLOOMIN8/eink_canvas_home_assistant_component/blob/65742327efab652e8438171010d2c4d61f96502d/custom_components/bloomin8_eink_canvas/ble_wake.py)、[HTTP 图片操作](https://github.com/ARPOBOT-BLOOMIN8/eink_canvas_home_assistant_component/blob/65742327efab652e8438171010d2c4d61f96502d/custom_components/bloomin8_eink_canvas/api_client.py)。
- [CrossPoint 当前服务器合同](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/devices/crosspoint_gray/device.json)。

## 5. OpenDisplay 能共用到哪一层

OpenDisplay 的 HA 路径与 standalone bridge 只是 BLE 主机不同，手机侧不需要做两个驱动，也不需要 HA device id、Tesserae token 或服务器配对。手机直接发现设备、读取配置、获取密钥（若启用）并发送。

但“一个适配器”不代表所有设备共享相同像素布局或传输快路径：
- 黑白可为 1bpp，BWR/BWY 采用分离位平面；四灰也可采用两个 1-bit plane，不能套用 Tesserae 的 packed 2bpp。
- 六色有普通行优先与 BWGBRY_SPLIT 左右半平面布局；某些 BWRY/灰阶型号还有 code map。
- PIPE 滑动窗口协议在 canonical spec 标注的 Firmware（nRF52840/ESP32）目标上实现；NRF54、Silabs、NRF52811 不应被假定支持同一路径。需按设备配置、目标实现和响应协商，保留 direct-write 路线。
- 安全设备采用协议规定的认证/AES-CCM，而现有 Tesserae BLE v2 使用 AES-GCM；不能共用同一个 crypto envelope。
- 当前官方已有生成的 Swift 协议常量与结构体，可审查许可证和生成器后固定版本复用；这不是完整 CoreBluetooth 传输或图片编码 SDK。
- iOS 用 CBPeripheral 标识与设备协议身份管理连接，不要求用户输入 BLE MAC；HA 的 MAC 发现方式不能照抄到 iOS。
- 若 HA/桥接器也在管理同一标签，需串行占用、处理连接忙与内容随后被自动任务覆盖；不能承诺手机拥有持久控制权。

来源：[canonical 协议与 target 矩阵](https://github.com/OpenDisplay/opendisplay-protocol/blob/1080d797341402a96f5240d3c436f0a95c8b2f47/src/opendisplay_protocol.h)、[生成的 Swift 常量](https://github.com/OpenDisplay/opendisplay-protocol/blob/1080d797341402a96f5240d3c436f0a95c8b2f47/src/opendisplay_protocol.swift)、[生成的 Swift 结构](https://github.com/OpenDisplay/opendisplay-protocol/blob/1080d797341402a96f5240d3c436f0a95c8b2f47/src/opendisplay_structs.swift)、[图像编码](https://github.com/OpenDisplay/py-opendisplay/blob/48473123053dd5193fb15b8e7aa486410a7f919a/src/opendisplay/encoding/images.py)、[位平面编码](https://github.com/OpenDisplay/py-opendisplay/blob/48473123053dd5193fb15b8e7aa486410a7f919a/src/opendisplay/encoding/bitplanes.py)。

## 6. 必须先处理的实际兼容问题

### 6.1 BLE 数字编号已经冲突

Companion 当前 BLESetupHardware 是按 UInt8 固定枚举并在广播阶段解析。上游实际板定义与本地不同：

| code | 当前 Companion | 当前统一固件 | 影响 |
| ---: | --- | --- | --- |
| 8 | XIAO 7.5 | reTerminal Sticky | 可能识别为错误型号 |
| 9 | Waveshare 13.3 | EE05 | 可能识别为错误型号 |
| 11 | PicPak | EE03 | 设置服务存在身份歧义；不能直接全局改枚举覆盖 |
| 12 | 无枚举 | PaperMono | 广播解析失败/不进入现有枚举 |
| 18 | 无枚举 | Good Display ESP32-133C02 | 同上 |
| 19 | 无枚举 | Inkplate 13SPECTRA | 同上 |

本地路径：App/Sources/DeviceSetup/BLESetupProtocol.swift、NearbyDeviceManager.swift。上游 docs/ble-setup-protocol.md 的 8/9 仍写旧 reserved 值，因此这里以板级宏和发布构建为准。

建议先保留 rawHardwareCode，对已知服务识别协议族；连接读取 info 后以 model + 固件/能力合同校验设备。广播只能提示“附近屏幕”，不能作为执行 PicPak 专用命令的充分条件。旧 PicPak 的 code=11 必须保留兼容；Photo service 可区分照片会话，但维护 service 相同，仍需读设备信息。新增协议加入明确 family / kind，避免再增加无命名空间的编号。公开 info 只是自报，真正授权仍靠 QR/Passkey/密钥流程。

### 6.2 “同一型号、同一字节数”也不能保证同格式

- Inkplate 13SPECTRA：社区固件按 1600×1200 接收，统一固件按 1200×1600 接收；都恰好 960000 字节。目录的 landscape 配置不能直接用于统一固件 BLE 路线。
- EE05：可见像素 122×250，原生缓冲 128×250，目录默认横向构图 250×122，col_offset=6；要先变换再补隐藏列，不是把照片拉伸到 128 宽。
- PicPak 与 NOTE4C：都 400×300 四色，但目录 vflip 分别为 true / false。
- M5Paper / PaperS3：构图是 540×960，接收行宽是 960×540；Sticky / PaperMono 则接收 480×800，由驱动处理控制器方向。
- 六色 Spectra 6 与七色 ACeP 的 nibble 色序不同。Inkplate “6COLOR” 实际走七色 ACeP。
- E1001 的灰阶波形由具体玻璃/固件管理，App 不应通过 BLE 图像编码猜波形。
- 当前照片加载路径 maximumPixelSize=1536 是 PicPak 场景的上限；通用化时应按目标尺寸保留足够源像素，把 Vision 分析缩略图与最终输出分开，避免大屏先缩小再放大。

这些区别要求能力合同描述 visible geometry、buffer geometry、变换、stride、padding、palette code map、packing 和行顺序，而不只是 width/height/colors。

## 7. 建议架构与协议边界

### 7.1 App 共用层，三个传输适配器

拟新增结构，尚未写入代码：

- NearbyDisplayIdentity：协议族、服务、设备自报 kind/model、稳定身份、固件版本、原始编号。
- PhotoCapabilities：经过认证会话确认的能力、能力摘要、可接受格式、缓冲尺寸/stride/平面、可见区域和构图变换、刷新与传输限制。
- LocalPhotoPipeline：解码/EXIF、裁剪/Auto Frame、按目标色板抖色、编码/补齐，输出不可变 EncodedFrame；编码器按格式分派。
- PhotoTransferSession：连接、认证、发送、取消、已校验接收、等待显示结果/结果未知、错误。UI 不实现具体分包规则。
- PicPakV1Adapter：保持当前 30000 字节/192-byte stop-and-wait、底行优先、现有密钥撤销行为。
- TesseraePhotoV2Adapter：新增能力协议、可协商分包/窗口与统一固件接收。
- OpenDisplayAdapter：复用其 canonical Swift 定义，独立实现配置解析、AES-CCM、direct-write / PIPE 与编码变体。

CoreBluetooth 连接调度、照片编辑与量化算法可共用；ACK、加密封装、压缩/plane 布局及刷新语义由适配器决定。不把 OpenDisplay 的 AES-CCM 改成现有 AES-GCM，不向旧 PicPak 静默发送 v2 格式。

### 7.2 拟议 Tesserae Photo v2 能力合同

新增独立、版本化的图片能力查询；不把完整能力塞入当前 320-byte 公共 info 或 31-byte 广播。通过已有认证控制通道，按有限分页/分片读取；控制消息保留尺寸上限，图片走独立二进制数据特征。

合同至少包含：
- family、schema、kind/model、firmware、capability_digest。
- visible_w/h、buffer_w/h、row_stride_bytes、padding/visible_rect、从预览到缓冲的完整变换。
- formats 列表：编码 id/version、bpp、row_order、bit/nibble order、plane 结构、palette RGB 与 wire code map、exact_bytes。
- transport：最大 chunk payload、设备窗口/队列、最大原始/压缩字节数、允许的压缩、idle/absolute timeout。
- lifecycle：物理授权与唤醒方式、是否 photo-only 可用、手动模式行为、低电量/温度拒绝条件、接收/刷新结果语义。

发送端用明确 format id + capability_digest + exact byte count + SHA-256 开始传输；接收端在分配前检查尺寸/乘法溢出/可用内存，拒绝不匹配，收齐校验后提交。App 自己的型号表可作显示/校验，不可在缺少固件收图声明时推定支持。

首版格式集合：mono1、gray2、gray4、BWR packed2、BWRY packed2、Spectra6 packed4、ACeP7 packed4；gray8 是有映射的 gray4 容器。OpenDisplay 的 bitplanes / split6 通过自己的布局适配器输出。Photos UI 只展示目标真正接受的格式。

### 7.3 统一固件接收模块

建议把 BLE 认证、收图状态机、存储接收、校验和屏幕提交分层：
- 现有 QR/Passkey 可作为首次物理授权基础；离线发图不要求已配置 Wi-Fi 或已注册 Tesserae。持久照片密钥的发放、撤销与工厂重置要有明确合同，不能复用服务器 token。
- NimBLE 后端与当前设置/维护共用 radio 生命周期；不在 BLE 回调内做抖色、刷屏或同步写大文件。
- PSRAM 板接收完整帧或使用可验证暂存；低内存板用专门 backend。失败、取消或断连不触发显示半成品。
- 通用接收核心面对 epd_driver / panel info，不直接写各板 SPI。图像形状依实际固件驱动，不直接读取服务器 catalog 当运行时真相。
- 在照片接收模式暂停 REST/MQTT/relay/本地轮播的显示写入；区分一次性覆盖与手动保持，明确重启后的行为，以及用户如何恢复自动更新。
- 尽量先关闭无线再刷新，遵守现有板的电源时序。接收 ACK 不能伪装为显示成功：例如 PicPak 的 photo_received 明确只表示校验收齐。若驱动没有可核验的刷新返回值，UI 显示“已接收，屏幕正在刷新”，结果标为未知；只有驱动/后续查询明确确认才显示“刷新完成”。

不建议为了发一张图把整机刷成 OpenDisplay 固件，或在首版统一固件里同时再造一套完整 OpenDisplay 服务。保留现有 Tesserae 身份与授权，先做单一通用收图模块；OpenDisplay 是 App 中并列的标准适配器。若上游希望固件也标准化，应先协商是否正式实现 OpenDisplay 兼容服务，以及身份、认证、配置和模式映射，再替换 v2 路线，避免同时长期维护两套新服务。

### 7.4 大文件传输与资源边界

E1004 是 960000 字节，E1003/EE03 是 1314144 字节，PicPak 是 30000 字节。沿用 192-byte 单块并逐块等待应用 ACK，前两者分别约 5000 / 6845 块，还可能叠加多次 ATT 写入与加密分片；不能沿用 PicPak 时限就宣布可用。

新协议需协商 MTU 可承受的 payload，使用受控 credit/window 和累计 offset ACK；在 iOS 遵守 maximumWriteValueLength 与 canSendWriteWithoutResponse 等流控，设置超时与有限重试，避免盲发。逻辑重试使用新的加密 counter，不复用 ciphertext。旧 PicPak 保留原协议。

首版可以不做跨连接断点续传：断开即丢弃未提交数据，重连重新查询能力并开始新 transfer。若加入续传必须绑定设备、格式、digest 和 transfer generation，另做合同，不能仅凭 offset 接上。

压缩只在双方声明后启用，明确压缩前后长度与完整性。低内存板尤其不能假定能同时分配 zlib、蓝牙队列和完整帧。速度、续航、最大距离都必须实测，本文不作传输秒数承诺。

## 8. 分阶段落地与验收

| 阶段 | 具体交付 | 允许声明的支持范围 |
| --- | --- | --- |
| 0：身份与合同 | 修复 raw hardware code / 型号解析，整理现有 PicPakV1，冻结能力与错误合同，核对上游编号；不改变旧设备发送行为 | 仍只有当前 PicPak 路线；其他仅识别 |
| 1：统一能力与代表板 | App 通用照片管线 + PhotoV2；统一固件公共收图模块；先 E1004 六色大帧 + E1001 黑白 + Sticky 或 PaperMono 四灰 | 每块完成实测后逐块启用 |
| 2：覆盖全部 A 组 | 同一实现编译 15 个构建；E1003/EE03 最大帧、EE05 隐藏列、Inkplate13 固件几何差异等补实机验收 | 明确区分“已编译/待验证/已验收” |
| 3：OpenDisplay 并行路线 | 一个协议适配器，认证、配置、direct-write，按能力启用 PIPE；至少一块小单色与一块彩色大屏及加密设备 | 只声明已验证设备/固件组合，不笼统宣传全部标签 |
| 4：B 组与社区移植 | 同固件有 PSRAM S3 优先；NOTE4C/Arduino 后端；无 PSRAM C3/C6、OpenPaper L、Pico、Linux 分别做资源/系统实现 | 逐固件提交与验证，不由 App 单方面扩大 |
| 后续可选 | Bloomin8 直连 HTTP、封闭阅读器 BLE 等独立项目 | 与“纯蓝牙照片”分开呈现 |

阶段 1 不必等全部设备到手才开始代码，但不能提前给未验证设备打“已支持”标签。具体日期取决于上游接受合同和可用测试硬件，不从源码估算出发布承诺。

最低验收矩阵：
- 图像：六色/七色色条、0/1 位序、渐变、角标、文字、横竖/翻转、隐藏列、奇数行宽、不同格式确切字节数；与相应服务器 packer 的 golden vectors 比较。
- 协议：重复/延迟/越界 offset、错误格式/digest、能力变更、丢 ACK、断连/取消、超时、旧固件未声明能力；模拟 peripheral 有用但不替代空口实测。
- 身份/授权：编号 8/9/11 冲突、未知编号、QR/Passkey、密钥存储失败、撤销、工厂重置、另一台手机；防止误执行维护指令。
- 生命周期：无服务器/Wi-Fi 配置仍能照片授权，手机后台/锁屏、设备睡眠与物理唤醒、低电量拒绝、恢复自动更新、自动内容与手机发送的并发。
- 资源：小帧、960KB、1.31MB；每目标固件构建/slot 容量，峰值堆/PSRAM、BLE throughput、刷新电流与温度边界。性能/电量仅以实测为准。
- OpenDisplay：非加密/加密、legacy/direct-write/PIPE、packed/bitplane/split 格式，以及 HA/桥接器占用连接时的行为。

## 9. Companion 预计改动位置

| 当前文件 | 拟改动 |
| --- | --- |
| App/Sources/DeviceSetup/BLESetupProtocol.swift | raw code、协议族与设备身份解析；保持现有 QR/Passkey 合同 |
| App/Sources/DeviceSetup/NearbyDeviceManager.swift | 从 PicPak 专用大状态机拆出协议适配器；共用扫描/连接调度 |
| App/Sources/DeviceSetup/BLEPhotoProtocol.swift | 把现有常量固定在 PicPakV1；新通用能力/任务类型单独建文件 |
| App/Sources/DeviceSetup/PicPakPhotoEncoder.swift | 保留旧 packer；提取可共用 raster/量化，新增独立格式 packer |
| App/Sources/DeviceSetup/NearbyPhotoSendView.swift | 动态 panel、文案、源像素上限与错误展示；保持服务器配对独立 |
| SharedUI / TesseraeKit | 复用裁剪和 Auto Frame；新增确定性的布局/编码值模型 |
| App/Tests 与 TesseraeKit tests | 新能力与字节合同验证，保留 PicPak 的回归向量 |

统一固件实际文件：src/ble_setup.c、src/ble_setup_protocol.*、src/main.c、panel/epd_panel.h 及各板配置；新增独立 photo receiver / sink，避免把所有大帧逻辑塞进设置 JSON 处理器。

## 附录 A：61 个目录条目逐项归类

本表保留**服务器目录中的尺寸**，并非为尚不存在的 BLE 服务背书。尤其 Inkplate13，不能直接把这里的 native 尺寸用于另一套固件。所有条目的原始说明和验证限制保留在 sources.json。

| 目录 ID / 来源 | 构图尺寸 | catalog native | 色域 | 当前蓝牙分类 |
| --- | --- | --- | --- | --- |
| [kindle_basic_4](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_basic_4.json) | 1072×1448 | 1072×1448 | gray_16 | K：KOReader，网络客户端 |
| [kindle_oasis_3](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_oasis_3.json) | 1264×1680 | 1264×1680 | gray_16 | K：KOReader，网络客户端 |
| [kindle_paperwhite_2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_paperwhite_2.json) | 758×1024 | 758×1024 | gray_16 | K：KOReader，网络客户端 |
| [kindle_paperwhite_3](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_paperwhite_3.json) | 1072×1448 | 1072×1448 | gray_16 | K：KOReader，网络客户端 |
| [kindle_paperwhite_5](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_paperwhite_5.json) | 1236×1648 | 1236×1648 | gray_16 | K：KOReader，网络客户端 |
| [kindle_scribe](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/amazon/kindle_scribe.json) | 1860×2480 | 1860×2480 | gray_16 | K：KOReader，网络客户端 |
| [picpak_4_2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/community/picpak_4_2.json) | 400×300 | 400×300 | bwry_4 | P：PicPak BLE Photo v1 |
| [elecrow_crowpanel_579](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/elecrow/crowpanel_579.json) | 792×272 | 792×272 | mono | B：统一固件 BLE 未启用 |
| [epdiy_v7_ed133ut2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/epdiy/epdiy_v7_ed133ut2.json) | 1600×1200 | 1600×1200 | gray_16 | B：统一固件 BLE 未启用 |
| [gooddisplay_esp32_133c02](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/gooddisplay/esp32_133c02.json) | 1200×1600 | 1200×1600 | spectra_6 | A：统一固件 BLE 设置已启用 |
| [kobo_aura_edition_2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_aura_edition_2.json) | 758×1024 | 758×1024 | gray_16 | K：KOReader，网络客户端 |
| [kobo_clara_colour](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_clara_colour.json) | 1072×1448 | 1072×1448 | kaleido3 | K：KOReader，网络客户端 |
| [kobo_clara_hd](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_clara_hd.json) | 1072×1448 | 1072×1448 | gray_16 | K：KOReader，网络客户端 |
| [kobo_libra_2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_libra_2.json) | 1264×1680 | 1264×1680 | gray_16 | K：KOReader，网络客户端 |
| [kobo_libra_colour](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_libra_colour.json) | 1264×1680 | 1264×1680 | kaleido3 | K：KOReader，网络客户端 |
| [kobo_sage](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/kobo/kobo_sage.json) | 1440×1920 | 1440×1920 | gray_16 | K：KOReader，网络客户端 |
| [m5stack_m5paper](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/m5stack/m5paper.json) | 540×960 | 960×540 | gray_16 | B：统一固件 BLE 未启用 |
| [m5stack_papermono](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/m5stack/papermono.json) | 480×800 | 480×800 | gray_4 | A：统一固件 BLE 设置已启用 |
| [m5stack_papers3](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/m5stack/papers3.json) | 540×960 | 960×540 | gray_16 | B：统一固件 BLE 未启用 |
| [paperlesspaper_openpaper_7](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/paperlesspaper/openpaper_7.json) | 480×800 | 800×480 | spectra_6 | B：统一固件 BLE 未启用 |
| [paperlesspaper_openpaper_l](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/paperlesspaper/openpaper_l.json) | 1200×1600 | 1200×1600 | waveshare_e6 | B：统一固件 BLE 未启用 |
| [pimoroni_inky_frame_73](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/pimoroni/inky_frame_73.json) | 800×480 | 800×480 | spectra_6 | I：Pico Inky Frame，尚无 BLE 服务 |
| [pimoroni_inky_frame_73_acep](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/pimoroni/inky_frame_73_acep.json) | 800×480 | 800×480 | inky_7colour | I：Pico Inky Frame，尚无 BLE 服务 |
| [pimoroni_inky_4](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/pimoroni/inky_impression_4.json) | 600×400 | 600×400 | spectra_6 | L：Linux Pi 客户端，无收图 GATT |
| [pimoroni_inky_4_acep](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/pimoroni/inky_impression_4_acep.json) | 640×400 | 640×400 | acep_7colour | L：Linux Pi 客户端，无收图 GATT |
| [remarkable_paper_pro](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/remarkable/paper_pro.json) | 1620×2160 | 1620×2160 | rgb24 | R：reMarkable AppLoad，网络客户端 |
| [remarkable_1](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/remarkable/remarkable_1.json) | 1404×1872 | 1404×1872 | gray_16 | R：reMarkable AppLoad，网络客户端 |
| [remarkable_2](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/remarkable/remarkable_2.json) | 1404×1872 | 1404×1872 | gray_16 | R：reMarkable AppLoad，网络客户端 |
| [seeed_ee02](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/ee02.json) | 1200×1600 | 1200×1600 | spectra_6 | A：统一固件 BLE 设置已启用 |
| [seeed_ee03](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/ee03.json) | 1872×1404 | 1872×1404 | gray_16 | A：统一固件 BLE 设置已启用 |
| [seeed_ee04_73e6](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/ee04_73e6.json) | 800×480 | 800×480 | spectra_6 | A：统一固件 BLE 设置已启用 |
| [seeed_ee04_75](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/ee04_75.json) | 800×480 | 800×480 | mono | A：统一固件 BLE 设置已启用 |
| [seeed_ee05_213_bwry](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/ee05_213_bwry.json) | 250×122 | 128×250 | bwry_4 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1001](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1001.json) | 800×480 | 800×480 | mono | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1001_gray](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1001_gray.json) | 800×480 | 800×480 | gray_4 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1001_gray_legacy](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1001_gray_legacy.json) | 800×480 | 800×480 | gray_4 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1002](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1002.json) | 800×480 | 800×480 | spectra_6 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1003](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1003.json) | 1872×1404 | 1872×1404 | gray_16 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_e1004](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_e1004.json) | 1200×1600 | 1200×1600 | spectra_6 | A：统一固件 BLE 设置已启用 |
| [seeed_reterminal_sticky](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/reterminal_sticky.json) | 480×800 | 480×800 | gray_4 | A：统一固件 BLE 设置已启用；CrossInk 另有 sticky 构建 |
| [seeed_xiao_75](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/xiao_75.json) | 800×480 | 800×480 | mono | T：TRMNL BYOS，无收图 GATT |
| [xiao_epaper_75](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/xiao_epaper_75.json) | 800×480 | 800×480 | mono | B：统一固件 BLE 未启用 |
| [xiao_epaper_75_bwr](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/xiao_epaper_75_bwr.json) | 800×480 | 800×480 | bwr_3 | B：统一固件 BLE 未启用 |
| [xiao_epaper_panel_75_c3](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/seeed/xiao_epaper_panel_75_c3.json) | 800×480 | 800×480 | mono | B：统一固件 BLE 未启用 |
| [soldered_inkplate_10](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/soldered/inkplate_10.json) | 1200×825 | 1200×825 | gray_8 | S：Inkplate 社区固件，无收图 GATT |
| [soldered_inkplate_13spectra](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/soldered/inkplate_13spectra.json) | 1600×1200 | 1600×1200 | spectra_6 | A：统一固件 BLE 设置已启用；社区固件另见 S，原生行宽不同 |
| [soldered_inkplate_6color](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/soldered/inkplate_6color.json) | 600×448 | 600×448 | inky_7colour | S：Inkplate 社区固件，无收图 GATT |
| [trmnl_x](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/trmnl/x.json) | 1872×1404 | 1872×1404 | gray_16 | T：TRMNL BYOS，无收图 GATT |
| [waveshare_photopainter_73](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/photopainter_73.json) | 800×480 | 800×480 | spectra_6 | B：统一固件 BLE 未启用 |
| [waveshare_4_2_bw](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/wave42_bw.json) | 400×300 | 400×300 | mono | W：旧 ESP32 B/W 客户端，无收图 GATT |
| [waveshare_1085g](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/waveshare_1085g.json) | 1360×480 | 1360×480 | bwry_4 | B：统一固件 BLE 未启用 |
| [waveshare_133e6](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/waveshare_133e6.json) | 1200×1600 | 1200×1600 | waveshare_e6 | B：统一固件 BLE 未启用 |
| [waveshare_epaper_73f](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/waveshare_epaper_73f.json) | 800×480 | 800×480 | inky_7colour | B：统一固件 BLE 未启用 |
| [waveshare_esp32_driver_75](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/waveshare/waveshare_esp32_driver_75.json) | 800×480 | 800×480 | mono | B：统一固件 BLE 未启用 |
| [xteink_x3](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x3.json) | 528×792 | 792×528 | mono | X：CrossInk，无收图 GATT |
| [xteink_x3_gray](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x3_gray.json) | 528×792 | 792×528 | gray_4 | X：CrossInk，无收图 GATT |
| [xteink_x4](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x4.json) | 480×800 | 800×480 | mono | B：统一固件 BLE 未启用；CrossInk 路径另见 X |
| [xteink_x4_gray](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x4_gray.json) | 480×800 | 800×480 | gray_4 | X：CrossInk，无收图 GATT |
| [xteink_x4_pro](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x4_pro.json) | 480×800 | 800×480 | mono | X：CrossInk，无收图 GATT |
| [xteink_x4_pro_gray](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/xteink/x4_pro_gray.json) | 480×800 | 800×480 | gray_4 | X：CrossInk，无收图 GATT |
| [note4c_client](https://github.com/dmellok/tesserae/blob/6e16ea402d9d41be8616c73de4cc2b3529c9b43b/hardware/zectrix/note4c.json) | 400×300 | 400×300 | bwry_4 | N：NOTE4C，尚无 BLE |

## 附录 B：固定源码快照

表中的地址用于复查当日证据，后续上游变化不会自动更新本报告。OpenDisplay 的其他 MCU 家族差异来自 canonical 协议的 @targets 合同，本次未逐个下载所有 MCU 固件分支；其完整跨家族实机兼容性仍未验证。CrossPoint generic kind 未给出唯一可追踪固件，保留为未知；封闭系统不宣称已完成厂商固件内部审计。

| 仓库 | 快照 |
| --- | --- |
| dmellok/tesserae | [6e16ea402d9d](https://github.com/dmellok/tesserae/tree/6e16ea402d9d41be8616c73de4cc2b3529c9b43b) |
| dmellok/tesserae-device-firmware | [1e5a1be5b26f](https://github.com/dmellok/tesserae-device-firmware/tree/1e5a1be5b26ffa46fecc87475ee4945292c2c54f) |
| varanu5/picpak-tesserae-client | [539731c3537e](https://github.com/varanu5/picpak-tesserae-client/tree/539731c3537ed68ac2df0e6c29645c2270ea452c) |
| varanu5/zectrix-note4c-devkit-tesserae-client | [7ce23c9c36ab](https://github.com/varanu5/zectrix-note4c-devkit-tesserae-client/tree/7ce23c9c36ab5ccad05cef84111e1af0820634f2) |
| partridgeworks/tesserae.inkyframe | [4a6f16cb1076](https://github.com/partridgeworks/tesserae.inkyframe/tree/4a6f16cb1076549e1cda2e3b2afd33518961c926) |
| ripking/inkplate-tesserae-driver | [688a5839ed12](https://github.com/ripking/inkplate-tesserae-driver/tree/688a5839ed12c63c95cfcceb202988661c277b18) |
| dmellok/CrossInk | [15b2a91a19fe](https://github.com/dmellok/CrossInk/tree/15b2a91a19fee8a0202a62b5cabe62b51d44b42c) |
| partridgeworks/tesserae.remarkable | [c8d07660757f](https://github.com/partridgeworks/tesserae.remarkable/tree/c8d07660757f7c9d9985182f172eb0b66472b977) |
| dmellok/tesserae-opendisplay | [7845fbcc418a](https://github.com/dmellok/tesserae-opendisplay/tree/7845fbcc418a3d553ea4bf5d76e6538b02d497eb) |
| dmellok/tesserae-koreader | [7f191307a57e](https://github.com/dmellok/tesserae-koreader/tree/7f191307a57e3a054e26031e7e525f7808070c85) |
| partridgeworks/tesserae.inkplate | [c26fbeb47648](https://github.com/partridgeworks/tesserae.inkplate/tree/c26fbeb476488e7b6a8c2c60aa93dcf73cbb5dde) |
| dmellok/tesserae-device-pico-bin | [c5e71c9ba5d4](https://github.com/dmellok/tesserae-device-pico-bin/tree/c5e71c9ba5d4a9f58dbd6427d0b2be37fd3d0f64) |
| dmellok/tesserae-device-esp32-bw | [f2f508ad7220](https://github.com/dmellok/tesserae-device-esp32-bw/tree/f2f508ad7220269cdbffb4d0b81211dca8c25512) |
| dmellok/tesserae-device-pi-bin | [0af6224ff4db](https://github.com/dmellok/tesserae-device-pi-bin/tree/0af6224ff4db61f385c2273631f323969caa3b1f) |
| dmellok/tesserae-device-pi-png | [a9adb2188106](https://github.com/dmellok/tesserae-device-pi-png/tree/a9adb2188106a75a27006c8619e3cc332af1263b) |
| dmellok/tesserae-device-circuitpython | [2a4d38d868f0](https://github.com/dmellok/tesserae-device-circuitpython/tree/2a4d38d868f0bc858df68077e68d4b4b8c3a9e3c) |
| usetrmnl/trmnl-firmware | [4ee1b610751e](https://github.com/usetrmnl/trmnl-firmware/tree/4ee1b610751e42135f2c2d55e388f76ab3659cb5) |
| ARPOBOT-BLOOMIN8/eink_canvas_home_assistant_component | [65742327efab](https://github.com/ARPOBOT-BLOOMIN8/eink_canvas_home_assistant_component/tree/65742327efab652e8438171010d2c4d61f96502d) |
| OpenDisplay/Firmware | [6d058329757d](https://github.com/OpenDisplay/Firmware/tree/6d058329757da73f70d452e16ec663b5e694fe8f) |
| OpenDisplay/opendisplay-protocol | [1080d7973414](https://github.com/OpenDisplay/opendisplay-protocol/tree/1080d797341402a96f5240d3c436f0a95c8b2f47) |
| OpenDisplay/py-opendisplay | [48473123053d](https://github.com/OpenDisplay/py-opendisplay/tree/48473123053dd5193fb15b8e7aa486410a7f919a) |
| dmellok/tesserae-device-esp32-bin | [d9f613b78680](https://github.com/dmellok/tesserae-device-esp32-bin/tree/d9f613b786808ffb8785b3b27279622d65f7e3ba) |
| dmellok/tesserae-device-photopainter-7.3-bin | [3d14a899c072](https://github.com/dmellok/tesserae-device-photopainter-7.3-bin/tree/3d14a899c0724484dc10ee5b54b732df2018f46f) |

本次只新增审计文档与来源快照，没有改 App、服务器或任何固件，没有执行刷机、发布、提交或推送。

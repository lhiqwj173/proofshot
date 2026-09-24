# 设计

## 当前事实与模块边界

`D:/code/proofshot/参考水印/` 的三张 JPG 分别为 1080×1440、1279×1706、1080×1440。`D:/code/iosapptest/codemagic.yaml` 的 `ios-personal` 工作流依次运行 `flutter create --platforms=ios`、`flutter pub get`、`flutter build ios --release --no-codesign` 并打包 `Runner.app`。参考项目只有 `lib/main.dart` 计数器，无可复用相机符号。当前仓库无 OpenSpec 基线；本 change 首次增加规格。

## 决策

### D-001 工程及版本

以 Flutter 3.47.1 / Dart 3.13.1 为本地设计基线，生成 iOS 宿主并纳入版本控制，不在每次云构建中覆盖原生工程。Codemagic Flutter 版本同样固定为 3.47.1；若云端缺该版本，按 E-004 升级合同，不静默换 stable。部署目标 iOS 14.0（PhotoKit 有限照片访问从 iOS 14 起可用），设备验证指定 iPhone 11。直接依赖固定为 `camera: 0.12.1`、`geolocator: 14.0.3`、`geocoding: 5.0.0`、`shared_preferences: 2.5.5`；提交 `pubspec.lock`，CI 使用 `flutter pub get --enforce-lockfile`。云编译复制已验证的 Mac mini M2 无签名工作流，保留其 `flutter build ios --release --no-codesign` 和 IPA 打包方法，删除每次构建时的 `flutter create`。不引入 FFmpeg、云服务或整帧 Dart 图像流。

### D-002 相机与生命周期

`lib/camera/camera_coordinator.dart` 为唯一相机状态持有者，使用 `camera` 插件的 `availableCameras`、`CameraController`、`CameraPreview`、`takePicture`、`startVideoRecording`、`stopVideoRecording`、`setFlashMode`。controller 使用 `ResolutionPreset.veryHigh`、`enableAudio: true`、锁定竖屏方向；实际文件低于 1080p 时显式报错。串行化初始化、镜头切换、录制、销毁；异步结果用 generation token 防止过期 controller 回写。`AppLifecycleState.inactive/paused` 关闭闪光和释放 controller；录制中先请求结束并进入处理状态。`resumed` 重新枚举并初始化选中的镜头，未就绪显示状态与重试。系统禁止后台使用相机，不能承诺后台保持硬件会话。为避免 UI 堵塞，不在 Dart 主 isolate 逐帧处理视频。

### D-003 水印模型和几何

一个不可变 `WatermarkSnapshot` 包含 `capturedAt`（本地时区、含偏移的 ISO 8601 字符串）、`timeText=HH:mm`、`dateText=yyyy.MM.dd`、`weekdayText=星期一…星期日`、`locationText`、`customText`、`brandText=水印相机`。自定义字段是单条任意文本，去首尾空格、最多 30 个 Unicode 字素；为空则不显示该行。手动地点最多 40 个 Unicode 字素；空地点禁止拍摄。拍照在按下快门时冻结快照，录像在开始录制时冻结并保持整段一致。时间以设备本地墙钟显示，不宣称防篡改。

预览采用相机画面对应的实际内容矩形，水印通过统一规范化画布坐标布局；输出依据 EXIF/video transform 先转正，再按同一布局合成。以短边为 1080 的参考比例：时间行中心 `x=0.5,y=0.80`，字高约画面短边 `0.14`；日期/星期/地点行中心 `y=0.91`，字高 `0.035`；品牌右下角距右边及下边各 `0.03`；自定义字段中心位于时间上方 `y=0.71`，字高 `0.032`。整体留 3% 安全边距，长地点或字段按可用宽度缩小至 70%，仍不适合则换行（最多两行），禁止截断内容。使用系统中文字体白字、轻微深色阴影，图钉用红色圆点及针杆绘制，避免 emoji 跨平台外观变化。预览与导出共用 Dart 输出的布局常数和原生同等坐标约定；更稳妥的验收是参考图与预览/成品并排目测，并核对成品像素实际包含水印。

### D-004 地点与权限

启动相机时仅请求相机权限；视频第一次录制前请求麦克风权限；需要自动定位时请求 `When In Use`。定位用 `geolocator` 一次性当前位置并请求 `LocationAccuracy.best`；逆地理编码用 `geocoding`，按 `locality`、`subLocality`、`street`（回退 `thoroughfare`，再回退 `name`）拼接非空且不重复的地名，中文 locale `zh_CN`。不加入 `subThoroughfare` 门牌信息。本次拍摄的自动位置必须是最近 60 秒取得的有效坐标并且逆地理编码成功；超时、拒绝、关闭定位或无地名时显式显示“请填写地点”，允许用户手动输入，不将上次自动地点默默沿用。手动地点优先于自动地点，清空后恢复自动模式。权限拒绝属于可预期状态，界面提供设置入口；程序错误通过明确错误状态报告，不吞异常。

### D-005 闪光及镜头

拍照后摄提供 `off/on/auto`，录像后摄提供 `off/torch`；镜头切换后先关闭旧镜头 torch 再初始化新镜头。前摄若插件报告不支持闪光或补光则控制不可用且告知用户；绝不假称屏幕补光为硬件闪光。模式切换和镜头切换在录制中禁用。所有 `CameraException` 保留错误码并显示可执行的重试或权限提示。

### D-006 原生合成及相册事务

`ios/Runner/WatermarkBridge.swift` 暴露 `MethodChannel('proofshot/watermark')` 的 `renderPhoto`、`renderVideo`。传入原件临时绝对路径和 D-003 字段；Swift 校验字段、文件、媒体轨、尺寸和方向。照片用 ImageIO/CoreGraphics 在转正图像上绘制，然后输出 JPEG；视频用 `AVMutableVideoComposition`、`AVVideoCompositionCoreAnimationTool` 将同一静态快照写入每帧，并用 `AVAssetExportSession` 异步导出到新的 `.mp4`；保留音轨并依据 preferredTransform 转正。优先 1080p/30fps 录制和导出，若设备能力不满足则显式报错而非自动降级。导出前确认 H.264/AAC、`.mp4` 组合受支持。仅在合成完成后通过 `PHPhotoLibrary` add-only 权限写入相册；成功后将 `localIdentifier` 与媒体类型、拍摄时间写入 D-008 的本机索引，再删除原件/中间文件。若相册写入成功而索引写入失败，明确提示“已保存到相册，但应用内列表暂不可见”，保留待修复记录，不再次向相册添加。App 重新打开时检测未完成的临时任务并提示恢复；若上次保存回调未确认，显示“保存结果不确定，请先检查相册”，不得自动重复写入。Swift API 错误编码返回 Flutter，UI 显示状态；非法参数在开发环境直接触发断言或抛出明确错误。

桥接入参固定为 `{sourcePath: String, snapshot: {capturedAt,timeText,dateText,weekdayText,locationText,customText,brandText}}`，返回 `{renderedPath: String}`；保存另用 `saveToPhotos`，返回 `{localIdentifier: String}`。字段为空或类型不符、源文件不在应用临时目录、媒体轨缺失均返回明确错误码，不接受任意路径。原生绘制遵循 D-003 的规范化坐标，先把视频源尺寸经 `preferredTransform` 计算为正向包围盒，设 `renderSize` 为该包围盒，合成轨的 layer instruction 应用相对于包围盒原点平移后的 transform；Core Animation 父层与视频层大小相同，并显式转换 UIKit 左上原点与 Core Animation 坐标。导出 preset 用 `AVAssetExportPreset1920x1080`，预检 `.mp4` 兼容性和输出轨；完成后再核查视频尺寸、时长及音轨。照片按 ImageIO 方向标签转正后绘制，输出时重置方向标签。该映射在前摄/后摄、不同物理旋转样片中核对，任何不匹配都是失败。

### D-007 性能、状态与验收

状态为 `uninitialized → requestingPermission → initializing → ready ↔ recording → processing → ready`，另有 `interrupted/error`。只能在 `ready` 拍照或开始录像；`processing` 不允许再次开始录制，但预览可恢复。视频导出在原生后台队列，UI 持续响应；切后台时不尝试持续拍摄，恢复后重新初始化预览并显示处理结果。iPhone 11 真机验收：正常前台恢复 2 秒内预览可交互（排除系统首次权限弹窗及其他 App 占用相机），连续切换前后台 20 次无黑屏或重复初始化；录制 60 秒输出带声视频、水印与照片位置一致；相册中成品内容与预览一致。云编译与静态检查只能证明可构建，硬件、权限和耗时目标必须真机确认。

### D-008 应用内图库与删除

`ios/Runner/WatermarkGallery.swift` 用 PhotoKit/AVKit 提供原生图库页，由相机页“我的水印”按钮打开。仅显示 D-006 保存时登记的 `localIdentifier`：`Library/Application Support/proofshot/media-index.json` 为 UTF-8 JSON，schema `{version:1,items:[{id,kind,capturedAt}]}`，`kind` 仅 `photo|video`，按拍摄时间倒序；索引采用原子写入，未知版本/无效字段明确报错，不扫描用户整个相册，也不保存第二份完整媒体。相机保存只请求 add-only；第一次打开图库时请求 readWrite，接受 authorized 或 limited。Apple PhotoKit 会把应用新建资产自动加入有限访问集合。拒绝/受限时显示权限说明与系统设置入口，保持相机拍摄能力。

图库使用 `PHAsset.fetchAssets(withLocalIdentifiers:)` 查询登记资产，异步按屏幕尺寸请求缩略图；网格只保留可视区域缩略图，不向 Dart MethodChannel 传完整媒体。照片详情用原生滚动/缩放视图，视频通过 `PHImageManager.requestPlayerItem` 和 `AVPlayerViewController` 播放；媒体在 iCloud 且当前不可取得时显示加载或明确错误。列表提供刷新及照片/视频筛选。仅当 readWrite 状态为 authorized 且 ID 查询为空，才判定资产已由用户在系统照片中删除并清理索引；limited 状态查询为空时保留索引并提示调整选择，避免把权限遮蔽误判为已删除。

每次仅删除用户点选且仍在本机索引中的一个资产。先显示应用确认框，说明“将从系统照片删除，若启用 iCloud 照片也可能同步删除”；确认后调用 `PHAssetChangeRequest.deleteAssets` 于 `PHPhotoLibrary.performChanges`，交由系统再次确认。只有 PhotoKit 回调成功且重新查询证实资产不可见才删除索引项；取消、拒绝、错误均保留索引并显示结果。若成功删除后索引原子写入失败，下次刷新将清理失效项。应用不删除其他来源的相册资产，不提供批量删除。

### D-009 相机控制界面

相机取景画面是屏幕主体。顶部以紧凑半透明状态栏承载相机状态、图库和设置入口；底部用半透明控制面板呈现地点、镜头切换、闪光/补光、拍摄模式和快门。快门保持视觉主次，青绿色标示选中或就绪状态，红色仅用于录像状态。模糊效果只应用于控件背景，不处理相机预览或水印图像；界面重排不得改变拍摄、权限、保存及水印输出行为。

## 关键数据流

`CameraPreview → WatermarkSnapshot → 快门/录制 → XFile 临时原件 → MethodChannel 原生合成 → PHPhotoLibrary add-only 保存 → localIdentifier 本机索引 → 成功回执 → 临时文件清理`。图库使用 `本机索引 → PhotoKit 按 ID 查询 → 缩略图/详情/播放 → 用户确认 → PhotoKit 删除 → 索引删除`。失败时停在明确错误状态并保留原件与可重试参数。设置字段经 `shared_preferences` 本机存储；相机和相册数据不上传。

## 取舍及验证对应

相机插件缩短硬件兼容实现；原生离线合成保证保存媒体带水印。代价是视频停止后需等待导出且消耗额外临时空间；录制中显示时长和可用存储不足的明确错误。图库以 PhotoKit 原生视图避免完整媒体往返 Flutter 内存，代价是进入图库时另需相册读写授权。Apply 只检查依赖锁、格式/静态分析及云编译结果，不在本地运行 `flutter test` 或代替用户做真机验收。D-001 用锁文件与 CI 构建核对；D-002/D-005/D-007 的硬件状态、性能由用户真机核对；D-003/D-004 的外观与地点由用户真机核对；D-006/D-008 的媒体成品、浏览和删除由用户真机核对。

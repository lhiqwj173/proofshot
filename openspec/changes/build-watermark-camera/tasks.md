## Execution Contract

protocol: OPENSPEC_EXECUTION
contract_revision: 2
risk: HIGH

objective:
- 在 iPhone 11 上完成参考式水印照片及有声视频，支持日期、时间、地点、自定义字段、闪光/补光、前后摄，并在切回前台后恢复相机；应用内可浏览、播放、单项删除本应用的水印成品。
- 配置可重复的 Codemagic 无签名 iOS IPA 构建。

scope_summary:
- 新建 Flutter iOS 应用、原生 iOS 媒体水印/相册保存/图库桥接、权限、设置、CI 配置；只做本地静态检查与云端编译，最终真机验收由用户完成。

non_goals:
- 后台持续拍摄、实时滚动视频时钟、Android、地图选点、账号/云服务、App Store 发布、其他机型专项适配、浏览或删除非本应用创建的相册资产、批量删除。

allowed_paths:
- `pubspec.yaml`, `pubspec.lock`, `.gitignore`, `analysis_options.yaml`, `codemagic.yaml`
- `lib/**`
- `ios/**`（Flutter 生成的宿主工程、Swift 桥接和必要 Xcode 配置；不提交 Pods、Flutter 临时产物或构建结果）
- `openspec/changes/build-watermark-camera/**`

conditional_paths:
- path: `.metadata`
  only_if: `flutter create --platforms=ios --org com.proofshot .` 生成且 Flutter 工具需要纳入版本控制。
- path: `assets/**`
  only_if: D-003 的参考式视觉布局需要本地静态资源；不得复制参考照片作为应用内容。

forbidden:
- 修改 `D:/code/iosapptest` 或将其 Git 历史复制进本仓库。
- 用未带水印的原件冒充成品、使用旧自动地点代替本次有效地点、在后台持续占用相机。
- 添加 FFmpeg、第三方云服务、整帧 Dart 视频处理或未固定版本的依赖。
- 在本地运行 `flutter test`，或要求实施方替用户完成 iPhone 11 真机功能验收。

global_invariants:
- 相机和媒体处理只有单个活动操作；拍摄快照在拍照时/录像开始时冻结，预览和导出使用同一字段与几何约定。
- 媒体完成合成并成功写入相册后才报告成功或清理原始临时文件；失败必须有明确错误与恢复路径。
- 地点为空不得保存；麦克风权限不足不得开始承诺有声的录像；不支持的硬件闪光选项不可选。
- 图库仅按本应用保存的 localIdentifier 查询；删除须用户确认和 PhotoKit 成功回执，取消或失败不得移除本机索引。
- 文件读写显式指定 UTF-8；二进制媒体使用二进制 API，不适用文本编码。预期外状态抛出明确错误，UI 仅将系统权限拒绝等可预期结果转成可见提示。

escalate_if:
- E-001 proposal/design/spec 发生冲突。
- E-002 实现需新增非平凡技术或产品决策。
- E-003 仓库事实与记录的工程或版本事实冲突。
- E-004 关键依赖、API、运行时与 REF-003/006/008/009 不一致。
- E-005 必须扩大未授权业务范围。
- E-006 Review 要求修改 proposal/design/spec。
- E-007 已批准约束无法同时满足。
- E-008 必要验证命令失效且无法唯一确定等价替代。
- E-011 单 finding 已达到快速修复失败上限。

validation_plan:
  task:
  - Dart 当前修改运行 `dart format --output=none --set-exit-if-changed lib` 与 `flutter analyze`；Swift 当前修改在最终云编译集中验证。不得运行本地单元测试。
  apply_final:
  - `flutter pub get --enforce-lockfile`
  - `flutter analyze`
  - Codemagic `ios-personal` 工作流成功且生成非空 IPA；无法访问账户时记录未验证项，不把本地分析等同云编译通过。
  review:
  - `openspec validate build-watermark-camera --strict --json --no-interactive`
  - 对照 Requirement 与实现只读审查；iPhone 11 真机矩阵交给用户执行，实施方不替用户勾选真机结果。
  archive:
  - `openspec validate build-watermark-camera --strict --json --no-interactive`
  - 确认 task 与 Review 状态、Git 工作区和待提交文件。

convergence_policy:
  max_failed_fast_repairs_per_finding: 2

## Tasks

- [x] 1.1 创建 Flutter iOS 工程与锁定依赖。
  - 依据：云编译 Requirement；D-001；REF-002/003/008。
  - 读取：`design.md` D-001；参考工程 `pubspec.yaml`、`codemagic.yaml`；本仓库文件清单。
  - 修改：`pubspec.yaml`、`pubspec.lock`、`analysis_options.yaml`、`.gitignore`、`ios/**`、`lib/main.dart`；运行 `flutter create --platforms=ios --org com.proofshot .` 并保留 iOS 宿主工程，固定四项直接依赖版本及 iOS 14.0 目标。
  - 约束：不覆盖参考工程；生成文件中不可带占位 bundle ID；只提交源文件。
  - 验证：`flutter pub get --enforce-lockfile`、`flutter analyze`；预期依赖锁定一致、空壳应用无分析错误。

- [x] 2.1 实现单一水印数据模型、格式和预览布局。
  - 依据：参考式水印 Requirement；时间及地点来源 Requirement；D-003；REF-001。
  - 读取：`design.md` D-003；`specs/watermark-camera/spec.md` 前两项；`lib/main.dart`。
  - 修改：`lib/watermark/watermark_snapshot.dart`、`lib/watermark/watermark_overlay.dart`；实现本地时间/中文星期、长度限制、固定画布比例与长文本换行。
  - 约束：空地点抛出明确输入错误；视频快照后不可变；图钉用绘制图形。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期无格式或静态分析错误；周日/跨日/长文本实效由用户真机核对。

- [x] 2.2 实现地点解析、权限状态和本机设置。
  - 依据：时间及地点来源 Requirement；D-004；REF-008。
  - 读取：`design.md` D-004；`lib/watermark/watermark_snapshot.dart`；`pubspec.yaml`。
  - 修改：`lib/location/location_service.dart`、`lib/settings/watermark_settings.dart`、`ios/Runner/Info.plist`；使用 60 秒有效期、中文地名、手动地点优先、本机持久化及设置入口。
  - 约束：定位拒绝/超时/编码失败显式呈现；无地点不可生成快照；仅需 When In Use 权限。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期无格式或静态分析错误；新鲜/过期/拒绝/手动覆盖/重启持久化由用户真机核对。

- [x] 3.1 实现相机预览、模式及生命周期状态机。
  - 依据：拍照录像 Requirement；前后台恢复 Requirement；D-002/D-007；REF-003/004。
  - 读取：`design.md` D-002/D-007；`lib/main.dart`；`specs/watermark-camera/spec.md` 相机和恢复场景。
  - 修改：`lib/camera/camera_coordinator.dart`、`lib/camera/camera_screen.dart`、`lib/main.dart`、`ios/Runner/Info.plist`；单一 controller、异步 generation、前后台释放/重建、相机和麦克风权限。
  - 约束：只能 ready 捕获；录制中切后台先请求结束；错误状态可重试，不发生旧 controller 覆盖新会话。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期无格式或静态分析错误；生命周期行为由用户真机核对。

- [x] 3.2 增加前后镜头、闪光与补光 UI。
  - 依据：拍照录像闪光镜头 Requirement；D-005；REF-005。
  - 读取：`design.md` D-005；`lib/camera/camera_coordinator.dart`、`camera_screen.dart`。
  - 修改：`lib/camera/camera_coordinator.dart`、`lib/camera/camera_screen.dart`；按镜头和模式提供合法选项，切镜头先关 torch。
  - 约束：前摄不支持硬件时禁用控制；录制中禁止镜头与模式切换；保留 CameraException 错误码。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期无格式或静态分析错误；镜头和闪光行为由用户真机核对。

- [x] 4.1 实现照片原生合成桥接。
  - 依据：参考式水印 Requirement；前后台恢复与错误 Requirement；D-003/D-006；REF-001/007。
  - 读取：`design.md` D-003/D-006；`lib/watermark/watermark_snapshot.dart`；`ios/Runner/AppDelegate.swift`。
  - 修改：`ios/Runner/WatermarkBridge.swift`、`ios/Runner/AppDelegate.swift`、`lib/media/watermark_bridge.dart`；注册 channel、严格校验参数、ImageIO 转正、CoreGraphics 绘制、JPEG 临时成品。
  - 约束：只处理有效绝对临时路径；前摄方向和预览一致；尺寸异常显式报错；桥接返回成品路径或结构化错误。
  - 验证：检查 `renderPhoto` 参数、方向处理及桥接注册符号；Swift 编译由 task 6.1 云编译统一核对，成品由用户真机验收。

- [x] 4.2 实现视频原生合成与异步导出。
  - 依据：参考式水印 Requirement；拍照录像 Requirement；D-003/D-006；REF-006。
  - 读取：`design.md` D-003/D-006；`ios/Runner/WatermarkBridge.swift`；`lib/media/watermark_bridge.dart`。
  - 修改：`ios/Runner/WatermarkBridge.swift`、`lib/media/watermark_bridge.dart`；视频旋转归一、静态冻结水印、保留音轨、支持性检查、MP4 异步导出和错误回调。
  - 约束：无音轨视为录制失败；不阻塞 Flutter UI；导出失败保留原件并提示；不静默降低预设质量。
  - 验证：检查 `renderVideo`、音轨、transform、导出回调符号；Swift 编译由 task 6.1 云编译统一核对，成品由用户真机验收。

- [x] 4.3 实现相册 add-only 写入、媒体索引、原件清理与恢复。
  - 依据：前后台恢复与错误 Requirement；应用内水印媒体图库 Requirement；D-006/D-008；REF-007/011。
  - 读取：`design.md` D-006/D-008；`ios/Runner/WatermarkBridge.swift`；`lib/media/watermark_bridge.dart`。
  - 修改：`ios/Runner/WatermarkBridge.swift`、`ios/Runner/WatermarkGallery.swift` 中媒体索引、`lib/media/watermark_bridge.dart`、`lib/camera/camera_screen.dart`、`ios/Runner/Info.plist`；请求 add-only、写入相册、登记 localIdentifier、成功后清理、失败保留并在重开时发现待恢复任务。
  - 约束：未写入相册绝不提示成功；相册已写入但索引失败时报告两种状态并修复索引，不重复保存；临时任务与 UTF-8 JSON 索引原子写入。
  - 验证：检查 add-only 权限、索引 schema、写入顺序和错误回调符号；Swift 编译由 task 6.1 云编译统一核对，恢复行为由用户真机验收。

- [x] 4.4 实现“我的水印”图库浏览与播放。
  - 依据：应用内水印媒体图库 Requirement；D-008；REF-007/011。
  - 读取：`design.md` D-008；`ios/Runner/WatermarkGallery.swift` 媒体索引；`lib/camera/camera_screen.dart`。
  - 修改：`ios/Runner/WatermarkGallery.swift`、`ios/Runner/AppDelegate.swift`、`lib/camera/camera_screen.dart`、`ios/Runner/Info.plist`；新增 `openGallery` channel 方法，图库入口、readWrite/limited 授权、网格缩略图、筛选、照片详情、视频播放、刷新和空状态。
  - 约束：只查询索引中的 ID，不把完整媒体传到 Dart；有限权限导致不可见时保留索引；照片云端下载失败有明确状态。
  - 验证：检查 `openGallery`、`PHAsset.fetchAssets`、`PHImageManager`、`AVPlayerViewController` 和授权分支；Swift 编译由 task 6.1 云编译统一核对，操作由用户真机验收。

- [x] 4.5 实现单项删除与索引同步。
  - 依据：应用内水印媒体图库 Requirement；D-008；REF-012。
  - 读取：`design.md` D-008；`ios/Runner/WatermarkGallery.swift` 图库和索引符号。
  - 修改：`ios/Runner/WatermarkGallery.swift`；应用确认框、PhotoKit 系统删除确认、成功回调后的索引删除、取消/失败保留、刷新清理外部已删资产。
  - 约束：只允许删除索引中的单项；确认文案说明系统相册及 iCloud 同步影响；权限受限时不得把不可见误判为已删除。
  - 验证：检查 `PHAssetChangeRequest.deleteAssets` 被包在 `performChanges` 中，且索引更新只在成功分支；Swift 编译由 task 6.1 云编译统一核对，确认与取消路径由用户真机验收。

- [x] 5.1 完成参考图并排外观核对及布局修正。
  - 依据：参考式水印 Requirement；D-003；REF-001。
  - 读取：三张参考 JPG；`lib/watermark/watermark_overlay.dart`；原生绘制符号。
  - 修改：仅 `lib/watermark/watermark_overlay.dart`、`ios/Runner/WatermarkBridge.swift` 中布局常数及绘制；按参考图的上下层级、字号比例、安全边距进行静态比对修正。
  - 约束：不得仅修预览或仅修成品；不得复制竞品图形标识。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期静态检查通过；最终截图/样片并排核对由用户真机完成。

- [x] 5.2 完成返回前台性能和故障恢复。
  - 依据：前后台恢复 Requirement；iPhone 11 验收 Requirement；D-002/D-007；REF-004。
  - 读取：`design.md` D-002/D-007；`lib/camera/camera_coordinator.dart`；`ios/Runner/WatermarkBridge.swift`。
  - 修改：`lib/camera/camera_coordinator.dart`、`lib/camera/camera_screen.dart`；完善中断/占用/重试、处理状态和预览快速恢复。
  - 约束：不在后台继续占用摄像头；导出任务和恢复会话互不阻塞；重复生命周期事件不产生重复 controller。
  - 验证：`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`；预期静态检查通过；恢复计时由用户按下方真机矩阵完成。

- [ ] 6.1 配置云编译并完成分层静态验证。
  - 依据：云编译 Requirement；D-001；REF-002/009。
  - 读取：参考 `codemagic.yaml`；本仓库 `pubspec.yaml`、`pubspec.lock`、`ios/`。
  - 修改：`codemagic.yaml`、必要时 `.gitignore`；保留 `ios-personal` 流程，移除每次生成 host，锁文件安装、无签名构建、非空 IPA 打包和 artifacts。
  - 约束：不能把无签名 IPA 宣称可直接装真机；不能提交签名凭证。
  - 验证：`flutter pub get --enforce-lockfile`、`dart format --output=none --set-exit-if-changed lib`、`flutter analyze`，Codemagic 工作流日志与非空 IPA；预期静态和编译全部通过。
  - 本次验证：依赖锁定、Dart 格式与静态分析、Codemagic YAML 和 Info.plist XML 解析均通过；Codemagic 云构建为 `NOT_RUN`（当前目录没有 Git 仓库或远端，且没有可用的 Codemagic 项目会话），Swift 编译和非空 IPA 未验证；未运行 `flutter test`。

## 用户真机验收矩阵（iPhone 11，用户执行）

无签名 IPA 需签名后才能安装；以下结果由用户确认，实施方不得以模拟器或云编译代替。

1. 安装已签名构建，记录 iOS 版本；相机授权后检查竖屏预览与三张参考图的水印层级、字号、边距。
2. 分别用后摄和前摄拍照，检查后摄闪光关/开/自动、前摄不可用提示；在系统照片中查看水印像素、方向与前摄镜像。
3. 后摄开启补光录制 60 秒，前摄录制 60 秒，检查声音、时间/地点快照、成片水印、方向、停止后的补光状态。
4. 拒绝自动定位后输入手动地点，输入长自定义字段，重启应用，检查字段保存、换行及空地点阻止拍摄。
5. 打开“我的水印”，分别检查照片缩略图/详情、视频缩略图/播放、照片/视频筛选和刷新；拒绝相册读写权限时检查说明和设置入口。
6. 对一张照片和一段视频分别取消删除、确认删除；确认后在系统照片核对已删除，其他媒体保持；在系统照片直接删除一项后返回图库刷新。
7. 录制中切后台再返回，检查应用显示处理中或失败、不假装继续录制；常规切换其他应用再返回 20 次并逐次计时，正常返回 2 秒内预览和快门可用。
8. 拒绝麦克风或相册权限、模拟保存/导出错误时，检查错误可见、不会显示假成功、待恢复任务不会被无声丢弃。

# FlClash 通用客户端壳

[English](README.md)

基于 [FlClash](https://github.com/chen08209/FlClash) 和
[Mihomo](https://github.com/MetaCubeX/mihomo) 的 Flutter 通用客户端源码，支持
Android、Linux、Windows 和 macOS。示例名称为 **HarborProxy**，应用 ID 为
`com.example.harborproxy`。

包含桌面 Core 生命周期与 IPC、Android VPN、订阅配置、路由管理、自适应导航和
本地诊断；测试中的请求与凭据均为合成样例。

## 构建

使用 Flutter **3.44.8**、Go **1.26.8** 和目标平台的原生工具链；Android 使用
JDK 17、NDK r28c，并设置 `ANDROID_NDK`。Core 源码已包含在 `core/Clash.Meta`，
无需初始化 Git 子模块。

```sh
python3 tool/download_geodata.py
flutter pub get
dart setup.dart linux
# 也可选择 android、windows 或 macos，在对应平台构建
```

GeoData 从 MetaCubeX 的公开 Release 下载，校验附件 SHA-256，并将来源与哈希写入
`assets/data/GEODATA.lock`；数据库不提交到 Git。平台依赖与测试命令见
[英文构建说明](README.md#build)。

分发衍生版本时
自行配置品牌与部署输入；仓库不提供发布上传流程或签名凭据。

## 许可证

[GPLv3](LICENSE)，保留上游版权和第三方许可声明。

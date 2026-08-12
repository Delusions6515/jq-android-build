# jq-android-build

用 GitHub Actions 编译 jq for Android，产出**静态链接、自包含**的二进制
（`--with-oniguruma=builtin` + `LDFLAGS=-all-static`，oniguruma 内置，无动态依赖），
可在普通 Android 上直接运行，无需 termux。

构建方法参考 jqlang/jq 官方静态构建方式与 termux-packages 的 jq 包。

## 产物

```
jq-1.8.2-android-arm64/
└── bin/
    └── jq        # 静态 ELF, readelf -d 无 NEEDED
```

## 使用

### GitHub Actions

Actions → Build jq for Android → Run workflow：

- `jq_version`：`latest`（默认）/ 完整版本如 `1.8.2`
- `target_arch`：`all`（默认）/ `arm64` / `arm` / `x64` / `ia32`
- `ndk_version`：留空用 runner 默认 NDK / `latest`（脚本解析最新稳定版）/ 具体版本如 `r29`

### 本地构建

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk
./build.sh                            # 最新 release + arm64
JQ_VERSION=1.8.2 TARGET_ARCH=arm ./build.sh
```

## 环境变量

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `JQ_VERSION` | `latest` / 完整版本 | `latest` |
| `TARGET_ARCH` | `arm64` / `arm` / `x64` / `ia32` | `arm64` |
| `ANDROID_SDK_VERSION` | Android API 级别 | `24` |
| `ANDROID_NDK_HOME` | NDK 路径（未设置时自动找 Actions 预装） | - |
| `OUT_DIR` | 输出目录 | `./out` |

## 构建要点

- `--with-oniguruma=builtin`：oniguruma 内置，产物单个 ELF
- `LDFLAGS="-static -s"`：静态链接 + strip
- jq 依赖简单，通常不需要补丁；`patches/<版本线>/termux/` 按需对照 termux 移植

## 维护

- jq 出新版本：手动触发构建即可，新版本自动产出 artifact
- 构建报错：看日志 `[!]` 警告，对照 termux-packages 更新补丁
- 产物在 Actions artifact，仓库本身只存脚本，很轻

## 许可

jq 本体为 MIT License；内含 decNumber 组件（ICU License）。
补丁（如有）来源 termux-packages（GPL-3.0 仓库）的 jq 包。

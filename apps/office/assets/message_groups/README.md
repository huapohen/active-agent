# 消息分组图标

手机分组面板使用授权图标库素材。透明 PNG 均为原始图标库 SVG 通过 `rsvg-convert -w 96 -h 96` 渲染，未重绘路径，没有使用飞书产品标识或真实账户截图。运行时缩放并按选中状态着色。

- `chat-circle-text.png`：Phosphor Icons，MIT；来源与原始 Git blob SHA / SHA-256 见 `phosphor-source.json`，许可证见 `PHOSPHOR_LICENSE.txt`。
- Remix Icon **v4.6.0**，Apache-2.0；来源与原始 Git blob SHA / SHA-256 见 `sources.json`，许可证见 `REMIXICON_LICENSE.txt`。`source_tree_sha` 表示该版本源码树，不是实现提交号。
- Solar / 480 Design：CC BY 4.0，https://creativecommons.org/licenses/by/4.0/ 。作者来源及转换说明见 `SOLAR_ATTRIBUTION.md`。
- Tabler Icons / Paweł Kuna：MIT，https://github.com/tabler/tabler-icons 。原始许可证全文见 `TABLER_LICENSE.txt`。
- Solar 与 Tabler 的逐 asset 映射、原始 Iconify collection Git blob SHA、JSON/SVG body/PNG SHA-256 见 `supplemental-sources.json`，原始 collection 内容核验 Git blob SHA 后才提取。Tabler 许可证下载也单独校验 Git blob SHA。

| 当前控件 | 实际 app asset / 图标 | 来源 |
| --- | --- | --- |
| 消息 | `chat-circle-text.png` | Phosphor |
| 未读 | `solar-chat-round-unread-linear.png` | Solar |
| 标记 | `tabler-flag-3.png` | Tabler |
| @我 | `at-line.png` | Remix v4.6.0 |
| 单聊 | Flutter `Icons.person_outline` | Material Icons，Apache-2.0；现有 Flutter 字体资产 |
| 群组 | Flutter `Icons.group_outlined` | Material Icons，Apache-2.0；现有 Flutter 字体资产 |
| 云文档 | `file-cloud-line.png` | Remix v4.6.0 |
| 话题 | `tabler-message-2.png` | Tabler |
| 已完成 | `solar-chat-round-check-linear.png` | Solar |
| 编辑分组 | `list-settings-line.png` | Remix v4.6.0 |

旧版 Remix `chat-unread-line.png`、`flag-line.png`、`user-line.png`、`group-line.png`、`feedback-line.png`、`chat-check-line.png` 保留原路径和原始来源记录，防止开发过程旧 bundle 的资源引用失效；当前映射以上表为准。

下载内容逐项核验 Git blob SHA 后才转换。运行时图标尺寸与颜色由 `officeMessageGroupGraphic` 和手机分组管理按钮控制，PNG 提供图形路径透明度。

这些是具有相同用途的授权图标库素材，不能据此声明与飞书的全部图标轮廓逐像素一致。

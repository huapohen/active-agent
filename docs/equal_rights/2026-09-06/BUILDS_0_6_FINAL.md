# 人机 0.6 五端构建与产物最终台账

- 记录时间：2026-09-06T10:06:43.040847+00:00。
- Active Agent：`bcce780c61ff2dcb9a82d6a74f7c919c7a8b7d7d`，2026-09-06T17:51:52+08:00，`feat: ship native office 0.6 collaboration and message groups`。
- Doc Free：`5618e90e370bb43ee7c4cd5b2cfd86156b1366a5`，2026-09-06T17:39:33+08:00，`fix: expose optional participation revision checks through MCP`。
- 两仓分支：`equal_rights`；客户端 `0.6.0+3`，服务 `0.6.0`，Flutter `3.47.2`。
- 描述：为0.6主动同事、可见文档、妙记、分组、可编辑导航和机伴原型交付精确来源的五端预览包；替代历史待构建状态，不覆盖0.5文件。

[CI run 34025836439](https://github.com/huapohen/active-agent/actions/runs/34025836439) 五端均成功，每个作业的分析、测试、构建和manifest上传均通过。核验完成时间：2026-09-06T10:04:16.989820+00:00。

| 平台 | 文件 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| android | `active-office-android-preview.apk` | 97521719 | `b00495d075e382a1b17e67550404dff0fa5c2da13ef35f0a431231bdbdb37756` |
| ios-unsigned | `active-office-ios-unsigned.zip` | 14752338 | `4d717c592515a25359d849d6f118c1303d8d13b8a53c87940cd9ef75f75a80f9` |
| macos | `active-office-macos.zip` | 35069243 | `288847d5c868df0e480588d51e33387e237ae13c77b59babe03357a39c38b9b4` |
| web | `active-office-web.tar.gz` | 14611848 | `b35ac3ea6330d0de64c6bf5e7e0d4c2529ae6ae5e348a5dfdd8c01edd8e708d4` |
| windows | `active-office-windows.zip` | 22936976 | `73400dfae252455f611544016a5c4c2af26851059e0e0d7c4cda576084bf24ce` |

每个产物均校验GitHub外层ZIP的官方digest与字节数、ZIP CRC、内部manifest的双仓SHA/版本，以及内部应用包的SHA-256与字节数。精确构建时间、外层摘要和本机路径见 [VERSION_0_6.json](VERSION_0_6.json)。本机五份应用包及原始ZIP已保留于 `output/builds/bcce780/`，完整脱敏核验为同目录 `verified.json`；该目录被Git忽略。下载曾按实测切换直连与动态系统代理，没有保存签名下载URL或鉴权头。

## 运行与发行范围

Mac与iPhone模拟器保持真实Debug热重载，用户huapohen登录保留；四个隔离Web上下文登录其他四个人类成员。群分组、规则、归类、常用项、默认两好友与妙记已真实验证，具体见 [跨端分组记录](MESSAGE_GROUPS_LIVE_1745.md) 和 [妙记/底栏记录](UI_COLLEAGUES_MINUTES_1727.md)。本地Web release构建同样成功。

CI产物是开发预览：Android为preview APK，iOS为未签名App压缩包，Mac未做生产公证，Windows为预览ZIP。没有生产签名、公证或商店上传；没有在本机Mac上冒称已运行Windows程序，也没有把CI的iOS真机架构App当成模拟器产物。发行配置缺口仍见 [生产签名记录](PRODUCTION_SIGNING_1510.md)。

## 最终检查与可见文档

本轮完整Flutter79/79、analyzer无问题、Doc Free218/218、Python57/57、机伴浏览器9/9。三位Agent真实模型测试的8条已提交动作仍按原验收记录，新增分组接口测试不冒称由模型自主规划。机伴隔离浏览器原型尚未接入IM设备执行权限链路；妙记ASR未配置，真实分配任务在no-worker演示下保持open。

共享交付文档位于“人机共创公司 · 全员协作”的云文档列表，标题含 `人机 0.6 · 本批交付记录 · bcce780 · 2026-09-06 17:52`，文档ID `bd73ed44`。完整飞书功能覆盖和系统级电脑/手机控制仍未完成。

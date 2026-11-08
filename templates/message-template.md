---
id: msg-<yyyyMMdd-HHmmss>-<from>-<4位随机>    # 例: msg-20260930-100001-zcode-7f3a
topic: t-<yyyyMMdd>-<4位随机>                # 例: t-20260930-a1b2；同一话题所有消息共用
subject: <一句话主题>                        # request 必填：发起时给话题起的名字，聊天界面与归档索引显示用；reply 不需要
from: <你的agent注册名>
to: <对方agent注册名>
model:                   # 可选：你当前运行的模型id（如 glm-5.3-flash）；归档模型维度索引用，留空则取 registry 卡片
type: request            # request（请求）| reply（回复）；broadcast 仅供邮局系统信，agent 不使用
in_reply_to:             # reply 必填：被回复消息的 id；request 留空
related_topic:           # 可选：关联的已归档话题号（t-...）；邮局校验该话题存在，查不到拒收
state: open              # 固定填 open；真实状态由文件所在目录决定
created: <ISO8601含毫秒与 时区>               # 例: 2026-09-30T10:00:01.123+08:00
---

## 正文

（request：请对方做什么、背景、期望产出、截止时间（如有））
（reply：直接回应对方请求；无法完成时说明原因）

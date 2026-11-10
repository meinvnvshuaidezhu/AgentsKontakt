# i18n.zh-CN.psd1 - mailbox CLI Chinese display templates (zh-CN).
#
# This file is DATA - the single place to edit wording. Scripts never change
# for wording. Rules:
#   - Keys are stable semantic ids (the mapping table); never rename them.
#   - {0}{1}... are argument placeholders, reused/ordered freely per language.
#   - Every value keeps its English status token inline in [brackets] so the
#     documented token (DELIVERED / RETURNED / ...) stays visible to agents
#     and tests.
#   - Multi-line mail bodies are line arrays; '' = one blank line.
#   - English fallback templates live at the call sites: a missing, corrupt
#     or incomplete table silently falls back to today's English output.
#     New language = copy this file to config\i18n.<lang>.psd1 and translate;
#     select with the AK_LANG environment variable (default zh-CN).

@{
  # ---- .status sidecar status codes -> display names ----
  'status.DISPATCHING' = '派送中 [DISPATCHING]'
  'status.DELIVERED'   = '已送达 [DELIVERED]'
  'status.RETURNED'    = '已退回 [RETURNED]'
  'status.REPLIED'     = '已回信 [REPLIED]'
  'status.STALLED'     = '滞留 [STALLED]'
  'status.IN_PROGRESS' = '处理中 [IN_PROGRESS]'
  'status.ARCHIVED'    = '已归档 [ARCHIVED]'
  'status.REJECTED'    = '已拒收 [REJECTED]'

  # ---- send.ps1 ----
  'send.already-taken'   = '已被取走或不存在（already taken or gone）'
  'send.err-not-outbox'  = '文件不在已注册的 outbox 内：{0}（file is not inside a registered outbox）'
  'send.returned.bad-envelope'            = '已退回 [RETURNED]（信封缺字段 {0} / bad envelope: missing {0}）'
  'send.returned.invalid-type'            = '已退回 [RETURNED] {0}（type 不合法 / invalid type）'
  'send.returned.request-no-subject'      = '已退回 [RETURNED] {0}（request 缺 subject / request without subject）'
  'send.returned.subject-too-long'        = '已退回 [RETURNED] {0}（subject 超长 / subject too long）'
  'send.returned.to-equals-from'          = '已退回 [RETURNED] {0}（to 等于 from / to equals from）'
  'send.returned.id-not-ascii'            = '已退回 [RETURNED] {0}（id 含非 ASCII 字符 / id not ascii）'
  'send.returned.spoofed'                 = '已退回 [RETURNED] {0}（来源仿冒 / spoofed from）'
  'send.returned.recipient-not-registered' = '已退回 [RETURNED] {0}（收件人未注册 / recipient not registered）'
  'send.returned.target-inbox-missing'    = '已退回 [RETURNED] {0}（收件方 inbox 不存在 / target inbox missing）'
  'send.returned.duplicate-id'            = '已退回 [RETURNED] {0}（目标信箱已存在同 id / duplicate id）'
  'send.returned.related-malformed'       = '已退回 [RETURNED] {0}（related_topic 格式不合法 / related_topic malformed）'
  'send.returned.related-not-found'       = '已退回 [RETURNED] {0}（归档中未找到关联话题 / related topic not found）'
  'send.queued-busy'     = '已排队 [QUEUED] {0} -> {1}（收件方忙，其会话结束后会来领取 / recipient busy; will pick up when its session ends）'
  'send.returned.all-channels-failed' = '已退回 [RETURNED] {0} -> {1}（所有唤醒通道均失败 / all notify channels failed）'
  'send.delivered'       = '已送达 [DELIVERED] {0} -> {1}'
  'send.bounce.body'     = @('你的 outbox 信件被邮局退回。', '', 'id: {0}', 'reason: {1}', '', '正本在你自己的 sent 区（状态 已退回 [RETURNED]）。修复问题后重新交寄。')
  'send.allfailed.body'  = @('信件无法投递：所有唤醒通道都失败了。', '', 'id: {0}', '收件人: {1}', '', '不会自动重试。请检查收件方卡片（wake 链路），修复后重新交寄。')
  'send.receipt.body'    = @('已投递给 {0}。', '', 'id: {1}', '追踪：读取 sent 区正本旁的 .status 侧车文件，或运行 scripts\mail-status.ps1 -Id {1}')

  # ---- claim.ps1 ----
  'claim.already-claimed' = '已被认领或不存在（already claimed or gone）'
  'claim.err-not-inbox'   = '文件不在已注册的 inbox 内（file is not inside a registered inbox）'
  'claim.claimed'         = '已认领 [CLAIMED] {0}（by {1}）'

  # ---- mail-check.ps1 ----
  'mailcheck.not-registered' = 'MAILBOX: agent 未注册：{0}（agent not registered）'
  'mailcheck.no-pending'     = 'MAILBOX: {0} 无待处理信件（no pending mail）'
  'mailcheck.pending-count'  = 'MAILBOX: {1} 有 {0} 封待处理信件（pending message(s)）'
  'mailcheck.new'            = '  新信 [NEW]   {0}  from={1}  topic={2}  type={3}'
  'mailcheck.claim-hint'     = '           -> 请先认领（claim it first）: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File "{0}"'
  'mailcheck.claimed'        = '  已认领 [CLAIMED] {0}  from={1}  topic={2}  type={3}（已被认领，直接处理 / already claimed, handle it）'

  # ---- progress.ps1 ----
  'progress.not-found'      = 'progress: 找不到消息：{0}（message not found）'
  'progress.not-processing' = 'progress: 消息不在 processing 目录，请先认领（not in a processing folder, claim it first）'
  'progress.ok'             = '心跳 [PROGRESS] {0}'

  # ---- mail-status.ps1 ----
  'mailstatus.usage'    = '用法：mail-status -Id <msg-id> | -Topic <t-...> | -Agent <name>（usage）'
  'mailstatus.no-match' = '没有匹配的消息（no matching message）'
  'mailstatus.stage.archived' = '已归档 [ARCHIVED]（已回信/已结案）'
  'mailstatus.stage.pending'  = '待领取 [PENDING]（inbox，未认领）'
  'mailstatus.stage.working'  = '处理中 [WORKING]（processing）'
  'mailstatus.stage.inflight' = '在途 [IN-FLIGHT]（sent 正本）'
  'mailstatus.heartbeat' = ' | 心跳（{0} 分钟前）: {1}'

  # ---- close.ps1 ----
  'close.denied' = '已拒绝 [DENIED] topic {0}（结案人 {1} 不是发起人 {2}）'
  'close.closed' = '已结案 [CLOSED] topic {0} gathered={1} -> {2}{3}'
  'close.locked' = '（已锁定）'
  'close.denied.body' = @('结案请求被拒绝。', '', 'topic: {0}', '结案人: {1}', '发起人: {2}', '', '只有话题发起人可以结案并归档一个话题。')

  # ---- archive-query.ps1 ----
  'aq.no-archive' = '尚无归档（no archive yet）'
  'aq.usage1'     = '用法：archive-query.ps1 [-Agent name] [-With name] [-From name] [-To name] [-Model id]'
  'aq.usage2'     = '                 [-Date yyyy-MM-dd] [-Month yyyy-MM] [-Year yyyy] [-Topic t-...] [-Keyword text] [-Message]'
  'aq.usage3'     = '索引文件：archive\index.md（全局）、archive\<agent>\_index.md（按 agent）'
  'aq.agents'     = '已注册 agent：{0}'
  'aq.matched'    = '共匹配 {0} 个话题（topic(s) matched）'

  # ---- init.ps1 ----
  'init.root'    = '根目录 (Root)   : {0}'
  'init.agents'  = '已注册 (Agents) : {0}'
  'init.agents.none' = '（尚未注册任何 agent / none registered yet）'
  'init.created' = '已创建 (Created): registry/ mailboxes/<agent>/{inbox,processing,outbox,sent,notes} archive/ logs/ templates/ post/{manifest,cold}'
  'init.wake1'   = '唤醒 (Wake)     : 没有 wake 命令的 agent 使用 PULL 模式（自行运行 mail-check 查信）；'
  'init.wake2'   = '                  有 wake 的 agent 使用 PUSH 模式（send.ps1 投递后立即拉起其 CLI；'
  'init.wake3'   = '                  watch.ps1 是后备常驻邮差）。'
  'init.next'    = '下一步 (Next)   : 常驻运行 scripts\watch.ps1（后备方式），或打开 dashboard\dashboard.html'

  # ---- core\route.ps1 ----
  'route.returned-exhausted'  = '已退回 [RETURNED] {0} - attempts exhausted（唤醒次数耗尽）({1})'
  'route.queued-busy'         = '收件方忙-已排队 [QUEUED-BUSY] {0}'
  'route.exhausted-busy'      = '存活方活跃-暂缓退回 [DEFERRED] {0} - attempts exhausted but recipient active（唤醒次数已耗尽，但收件方仍在活动，退回暂缓）'
  'route.claimed-no-dispatch' = '已认领-不派发 [CLAIMED(no-dispatch)] {0}'
  'route.dispatched'          = '已派发 [DISPATCHED] {0} -> {1} ({2})'
  'route.notify-failed'       = '派发失败 [NOTIFY-FAILED] {0} - all channels failed（所有通道失败，已重新排队到 inbox / requeued to inbox）'
  'route.deadletter.body'     = @('邮局在 {0} 次唤醒无人应答后，停止重派这封信。', '', 'id: {1}', '收件人: {2}', 'topic: {3}', '', '收件方副本已删除；正本仍在你的 sent 区（状态 已退回 [RETURNED]）。可选：戳一下收件方、用新 id 重发，或结案话题。')
  'route.mailto.subject'      = 'AgentsKontakt 新信: {0}'
  'route.mailto.body'         = @('你的 AgentsKontakt 信箱有新信。', '', 'id: {0}', 'topic: {1}', 'from: {2}', 'file: {3}', '', '请阅读共享根目录下的 PROTOCOL.md 并处理这条消息。')

  # ---- core\integrity.ps1 ----
  'integrity.no-manifest' = 'integrity: 尚无台账（no manifest yet）'
  'integrity.unchanged'   = 'integrity: 归档无变化（签名匹配 / sig match）'
  'integrity.tamper'      = '篡改 [TAMPER] {0} | {1} | 哈希不在台账（hash not in manifest）'
  'integrity.summary'     = 'integrity 完整性: topics={0} files={1} tampered={2} cached={3}'

  # ---- core\feed.ps1 ----
  'feed.following' = '--- 跟随中（Ctrl+C 停止 / following）---'

  # ---- core\watch.ps1 ----
  'watch.stalled.body' = @('这封在途信件在整个滞留观察窗口内没有任何动静。', '', 'id: {0}', '收件人: {1}', '最近活动: {2}', '', '可选：戳一下收件方、重发，或结案话题。无论后续如何，正本都留在你的 sent 区。')

  # ---- scripts\registry-audit.ps1 ----
  'audit.badroot'                    = '数据根下没有 registry\ 目录：{0}（no registry\ directory under data root）'
  'audit.no-cards'                   = 'registry\ 里没有卡片（no cards in registry）'
  'audit.fail-todo'                  = '字段 {0} 残留 TODO [FAIL]'
  'audit.fail-placeholder'           = '字段 {0} 仍含占位符 [FAIL]'
  'audit.fail-liveness'              = '缺 liveness 申报，视同未注册完（missing liveness declaration）[FAIL]'
  'audit.fail-pull-missing'          = '缺 pull 字段——PULL 兜底人人必配（PROTOCOL §0 第 4 条纪律）[FAIL]'
  'audit.fail-pull-task-missing'     = 'pull 登记的计划任务不存在：{0}——卡片与现实不符 [FAIL]'
  'audit.fail-channel-unimplemented' = '信道 {0} 未实装——禁止注册邮局敲不响的信道 [FAIL]'
  'audit.fail-webhook-dead'          = 'webhook 门铃无监听：{0}:{1}（挂在会话里的门铃已死或从未常驻）[FAIL]'
  'audit.fail-webhook-badurl'        = 'webhook 门铃 URL 无法解析：{0} [FAIL]'
  'audit.fail-exec-script-missing'   = 'exec 适配器脚本不存在：{0} [FAIL]'
  'audit.warn-mailto-noconfig'       = 'mailto 已注册但 config\smtp.json 不存在 [WARN]'
  'audit.warn-never-dispatched'      = 'wake 登记了 {0}，但 journal 从无 "DISPATCH ... via {0}"——该信道从未真正敲响过 [WARN]'
  'audit.warn-no-poll-journal'       = 'PULL 模式但 journal 无 POLL 记录——兜底没在跑？[WARN]'
  'audit.warn-pull-task-result'      = '计划任务 {0} 存在但最近运行结果非 0：{1} [WARN]'
  'audit.warn-noschtasks'            = '非 Windows 环境，无法核验计划任务 {0} [WARN]'
  'audit.warn-unknown-channel'       = 'wake 链含无法识别的信道：{0} [WARN]'
  'audit.exempt'                     = 'pull=none 豁免（{0}）[EXEMPT]'
  'audit.skip-infra'                 = '系统基建卡片，免 pull 要求 [SKIP]'
  'audit.pull-ok'                    = 'pull 兜底在跑（task={0}）[OK]'
  'audit.ok'                         = '全部检查通过 [OK]'
  'audit.summary'                    = '审计完成：fail={0} warn={1}'
}

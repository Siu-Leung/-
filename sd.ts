/**
 * TeleBox 标准插件格式
 * 零外部依赖，使用原生 fetch 避免模块加载失败
 */

export const name = 'sd';
export const command = 'sd';
export const description = '加强版索敌：支持多人、限时、自定义API';
export const version = '2.0.0';

// 存储全局索敌状态：Map<目标ID, 目标信息>
const targetMap = new Map<number, { username: string; expireAt: number | null; timer?: NodeJS.Timeout | any }>();

// 默认火力 API 池
const apiList: string[] = [
  'https://yyapi.a1aa.cn/api.php?level=max',
  'https://yyapi.a1aa.cn/api.php?level=max',
  'https://yyapi.a1aa.cn/api.php?level=max'
];

/**
 * 核心：获取随机嘴臭内容 (使用原生 fetch，零依赖)
 */
async function getFirepower(): Promise<string> {
  const url = apiList[Math.floor(Math.random() * apiList.length)];
  try {
    const res = await fetch(url, { method: 'GET' });
    const text = await res.text();
    
    // 尝试解析为 JSON，兼容多种 API 格式
    try {
      const data = JSON.parse(text);
      return (data.data?.text || data.text || data.content || text).trim();
    } catch {
      // 如果不是 JSON，直接返回纯文本
      return text.trim() || '（词库卡壳了...）';
    }
  } catch (err) {
    return '网络延迟，放你一马。';
  }
}

/**
 * .sd 命令的主执行逻辑
 */
export async function execute(ctx: any) {
  const text = ctx.message?.text || '';
  const args = text.split(/\s+/);
  const subCommand = args[1]?.toLowerCase();
  const replyTo = ctx.message?.reply_to_message;

  if (!subCommand) {
    return ctx.reply('⚠️ 用法：\n• .sd on [分钟] (需回复目标)\n• .sd off (需回复目标)\n• .sd list (查看名单)\n• .sd api [url]\n• .sd multi (说明)');
  }

  switch (subCommand) {
    case 'on': {
      // 必须通过回复来锁定目标
      if (!replyTo) return ctx.reply('❌ 错误：请回复你想对线的那个人！');
      const target = replyTo.from;
      if (!target || target.is_bot) return ctx.reply('❌ 无法对机器人或未知用户开火。');

      const minutes = args[2] ? parseInt(args[2], 10) : null;
      
      // 清除可能存在的旧定时器
      if (targetMap.has(target.id)) {
        const oldData = targetMap.get(target.id);
        if (oldData?.timer) clearTimeout(oldData.timer);
      }

      let timer: any;
      if (minutes && !isNaN(minutes)) {
        timer = setTimeout(() => {
          targetMap.delete(target.id);
          ctx.reply(`⏰ 对 [${target.first_name}] 的 ${minutes} 分钟限时轰炸已结束。`);
        }, minutes * 60 * 1000);
      }

      targetMap.set(target.id, {
        username: target.username || target.first_name,
        expireAt: minutes ? Date.now() + minutes * 60 * 1000 : null,
        timer
      });

      await ctx.reply(`🔥 已锁定目标: ${target.first_name}${minutes ? ` (${minutes} 分钟)` : ' (永久)'}`);
      break;
    }

    case 'off': {
      // 停止对特定用户的索敌
      if (!replyTo) return ctx.reply('❌ 请回复被锁定的用户以停止索敌。');
      const targetId = replyTo.from?.id;
      if (targetId && targetMap.has(targetId)) {
        const data = targetMap.get(targetId);
        if (data?.timer) clearTimeout(data.timer);
        targetMap.delete(targetId);
        await ctx.reply('🏳️ 已停火，放他一马。');
      } else {
        await ctx.reply('❓ 该用户并未在名单中。');
      }
      break;
    }

    case 'list': {
      if (targetMap.size === 0) return ctx.reply('🕊️ 现世安稳，没有任何索敌目标。');
      let listMsg = '📝 **当前开火名单：**\n';
      targetMap.forEach((val, key) => {
        const timeStr = val.expireAt ? ` [剩 ${Math.round((val.expireAt - Date.now()) / 60000)} 分]` : ' [持续]';
        listMsg += `• <code>${key}</code> | <b>${val.username}</b>${timeStr}\n`;
      });
      await ctx.replyWithHTML(listMsg);
      break;
    }

    case 'api': {
      const newUrl = args[2];
      if (!newUrl?.startsWith('http')) return ctx.reply('❌ 请提供有效的 API URL（包含 http/https）。');
      apiList.push(newUrl);
      await ctx.reply(`✅ 弹药库已扩容！当前共有 ${apiList.length} 条线路。`);
      break;
    }

    case 'multi': {
      await ctx.reply('💡 **多人模式说明：**\n你可以对群内多个人分别回复 `.sd on`，我会并行记录所有人的 ID，谁发消息就怼谁。');
      break;
    }

    default:
      await ctx.reply('❌ 未知指令。请使用 .sd 查看帮助。');
  }
}

/**
 * 监听所有文本消息，触发索敌反击
 * 注意：TeleBox 加载器通常会自动挂载名为 onMessage 或 listen 的导出函数
 */
export async function onMessage(ctx: any) {
  const senderId = ctx.from?.id;
  const messageId = ctx.message?.message_id;

  // 如果发送消息的人在我们的锁定名单中
  if (senderId && targetMap.has(senderId)) {
    const content = await getFirepower();
    const targetData = targetMap.get(senderId);
    
    // 构造回复文本：有 username 就 @ 出来，没有就直接加粗回复
    const replyText = targetData?.username 
      ? `@${targetData.username} <b>${content}</b>` 
      : `<b>${content}</b>`;

    try {
      await ctx.replyWithHTML(replyText, {
        reply_to_message_id: messageId
      });
    } catch (err) {
      console.error('SD 回复失败:', err);
    }
  }
}

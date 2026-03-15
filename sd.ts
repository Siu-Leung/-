import { Context } from 'telegraf';
import axios from 'axios';

/**
 * 插件基础信息
 */
export const name = '极限索敌';
export const command = 'sd';
export const help = `跟我对线？
用法：
• .sd on [时间] - 开启索敌 (需回复目标)
• .sd off - 停止索敌 (需回复目标)
• .sd list - 查看当前名单
• .sd api [url] - 添加自定义API`;

// 存储索敌名单
const targetMap = new Map<number, { username: string; expireAt: number | null; timer?: NodeJS.Timeout }>();

// 默认高火力 API 池
let apiList: string[] = [
  'https://yyapi.a1aa.cn/api.php?level=max',
  'https://api.shadiao.pro/chp',
  'https://v1.alapi.cn/api/soul'
];

/**
 * 获取嘴臭文本
 */
async function getInsult(): Promise<string> {
  const url = apiList[Math.floor(Math.random() * apiList.length)];
  try {
    const res = await axios.get(url, { timeout: 3000 });
    const data = res.data;
    const text = typeof data === 'string' ? data : (data.data?.text || data.text || data.content);
    return text ? text.trim() : '词库暂时断货了。';
  } catch {
    return '网络延迟，放你一马。';
  }
}

/**
 * .sd 命令处理主入口 (TeleBox 规范使用 execute)
 */
export const execute = async (ctx: Context) => {
  // @ts-ignore
  const text = ctx.message?.text || '';
  const args = text.split(/\s+/);
  const subCommand = args[1]?.toLowerCase();

  // @ts-ignore
  const replyTo = ctx.message?.reply_to_message;

  switch (subCommand) {
    case 'on': {
      if (!replyTo) return ctx.reply('❌ 请回复一个你想索敌的用户！');
      const target = replyTo.from;
      if (!target || target.is_bot) return ctx.reply('❌ 无法索敌机器人或无效用户。');

      const minutes = args[2] ? parseInt(args[2]) : null;
      
      // 清除旧的计时器防止重叠
      if (targetMap.has(target.id)) {
        const old = targetMap.get(target.id);
        if (old?.timer) clearTimeout(old.timer);
      }

      let timer: NodeJS.Timeout | undefined;
      if (minutes) {
        timer = setTimeout(() => {
          targetMap.delete(target.id);
          ctx.reply(`⏰ 对 [${target.first_name}] 的限时索敌已结束。`);
        }, minutes * 60 * 1000);
      }

      targetMap.set(target.id, {
        username: target.username || target.first_name,
        expireAt: minutes ? Date.now() + minutes * 60 * 1000 : null,
        timer
      });

      await ctx.reply(`🔥 已锁定目标: ${target.first_name}${minutes ? ` (${minutes}分钟)` : ' (永久)'}`);
      break;
    }

    case 'off': {
      if (!replyTo) return ctx.reply('❌ 请回复被锁定的用户以停止索敌。');
      const targetId = replyTo.from?.id;
      if (targetId && targetMap.has(targetId)) {
        const data = targetMap.get(targetId);
        if (data?.timer) clearTimeout(data.timer);
        targetMap.delete(targetId);
        await ctx.reply('🏳️ 已停止对该用户的索敌。');
      } else {
        await ctx.reply('❓ 该用户不在索敌名单中。');
      }
      break;
    }

    case 'list': {
      if (targetMap.size === 0) return ctx.reply('🕊️ 当前没有正在索敌的目标。');
      let msg = '📝 **当前索敌名单：**\n';
      targetMap.forEach((v, k) => {
        const rest = v.expireAt ? ` [剩${Math.round((v.expireAt - Date.now()) / 60000)}分]` : ' [持续]';
        msg += `• <code>${k}</code> | <b>${v.username}</b>${rest}\n`;
      });
      await ctx.replyWithHTML(msg);
      break;
    }

    case 'api': {
      const url = args[2];
      if (!url?.startsWith('http')) return ctx.reply('❌ 请输入有效的 API URL。');
      apiList.push(url);
      await ctx.reply('✅ 自定义 API 已添加。');
      break;
    }

    default:
      await ctx.reply(help);
  }
};

/**
 * 监听所有消息 (TeleBox 规范使用 onMessage)
 */
export const onMessage = async (ctx: Context) => {
  // @ts-ignore
  const senderId = ctx.from?.id;
  // @ts-ignore
  const messageId = ctx.message?.message_id;

  if (senderId && targetMap.has(senderId)) {
    const insult = await getInsult();
    const data = targetMap.get(senderId);
    
    const replyText = data?.username ? `@${data.username} <b>${insult}</b>` : `<b>${insult}</b>`;

    try {
      await ctx.replyWithHTML(replyText, {
        reply_to_message_id: messageId
      });
    } catch (e) {
      console.error('SD Error:', e);
    }
  }
};

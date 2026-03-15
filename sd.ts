import { Context, NarrowedContext } from "telegraf";
import { Message, Update } from "telegraf/types";
import axios from "axios";

/**
 * 插件信息
 */
export const name = "极限索敌 (SD-Ultra)";
export const command = "sd";
export const description = "多目标对线、自定义 API、定时炸弹。";
export const usage = 
  "\n• .sd on [时间] - 开启(需回复)\n• .sd off - 停止对该用户索敌(需回复)\n• .sd list - 查看名单\n• .sd api [url] - 添加新弹药库";

// 目标库：Map<userId, { username: string, expireAt: number | null, timer?: NodeJS.Timeout }>
const targetMap = new Map<number, { username: string; expireAt: number | null; timer?: NodeJS.Timeout }>();

// 弹药库 (内置多条高火力线路)
let apiList: string[] = [
  "https://yyapi.a1aa.cn/api.php?level=max",      // 默认最强线路
  "https://api.shadiao.pro/chp",                // 阴阳怪气专用
  "https://v1.alapi.cn/api/soul",               // 毒舌鸡汤
  "https://api.uomg.com/api/rand.qinghua"       // 这种时候发情话也是一种嘲讽
];

/**
 * 核心：火力输出 (随机从 API 获取内容)
 */
async function getFirepower(): Promise<string> {
  const url = apiList[Math.floor(Math.random() * apiList.length)];
  try {
    const res = await axios.get(url, { timeout: 3000 });
    const data = res.data;
    // 兼容多种 API 返回格式
    const content = (typeof data === 'string' ? data : (data.data?.text || data.text || data.content));
    return content ? content.trim() : "（子弹卡壳了...）";
  } catch {
    return "算你命大，我的网络抽风了。";
  }
}

/**
 * 主指令逻辑
 */
export async function handler(ctx: NarrowedContext<Context, Update.MessageUpdate>) {
  const message = ctx.message as Message.TextMessage;
  const args = message.text.split(/\s+/);
  const subCommand = args[1]?.toLowerCase();

  switch (subCommand) {
    case "on": {
      // 开启逻辑：必须回复某人
      if (!message.reply_to_message) return ctx.reply("❌ 错误：请回复你想对线的那个人！");
      const target = message.reply_to_message.from;
      if (!target || target.is_bot) return ctx.reply("❌ 无法对机器人或未知用户开火。");

      const minutes = args[2] ? parseInt(args[2]) : null;
      
      // 如果已经锁定了该用户，先清除旧的定时器
      if (targetMap.has(target.id)) {
        const oldData = targetMap.get(target.id);
        if (oldData?.timer) clearTimeout(oldData.timer);
      }

      let timer: NodeJS.Timeout | undefined;
      if (minutes) {
        timer = setTimeout(() => {
          targetMap.delete(target.id);
          ctx.reply(`⏰ 时间到，对 [${target.first_name}] 的限时轰炸已结束。`);
        }, minutes * 60 * 1000);
      }

      targetMap.set(target.id, {
        username: target.username || target.first_name,
        expireAt: minutes ? Date.now() + minutes * 60 * 1000 : null,
        timer
      });

      await ctx.reply(`🔥 锁定目标: ${target.first_name}${minutes ? ` (持续 ${minutes} 分钟)` : " (直到天荒地老)"}`);
      break;
    }

    case "off": {
      // 停止逻辑：回复谁就停谁
      const targetId = message.reply_to_message?.from?.id;
      if (targetId && targetMap.has(targetId)) {
        const data = targetMap.get(targetId);
        if (data?.timer) clearTimeout(data.timer);
        targetMap.delete(targetId);
        await ctx.reply("🏳️ 已停火，放他一马。");
      } else if (!message.reply_to_message && targetMap.size > 0) {
        // 如果直接发 .sd off 且没回复，给出提示，或者直接清空所有？
        await ctx.reply("⚠️ 请回复特定用户以停止索敌，或使用其他手段清空。");
      } else {
        await ctx.reply("❓ 该用户并未在名单中。");
      }
      break;
    }

    case "list": {
      if (targetMap.size === 0) return ctx.reply("🕊️ 现世安稳，没有任何索敌目标。");
      let listMsg = "📝 **当前开火名单：**\n";
      targetMap.forEach((val, key) => {
        const timeStr = val.expireAt ? ` [剩 ${Math.round((val.expireAt - Date.now()) / 60000)} 分]` : " [持续]";
        listMsg += `• <code>${key}</code> | <b>${val.username}</b>${timeStr}\n`;
      });
      await ctx.replyWithHTML(listMsg);
      break;
    }

    case "api": {
      const newUrl = args[2];
      if (!newUrl?.startsWith("http")) return ctx.reply("❌ 请提供有效的 API URL。");
      apiList.push(newUrl);
      await ctx.reply(`✅ 弹药库已扩容！当前共有 ${apiList.length} 条线路。`);
      break;
    }

    default:
      await ctx.reply(`可用指令: ${usage}`);
  }
}

/**
 * 监听消息：实现全自动回怼
 */
export async function onText(ctx: NarrowedContext<Context, Update.MessageUpdate>) {
  const message = ctx.message as Message.TextMessage;
  const senderId = message.from?.id;

  // 核心逻辑：只要发送者在 Map 里，就立刻反击
  if (senderId && targetMap.has(senderId)) {
    const content = await getFirepower();
    const targetData = targetMap.get(senderId);
    
    const replyText = targetData?.username 
      ? `@${targetData.username} <b>${content}</b>` 
      : `<b>${content}</b>`;

    try {
      await ctx.replyWithHTML(replyText, {
        reply_to_message_id: message.message_id
      });
    } catch (err) {
      console.error("火力输出失败:", err);
    }
  }
}

// 时间格式化工具函数（issue #28）
// 提取 ThreadCard.formatTime 与 SearchPage.formatTime 的公共实现
// 相对时间格式化：刚刚 / X 分钟前 / X 小时前 / X 天前 / YYYY-MM-DD
// M29：分级阈值与数值计算提取为纯函数 relativeTimeBucket（时钟经参数注入，可确定性测试）

import { getResourceString } from './ResourceUtil';

/** 相对时间分级类别 */
export type RelativeTimeKind = 'now' | 'minutes' | 'hours' | 'days' | 'date';

/** 相对时间分级结果（M29 纯函数返回值） */
export interface RelativeTimeBucket {
  kind: RelativeTimeKind;
  /** minutes/hours/days 档的展示数值（now/date 档无值） */
  value?: number;
}

/**
 * 相对时间分级纯函数（阈值判断与数值计算，独立于时钟与 UI 资源）
 * 阈值：<60s 刚刚 / <3600s 分钟前 / <86400s(1天内) 小时前 / >=86400s(1天外) 准确时间
 *
 * @param timestamp Unix 时间戳（秒）
 * @param nowSec 当前时间（秒），由调用方注入
 * @returns 分级结果
 */
export function relativeTimeBucket(timestamp: number, nowSec: number): RelativeTimeBucket {
  const diff: number = nowSec - timestamp;
  if (diff < 60) {
    return { kind: 'now' };
  } else if (diff < 3600) {
    return { kind: 'minutes', value: Math.floor(diff / 60) };
  } else if (diff < 86400) {
    return { kind: 'hours', value: Math.floor(diff / 3600) };
  }
  return { kind: 'date' };
}

/**
 * 格式化准确时间（1天外使用）：
 * 同年显示 MM-DD HH:mm，跨年显示 YYYY-MM-DD HH:mm
 */
function formatExactDateTime(timestamp: number, nowMs: number): string {
  const date: Date = new Date(timestamp * 1000);
  const nowDate: Date = new Date(nowMs);
  const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
  const day: string = date.getDate().toString().padStart(2, '0');
  const hours: string = date.getHours().toString().padStart(2, '0');
  const minutes: string = date.getMinutes().toString().padStart(2, '0');
  if (date.getFullYear() === nowDate.getFullYear()) {
    return `${month}-${day} ${hours}:${minutes}`;
  }
  return `${date.getFullYear()}-${month}-${day} ${hours}:${minutes}`;
}

/**
 * 格式化相对时间（1天内显示刚刚/分钟前/小时前，超过1天显示准确时间）
 * 必须在组件 build() 或生命周期内调用（依赖 getContext() 解析 $r 资源）
 *
 * @param timestamp Unix 时间戳（秒）
 * @returns 格式化后的时间字符串；timestamp <= 0 或非有限数（NaN/Infinity）时返回空串
 */
export function formatRelativeTime(timestamp: number): string {
  // 防御 NaN/Infinity：NaN <= 0 为 false（Code_Wiki 附录 #98 同类陷阱），
  // 漏过守卫后 diff 全比较为 false，落入日期分支渲染出 "NaN-NaN-NaN"
  if (!Number.isFinite(timestamp) || timestamp <= 0) {
    return '';
  }

  const nowMs: number = Date.now();
  const bucket: RelativeTimeBucket = relativeTimeBucket(timestamp, nowMs / 1000);
  switch (bucket.kind) {
    case 'now':
      return getResourceString($r('app.string.just_now'));
    case 'minutes':
      // ?? 0 兜底 value 的可选类型；minutes 档恒有值，不影响输出
      return (bucket.value ?? 0) + getResourceString($r('app.string.minutes_ago'));
    case 'hours':
      return (bucket.value ?? 0) + getResourceString($r('app.string.hours_ago'));
    case 'days':
    case 'date':
      return formatExactDateTime(timestamp, nowMs);
  }
}

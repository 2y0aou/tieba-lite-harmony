// 本地贴吧屏蔽管理：持久化已屏蔽贴吧列表，推荐流自动过滤，设置页可查看与解除

import { AppStorageManager } from '../data/AppStorage';
import { StringPrefs } from '../data/PreferenceKeys';
import { Logger } from './Logger';

const TAG: string = 'BlockManager';
const MAX_BLOCKED_FORUMS: number = 200;

export class BlockManager {
  private static loaded: boolean = false;
  private static blockedForums: string[] = [];

  static async load(): Promise<string[]> {
    try {
      const storage: AppStorageManager = AppStorageManager.getInstance();
      await storage.ensureReady();
      const raw: string = await storage.getString(StringPrefs.BLOCKED_FORUMS.key, StringPrefs.BLOCKED_FORUMS.defaultValue);
      const parsed: Object = JSON.parse(raw) as Object;
      const list: string[] = [];
      if (Array.isArray(parsed)) {
        for (let i = 0; i < parsed.length; i++) {
          const item: Object = parsed[i] as Object;
          if (typeof item === 'string') {
            const trimmed: string = item.trim();
            if (trimmed.length > 0 && list.indexOf(trimmed) < 0) {
              list.push(trimmed);
            }
          }
        }
      }
      BlockManager.blockedForums = list;
      BlockManager.loaded = true;
      return list.slice();
    } catch (err) {
      Logger.warn(TAG, `[BlockManager] load failed: ${(err as Error).message}`);
      BlockManager.loaded = true;
      return BlockManager.blockedForums.slice();
    }
  }

  static getCachedBlockedForums(): string[] {
    return BlockManager.blockedForums.slice();
  }

  static isForumBlocked(forumName: string): boolean {
    const clean: string = forumName.trim();
    if (clean.length === 0) {
      return false;
    }
    return BlockManager.blockedForums.indexOf(clean) >= 0;
  }

  static async blockForum(forumName: string): Promise<void> {
    const clean: string = forumName.trim();
    if (clean.length === 0) {
      return;
    }
    if (!BlockManager.loaded) {
      await BlockManager.load();
    }
    if (BlockManager.blockedForums.indexOf(clean) >= 0) {
      return;
    }
    const next: string[] = [clean];
    for (let i = 0; i < BlockManager.blockedForums.length && next.length < MAX_BLOCKED_FORUMS; i++) {
      next.push(BlockManager.blockedForums[i]);
    }
    BlockManager.blockedForums = next;
    await BlockManager.save();
  }

  static async unblockForum(forumName: string): Promise<void> {
    const clean: string = forumName.trim();
    if (!BlockManager.loaded) {
      await BlockManager.load();
    }
    BlockManager.blockedForums = BlockManager.blockedForums.filter((name: string) => name !== clean);
    await BlockManager.save();
  }

  static async clearAll(): Promise<void> {
    BlockManager.blockedForums = [];
    BlockManager.loaded = true;
    await BlockManager.save();
  }

  private static async save(): Promise<void> {
    try {
      const storage: AppStorageManager = AppStorageManager.getInstance();
      await storage.ensureReady();
      await storage.setString(StringPrefs.BLOCKED_FORUMS.key, JSON.stringify(BlockManager.blockedForums));
    } catch (err) {
      Logger.warn(TAG, `[BlockManager] save failed: ${(err as Error).message}`);
    }
  }
}

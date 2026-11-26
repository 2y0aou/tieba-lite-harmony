import { AppStorageManager } from '../data/AppStorage';
import { StringPrefs } from '../data/PreferenceKeys';

export class BrowseHistoryItem {
  tid: number = 0;
  title: string = '';
  forumName: string = '';
  authorName: string = '';
  authorAvatar: string = '';
  viewedAt: number = 0;

  constructor(
    tid: number,
    title: string,
    forumName: string,
    authorName: string,
    authorAvatar: string,
    viewedAt: number
  ) {
    this.tid = tid;
    this.title = title;
    this.forumName = forumName;
    this.authorName = authorName;
    this.authorAvatar = authorAvatar;
    this.viewedAt = viewedAt;
  }
}

class StoredBrowseHistoryItem {
  tid?: number;
  title?: string;
  forumName?: string;
  authorName?: string;
  authorAvatar?: string;
  viewedAt?: number;
}

const BROWSE_HISTORY_KEY: string = StringPrefs.BROWSE_HISTORY.key;
const BROWSE_HISTORY_LIMIT: number = 200;

export function parseBrowseHistory(raw: string, limit: number): BrowseHistoryItem[] {
  const result: BrowseHistoryItem[] = [];
  try {
    const stored: Object[] = JSON.parse(raw) as Object[];
    for (let i = 0; i < stored.length && i < limit; i++) {
      const item: StoredBrowseHistoryItem = stored[i] as StoredBrowseHistoryItem;
      if (item.tid !== undefined && item.tid > 0) {
        result.push(new BrowseHistoryItem(
          item.tid,
          item.title === undefined ? '' : item.title,
          item.forumName === undefined ? '' : item.forumName,
          item.authorName === undefined ? '' : item.authorName,
          item.authorAvatar === undefined ? '' : item.authorAvatar,
          item.viewedAt === undefined ? 0 : item.viewedAt
        ));
      }
    }
  } catch (err) {
    return [];
  }
  return result;
}

export class BrowseHistoryManager {
  static async load(): Promise<BrowseHistoryItem[]> {
    const storage: AppStorageManager = AppStorageManager.getInstance();
    const raw: string = await storage.getString(BROWSE_HISTORY_KEY, '[]');
    return parseBrowseHistory(raw, BROWSE_HISTORY_LIMIT);
  }

  static async record(item: BrowseHistoryItem): Promise<void> {
    if (item.tid <= 0) {
      return;
    }
    const current: BrowseHistoryItem[] = await BrowseHistoryManager.load();
    const next: BrowseHistoryItem[] = [item];
    for (let i = 0; i < current.length; i++) {
      if (current[i].tid !== item.tid) {
        next.push(current[i]);
      }
      if (next.length >= BROWSE_HISTORY_LIMIT) {
        break;
      }
    }
    await AppStorageManager.getInstance().setString(BROWSE_HISTORY_KEY, JSON.stringify(next));
  }

  static async remove(tid: number): Promise<void> {
    const current: BrowseHistoryItem[] = await BrowseHistoryManager.load();
    const next: BrowseHistoryItem[] = [];
    for (let i = 0; i < current.length; i++) {
      if (current[i].tid !== tid) {
        next.push(current[i]);
      }
    }
    await AppStorageManager.getInstance().setString(BROWSE_HISTORY_KEY, JSON.stringify(next));
  }

  static async clear(): Promise<void> {
    await AppStorageManager.getInstance().setString(BROWSE_HISTORY_KEY, '[]');
  }
}

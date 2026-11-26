// 表情资源管理（issue #74 + v8 新版贴吧高清表情升级）
// 1. 常用 51 个新版高清贴吧表情（image_emoticon1..50 + image_emoticon89）打包为本地 rawfile .webp，离线秒出
// 2. 其余新版贴吧扩展表情（image_emoticon61..101 / 125..137 等）走 HTTPS tb2.bdstatic.com 官方 CDN
// 3. 遇到无法识别的自定义表情 ID 时由 UI 降级为 [表情描述] 文本，避免纯表情楼层变空白

/** 表情信息 */
export class EmoticonInfo {
  /** 表情 id（如 image_emoticon25） */
  id: string = '';
  /** 表情名（如 滑稽） */
  name: string = '';
}

/**
 * 表情管理器
 * 提供 name ↔ id 映射 + 新版表情 ResourceStr 获取 + #(表情名) 标记构造
 */
export class EmoticonManager {
  /** 官方客户端表情 HTTPS CDN（支持全部 image_emoticon61..137 新版扩展表情） */
  private static readonly CDN_BASE: string = 'https://tb2.bdstatic.com/tb/editor/images/client/';
  /** 网页经典表情 HTTPS CDN（i_fXX 系列兜底） */
  private static readonly FACE_CDN_BASE: string = 'https://tb2.bdstatic.com/tb/editor/images/face/';

  /** 表情名列表（与 IDS 一一对应：保留全部经典常用 + 补充新版贴吧热门表情） */
  private static readonly NAMES: string[] = [
    '呵呵', '哈哈', '吐舌', '啊', '酷', '怒', '开心', '汗', '泪', '黑线',
    '鄙视', '不高兴', '真棒', '钱', '疑问', '阴险', '吐', '咦', '委屈', '花心',
    '呼~', '笑眼', '冷', '太开心', '滑稽', '勉强', '狂汗', '乖', '睡觉', '惊哭',
    '生气', '惊讶', '喷', '爱心', '心碎', '玫瑰', '礼物', '彩虹', '星星月亮', '太阳',
    '钱币', '灯泡', '茶杯', '蛋糕', '音乐', 'haha', '胜利', '大拇指', '弱', 'OK',
    '沙发', '手纸', '香蕉', '便便', '药丸', '红领巾', '蜡烛', '三道杠',
    '笑尿', '挖鼻', '犀利', '小红脸', '懒得理', '勉强笑', '爱心心', '心碎了',
    '吃瓜', '喝茶', '暗中观察', '狗头', '笑哭', '破防', '点赞', '菜狗',
    '无语', '小丑', '流汗', '奥特曼'
  ];

  /** 表情 id 列表（与 NAMES 一一对应） */
  private static readonly IDS: string[] = [
    'image_emoticon1', 'image_emoticon2', 'image_emoticon3', 'image_emoticon4', 'image_emoticon5',
    'image_emoticon6', 'image_emoticon7', 'image_emoticon8', 'image_emoticon9', 'image_emoticon10',
    'image_emoticon11', 'image_emoticon12', 'image_emoticon13', 'image_emoticon14', 'image_emoticon15',
    'image_emoticon16', 'image_emoticon17', 'image_emoticon18', 'image_emoticon19', 'image_emoticon20',
    'image_emoticon21', 'image_emoticon22', 'image_emoticon23', 'image_emoticon24', 'image_emoticon25',
    'image_emoticon26', 'image_emoticon27', 'image_emoticon28', 'image_emoticon29', 'image_emoticon30',
    'image_emoticon31', 'image_emoticon32', 'image_emoticon33', 'image_emoticon34', 'image_emoticon35',
    'image_emoticon36', 'image_emoticon37', 'image_emoticon38', 'image_emoticon39', 'image_emoticon40',
    'image_emoticon41', 'image_emoticon42', 'image_emoticon43', 'image_emoticon44', 'image_emoticon45',
    'image_emoticon46', 'image_emoticon47', 'image_emoticon48', 'image_emoticon49', 'image_emoticon50',
    'image_emoticon77', 'image_emoticon78', 'image_emoticon79', 'image_emoticon80',
    'image_emoticon81', 'image_emoticon82', 'image_emoticon83', 'image_emoticon84',
    'image_emoticon61', 'image_emoticon62', 'image_emoticon63', 'image_emoticon64',
    'image_emoticon65', 'image_emoticon66', 'image_emoticon67', 'image_emoticon68',
    'image_emoticon85', 'image_emoticon86', 'image_emoticon87', 'image_emoticon88',
    'image_emoticon89', 'image_emoticon90', 'image_emoticon91', 'image_emoticon92',
    'image_emoticon95', 'image_emoticon96', 'image_emoticon97', 'image_emoticon125'
  ];

  /** 缓存的所有表情列表 */
  private static emoticonList: EmoticonInfo[] | null = null;

  /**
   * 归一化贴吧表情 ID：
   * 服务端历史数据中 "image_emoticon"（无数字后缀）实际对应 "image_emoticon1"
   */
  static normalizeEmoticonId(rawId: string): string {
    const trimmed: string = rawId.trim();
    if (trimmed === 'image_emoticon') {
      return 'image_emoticon1';
    }
    return trimmed;
  }

  /**
   * 查找本地打包的 51 个新版高清贴吧表情（$rawfile 必须使用编译期字面量）
   */
  private static getLocalEmoticonResource(realId: string): Resource | null {
    switch (realId) {
      case 'image_emoticon1': return $rawfile('emoticons/image_emoticon1.webp');
      case 'image_emoticon2': return $rawfile('emoticons/image_emoticon2.webp');
      case 'image_emoticon3': return $rawfile('emoticons/image_emoticon3.webp');
      case 'image_emoticon4': return $rawfile('emoticons/image_emoticon4.webp');
      case 'image_emoticon5': return $rawfile('emoticons/image_emoticon5.webp');
      case 'image_emoticon6': return $rawfile('emoticons/image_emoticon6.webp');
      case 'image_emoticon7': return $rawfile('emoticons/image_emoticon7.webp');
      case 'image_emoticon8': return $rawfile('emoticons/image_emoticon8.webp');
      case 'image_emoticon9': return $rawfile('emoticons/image_emoticon9.webp');
      case 'image_emoticon10': return $rawfile('emoticons/image_emoticon10.webp');
      case 'image_emoticon11': return $rawfile('emoticons/image_emoticon11.webp');
      case 'image_emoticon12': return $rawfile('emoticons/image_emoticon12.webp');
      case 'image_emoticon13': return $rawfile('emoticons/image_emoticon13.webp');
      case 'image_emoticon14': return $rawfile('emoticons/image_emoticon14.webp');
      case 'image_emoticon15': return $rawfile('emoticons/image_emoticon15.webp');
      case 'image_emoticon16': return $rawfile('emoticons/image_emoticon16.webp');
      case 'image_emoticon17': return $rawfile('emoticons/image_emoticon17.webp');
      case 'image_emoticon18': return $rawfile('emoticons/image_emoticon18.webp');
      case 'image_emoticon19': return $rawfile('emoticons/image_emoticon19.webp');
      case 'image_emoticon20': return $rawfile('emoticons/image_emoticon20.webp');
      case 'image_emoticon21': return $rawfile('emoticons/image_emoticon21.webp');
      case 'image_emoticon22': return $rawfile('emoticons/image_emoticon22.webp');
      case 'image_emoticon23': return $rawfile('emoticons/image_emoticon23.webp');
      case 'image_emoticon24': return $rawfile('emoticons/image_emoticon24.webp');
      case 'image_emoticon25': return $rawfile('emoticons/image_emoticon25.webp');
      case 'image_emoticon26': return $rawfile('emoticons/image_emoticon26.webp');
      case 'image_emoticon27': return $rawfile('emoticons/image_emoticon27.webp');
      case 'image_emoticon28': return $rawfile('emoticons/image_emoticon28.webp');
      case 'image_emoticon29': return $rawfile('emoticons/image_emoticon29.webp');
      case 'image_emoticon30': return $rawfile('emoticons/image_emoticon30.webp');
      case 'image_emoticon31': return $rawfile('emoticons/image_emoticon31.webp');
      case 'image_emoticon32': return $rawfile('emoticons/image_emoticon32.webp');
      case 'image_emoticon33': return $rawfile('emoticons/image_emoticon33.webp');
      case 'image_emoticon34': return $rawfile('emoticons/image_emoticon34.webp');
      case 'image_emoticon35': return $rawfile('emoticons/image_emoticon35.webp');
      case 'image_emoticon36': return $rawfile('emoticons/image_emoticon36.webp');
      case 'image_emoticon37': return $rawfile('emoticons/image_emoticon37.webp');
      case 'image_emoticon38': return $rawfile('emoticons/image_emoticon38.webp');
      case 'image_emoticon39': return $rawfile('emoticons/image_emoticon39.webp');
      case 'image_emoticon40': return $rawfile('emoticons/image_emoticon40.webp');
      case 'image_emoticon41': return $rawfile('emoticons/image_emoticon41.webp');
      case 'image_emoticon42': return $rawfile('emoticons/image_emoticon42.webp');
      case 'image_emoticon43': return $rawfile('emoticons/image_emoticon43.webp');
      case 'image_emoticon44': return $rawfile('emoticons/image_emoticon44.webp');
      case 'image_emoticon45': return $rawfile('emoticons/image_emoticon45.webp');
      case 'image_emoticon46': return $rawfile('emoticons/image_emoticon46.webp');
      case 'image_emoticon47': return $rawfile('emoticons/image_emoticon47.webp');
      case 'image_emoticon48': return $rawfile('emoticons/image_emoticon48.webp');
      case 'image_emoticon49': return $rawfile('emoticons/image_emoticon49.webp');
      case 'image_emoticon50': return $rawfile('emoticons/image_emoticon50.webp');
      case 'image_emoticon89': return $rawfile('emoticons/image_emoticon89.webp');
      default: return null;
    }
  }

  /**
   * 判断表情 ID 是否能解析成有效的本地或 CDN 图片资源
   * 未知格式（如非标准商城贴纸 ID）返回 false，供 UI 降级渲染 [描述] 文本
   */
  static hasRenderableEmoticon(id: string): boolean {
    const realId: string = EmoticonManager.normalizeEmoticonId(id);
    if (realId.length === 0) {
      return false;
    }
    return /^image_emoticon\d+$/i.test(realId) || /^i_f\d+$/i.test(realId) || /^https?:\/\//i.test(realId);
  }

  /**
   * 构造表情图在线 HTTPS URL（向后兼容 + 用于不在本地 rawfile 的新版扩展表情）
   */
  static getEmoticonUrl(id: string): string {
    const realId: string = EmoticonManager.normalizeEmoticonId(id);
    if (realId.length === 0) {
      return '';
    }
    if (/^https?:\/\//i.test(realId)) {
      return realId;
    }
    if (/^i_f\d+$/i.test(realId)) {
      return EmoticonManager.FACE_CDN_BASE + realId + '.png';
    }
    return EmoticonManager.CDN_BASE + realId + '.png';
  }

  /**
   * 获取优先本地新版高清 .webp、其次官方 HTTPS CDN 的表情渲染源
   */
  static getEmoticonResource(id: string): ResourceStr {
    const realId: string = EmoticonManager.normalizeEmoticonId(id);
    const localRes: Resource | null = EmoticonManager.getLocalEmoticonResource(realId);
    if (localRes !== null) {
      return localRes;
    }
    return EmoticonManager.getEmoticonUrl(realId);
  }

  /**
   * 当表情无法解析为图片时的可读文字兜底
   */
  static getFallbackLabel(id: string, emojiDesc: string = ''): string {
    const cleanDesc: string = emojiDesc.trim();
    if (cleanDesc.length > 0) {
      return `[${cleanDesc}]`;
    }
    const cleanId: string = id.trim();
    return cleanId.length > 0 ? `[${cleanId}]` : '[表情]';
  }

  /**
   * 构造 #(表情名) 标记（用于插入回帖 content）
   */
  static buildEmoticonMark(name: string): string {
    return `#(${name})`;
  }

  /**
   * 根据 name 查询表情信息
   */
  static getEmoticonByName(name: string): EmoticonInfo | undefined {
    const index: number = EmoticonManager.NAMES.indexOf(name);
    if (index < 0) {
      return undefined;
    }
    const info: EmoticonInfo = new EmoticonInfo();
    info.id = EmoticonManager.IDS[index];
    info.name = name;
    return info;
  }

  /**
   * 获取所有表情列表（按映射表顺序）
   */
  static getAllEmoticons(): EmoticonInfo[] {
    if (EmoticonManager.emoticonList !== null) {
      return EmoticonManager.emoticonList;
    }
    const list: EmoticonInfo[] = [];
    for (let i = 0; i < EmoticonManager.NAMES.length; i++) {
      const info: EmoticonInfo = new EmoticonInfo();
      info.id = EmoticonManager.IDS[i];
      info.name = EmoticonManager.NAMES[i];
      list.push(info);
    }
    EmoticonManager.emoticonList = list;
    return list;
  }
}

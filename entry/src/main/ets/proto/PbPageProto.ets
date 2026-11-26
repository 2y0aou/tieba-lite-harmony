// PbPage protobuf 编解码（issue #7）
// 字段编号对齐 tbclient.protobuf-main/proto/PbPage 原定义
// wire format 编解码复用 ProtoWire.ets
// 用于 getPosts（帖子详情/回复列表），cmd=302001

import { resolveAnimatedImageUrl } from '../utils/MediaAnimation';
import { PostInfo, SubPostInfo, UserInfo, PageData, ThreadInfo, MediaInfo, ContentFragment, ContentFragmentType, VideoInfo, ForumInfo } from '../model/ForumModels';
import { ProtoWriter, ProtoReader } from './ProtoWire';
import { getAvatarUrl } from '../utils/AvatarUtil';

// ==================== PbPage 请求编码 ====================

/** PbPage 请求参数 */
export interface IPbPageReqParams {
  tid: number;           // 主题帖 id（proto 字段名 kz）
  pn: number;            // 页码
  rn: number;            // 每页回复数
  sort: number;          // 排序方式（0=正序ASC, 1=倒序DESC, 2=热门HOT，对齐 Android ThreadSortType）
  onlyAuthor: boolean;   // 只看楼主
  clientVersion: string;
  withFloor: boolean;
  floorRn: number;
  // 账号字段可选：仅 with_comments=true 时需要 BDUSS（对齐 aiotieba get_posts.pack_proto）
  // 默认 getPosts 是公开读 API，不传 BDUSS
  bduss?: string;
  // #72 加载上一页：back 标记 + pid 锚点（对齐 Android PbPageRequestData.proto field 2/3）
  // back=true 时服务端返回上一页数据，pid 作为定位锚点（当前列表首条 post id）
  back?: boolean;        // field 3：是否向前翻页
  lastPostId?: number;   // field 2：锚点 post id（当前列表首条 pid）
}

/**
 * 编码 CommonReq（field 编号对齐 CommonReq.proto）
 * 对齐 aiotieba get_posts.pack_proto：默认仅传 _client_type + _client_version
 * BDUSS 仅 with_comments=true 时传（HarmonyOS 端目前未启用 with_comments，故不传）
 *
 * 修复 350004 根因：b84231c commit 曾添加 cuid/timestamp/net_type/BDUSS 到 CommonReq，
 * 服务端对 protobuf 端点做严格会话校验导致 350004 从 ~1% 升至 100%。
 * 移除多余字段回归 aiotieba 实现，BDUSS 保留可选供未来 with_comments 使用。
 */
function encodeCommonReq(writer: ProtoWriter, params: IPbPageReqParams): void {
  writer.writeInt32(1, 2);                     // _client_type = 2
  writer.writeString(2, params.clientVersion); // _client_version
  if (params.bduss !== undefined && params.bduss.length > 0) {
    writer.writeString(10, params.bduss);      // BDUSS（仅 with_comments 时传，HarmonyOS 端暂未启用）
  }
}

/** 编码 DataReq（field 编号对齐 PbPageReqIdl.proto） */
function encodeDataReq(params: IPbPageReqParams): Uint8Array {
  const writer = new ProtoWriter();
  // #72 加载上一页：back 标记（field 3）+ pid 锚点（field 2）
  // 对齐 Android PbPageRequestData.proto：back=true 时服务端返回上一页数据
  if (params.back) {
    writer.writeInt32(3, 1);                                  // back = 1（向前翻页标记）
  }
  if (params.lastPostId !== undefined && params.lastPostId > 0) {
    writer.writeInt32(2, params.lastPostId);                  // pid（锚点 post id）
  }
  writer.writeInt32(4, params.tid);                          // kz = tid
  writer.writeInt32(5, params.onlyAuthor ? 1 : 0);           // lz = only_thread_author
  writer.writeInt32(6, params.sort);                         // r = sort
  writer.writeInt32(8, params.withFloor ? 1 : 0);            // with_floor
  writer.writeInt32(9, params.floorRn);                      // floor_rn
  // rn：对齐 aiotieba（rn > 1 时原样传，否则传 2）
  writer.writeInt32(13, params.rn > 1 ? params.rn : 2);      // rn
  writer.writeInt32(18, params.pn);                          // pn

  // common（field 25，嵌套 message）
  const commonWriter = new ProtoWriter();
  encodeCommonReq(commonWriter, params);
  writer.writeMessage(25, commonWriter.finish());

  return writer.finish();
}

/** 编码 PbPageReqIdl 顶层 */
export function encodePbPageReq(params: IPbPageReqParams): Uint8Array {
  const writer = new ProtoWriter();
  const dataBytes = encodeDataReq(params);
  writer.writeMessage(1, dataBytes);  // data
  return writer.finish();
}

// ==================== PbPage 响应解码 ====================

/** PbPage 解析结果 */
export class PbPageResult {
  posts: PageData<PostInfo> = new PageData<PostInfo>();
  thread: ThreadInfo = new ThreadInfo();  // 主题帖信息（标题等）
  forum: ForumInfo = new ForumInfo();
  /** #74 贴吧 id（来自 forum.id，回帖 API 必传字段） */
  forumId: number = 0;
}

/**
 * #101 decodePostContent 解码结果（消除副作用，纯函数化）
 * 旧实现通过 mediaList 入参 push 数据违反纯函数原则，改为返回本 class 实例
 */
export class PostContentDecodeResult {
  fragments: ContentFragment[] = [];
  mediaList: MediaInfo[] = [];
}

/** 解析 User（field 编号对齐 User.proto，与 FrsPageProto.decodeUser 一致）
 * #73 楼中楼作者解析复用此函数：SubPostList.author 与 Post.author 同为 User */
export function decodeUser(reader: ProtoReader): UserInfo {
  const user = new UserInfo();
  while (!reader.isEnd()) {
    const tag = reader.readTag();
    switch (tag.fieldNumber) {
      case 2:   // id
        user.uid = reader.readVarint();
        break;
      case 3:   // name
        user.name = reader.readString();
        break;
      case 4:   // name_show
        user.nickname = reader.readString();
        break;
      case 5: {  // portrait（短标识符如 "tb.0.xxx"，需拼接完整 URL）
        const portrait: string = reader.readString();
        // 保存原始 portrait 标识符，用于用户主页 API 查询
        user.portrait = portrait;
        // 对齐 aiotieba client.py:1221：小头像 55x55（AvatarUtil 内部已处理清洗+空值）
        user.avatar = getAvatarUrl(portrait, 's');
        break;
      }
      case 23:  // level_id
        user.level = reader.readVarint();
        break;
      case 25:  // is_bawu
        user.isBawu = reader.readVarint() !== 0;
        break;
      case 42:  // gender
        user.gender = reader.readVarint();
        break;
      case 127: // ip_address（IP 属地）
        user.ipAddress = reader.readString();
        break;
      default:
        reader.skipField(tag.wireType);
        break;
    }
  }
  return user;
}

/**
 * #71 解析 Post 的 content 碎片（field 编号对齐 PbContent.proto）
 * 返回 PostContentDecodeResult，包含 ContentFragment[]（富文本渲染）+ MediaInfo[]（图片块渲染）
 * #101 消除副作用：旧实现通过 mediaList 入参 push 数据，改为返回结果对象（纯函数化）
 * 对齐 aiotieba get_posts/_classdef.py Contents_p.from_proto + 各 Frag*_p.from_proto
 *
 * 字段编号映射（aiotieba 权威）：
 * - field 1: type（碎片类型枚举）
 * - field 2: text（TEXT正文 / LINK标题 / EMOJI的id / AT的昵称）
 * - field 3: link（LINK的URL / VIDEO的src）
 * - field 4: src（VIDEO封面，本阶段未用）
 * - field 5: bsize（图片尺寸 "width,height"）
 * - field 8: cdn_src（小图CDN）
 * - field 9: big_cdn_src（大图CDN）
 * - field 11: c（EMOJI描述）
 * - field 15: uid（AT的用户ID）
 * - field 25: origin_src（原图链接）
 *
 * #73 楼中楼内容复用此函数：SubPostList.content 与 Post.content 同为 repeated PbContent
 */
export function decodePostContent(reader: ProtoReader): PostContentDecodeResult {
  const result: PostContentDecodeResult = new PostContentDecodeResult();
  // proto3 默认值 0 = 纯文本（对齐 aiotieba _classdef.py: _type in [0,9,18,27,40] 为纯文本）
  // 命名 fragmentType：明确表示"这个碎片的内容类型"（非"当前处理类型"）
  let fragmentType: number = 0;
  // 通用字段（按 type 语义复用）
  let textValue: string = '';     // field 2
  let linkValue: string = '';     // field 3（LINK URL）
  let emojiDesc: string = '';     // field 11（EMOJI 描述）
  let uidValue: number = 0;       // field 15（AT 用户ID）
  // 图片碎片字段（type=3/20 或带 memeInfo 时有效，对齐 PbContent.proto）
  let bigSrc: string = '';        // field 6 — 大图备用链接
  let cdnSrc: string = '';        // field 8 — 小图 CDN 链接
  let bigCdnSrc: string = '';     // field 9 — 大图 CDN 链接
  let originSrc: string = '';     // field 25 — 原图链接
  let imageType: string = '';
  let dynamicImage: string = '';
  let staticImage: string = '';   // field 17 — 静态图兜底
  let activeImage: string = '';
  let bsize: string = '';         // field 5 — "width,height" 显示尺寸（图片专用）
  // 表情包/贴纸（field 33 MemeInfo）与贴吧+卡片（field 40/41）
  let memePicUrl: string = '';
  let memeThumbnail: string = '';
  let memeWidth: number = 0;
  let memeHeight: number = 0;
  let tiebaplusTitle: string = '';
  let tiebaplusDesc: string = '';
  let tiebaplusUrl: string = '';
  let itemName: string = '';
  // #151 视频碎片字段（type=5 时有效，对齐 PbContent.proto + aiotieba FragVideo_p.from_proto）
  let srcValue: string = '';      // field 4 — src（视频封面URL / type=20 贴纸图URL）
  let videoWidth: number = 0;     // field 18 — 视频宽度（uint32，视频专用，非 bsize）
  let videoHeight: number = 0;    // field 19 — 视频高度（uint32，视频专用，非 bsize）

  while (!reader.isEnd()) {
    const tag = reader.readTag();
    if (tag.fieldNumber === 1) {
      // type（0=纯文本, 1=链接, 2/11=表情, 3/20=图片, 4=@, 5=视频, 9=电话号, 10=语音, 18=话题, 27=百科, 35/36/37=贴吧+, 40=梗百科）
      fragmentType = reader.readVarint();
    } else if (tag.fieldNumber === 2) {
      textValue = reader.readString();
    } else if (tag.fieldNumber === 3) {
      linkValue = reader.readString();
    } else if (tag.fieldNumber === 4) {
      srcValue = reader.readString();
    } else if (tag.fieldNumber === 5) {
      bsize = reader.readString();
    } else if (tag.fieldNumber === 6) {
      bigSrc = reader.readString();
    } else if (tag.fieldNumber === 8) {
      cdnSrc = reader.readString();
    } else if (tag.fieldNumber === 9) {
      bigCdnSrc = reader.readString();
    } else if (tag.fieldNumber === 10) {
      imageType = reader.readString();
    } else if (tag.fieldNumber === 11) {
      emojiDesc = reader.readString();
    } else if (tag.fieldNumber === 15) {
      uidValue = reader.readVarint();
    } else if (tag.fieldNumber === 16) {
      dynamicImage = reader.readString();
    } else if (tag.fieldNumber === 17) {
      staticImage = reader.readString();
    } else if (tag.fieldNumber === 18) {
      videoWidth = reader.readVarint();
    } else if (tag.fieldNumber === 19) {
      videoHeight = reader.readVarint();
    } else if (tag.fieldNumber === 25) {
      originSrc = reader.readString();
    } else if (tag.fieldNumber === 33) {
      // MemeInfo: picUrl=3, thumbnail=4, width=5, height=6
      const memeReader = reader.readMessage();
      while (!memeReader.isEnd()) {
        const mTag = memeReader.readTag();
        if (mTag.fieldNumber === 3) {
          memePicUrl = memeReader.readString();
        } else if (mTag.fieldNumber === 4) {
          memeThumbnail = memeReader.readString();
        } else if (mTag.fieldNumber === 5) {
          memeWidth = memeReader.readVarint();
        } else if (mTag.fieldNumber === 6) {
          memeHeight = memeReader.readVarint();
        } else {
          memeReader.skipField(mTag.wireType);
        }
      }
    } else if (tag.fieldNumber === 36) {
      activeImage = reader.readString();
    } else if (tag.fieldNumber === 40) {
      // TiebaPlusInfo: title=1, desc=2, jump_url=3
      const tpReader = reader.readMessage();
      while (!tpReader.isEnd()) {
        const tpTag = tpReader.readTag();
        if (tpTag.fieldNumber === 1) {
          tiebaplusTitle = tpReader.readString();
        } else if (tpTag.fieldNumber === 2) {
          tiebaplusDesc = tpReader.readString();
        } else if (tpTag.fieldNumber === 3) {
          tiebaplusUrl = tpReader.readString();
        } else {
          tpReader.skipField(tpTag.wireType);
        }
      }
    } else if (tag.fieldNumber === 41) {
      // Item: item_name=2
      const itemReader = reader.readMessage();
      while (!itemReader.isEnd()) {
        const itemTag = itemReader.readTag();
        if (itemTag.fieldNumber === 2) {
          itemName = itemReader.readString();
        } else {
          itemReader.skipField(itemTag.wireType);
        }
      }
    } else {
      reader.skipField(tag.wireType);
    }
  }

  // 按 fragmentType 分发构建 fragment（对齐 aiotieba Contents_p._frags 调度逻辑）
  if (fragmentType === 0 || fragmentType === 9 || fragmentType === 18
      || fragmentType === 27 || fragmentType === 40) {
    // FragText_p: 纯文本/电话号/话题/百科/梗百科
    if (textValue.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.TEXT;
      frag.text = textValue;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 1) {
    // FragLink_p: 链接（text=标题, link=URL）
    const linkLabel: string = textValue.length > 0 ? textValue : linkValue;
    if (linkLabel.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.LINK;
      frag.text = linkLabel;
      frag.link = linkValue.length > 0 ? linkValue : linkLabel;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 2 || fragmentType === 11) {
    // FragEmoji_p: 表情（text=表情id, emojiDesc=描述）
    if (textValue.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.EMOJI;
      frag.text = textValue;
      frag.emojiDesc = emojiDesc;
      result.fragments.push(frag);
    } else if (emojiDesc.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.TEXT;
      frag.text = `[${emojiDesc}]`;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 4) {
    // FragAt_p: @用户（text=昵称, uid=用户ID）
    if (textValue.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.AT;
      frag.text = textValue;
      frag.uid = uidValue;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 3 || fragmentType === 20 || memePicUrl.length > 0 || memeThumbnail.length > 0) {
    // FragImage_p: 图片/大贴纸/Meme表情包碎片
    const media: MediaInfo = new MediaInfo();
    // URL 优先级：origin > big_cdn > big_src > cdn > src > static > memePicUrl > memeThumbnail
    if (originSrc.length > 0) {
      media.url = originSrc;
    } else if (bigCdnSrc.length > 0) {
      media.url = bigCdnSrc;
    } else if (bigSrc.length > 0) {
      media.url = bigSrc;
    } else if (cdnSrc.length > 0) {
      media.url = cdnSrc;
    } else if (srcValue.length > 0) {
      media.url = srcValue;
    } else if (staticImage.length > 0) {
      media.url = staticImage;
    } else if (memePicUrl.length > 0) {
      media.url = memePicUrl;
    } else {
      media.url = memeThumbnail;
    }
    media.animatedUrl = resolveAnimatedImageUrl(dynamicImage, media.url, imageType, activeImage);
    if (media.url.length === 0) {
      media.url = media.animatedUrl.length > 0 ? media.animatedUrl : activeImage;
    }
    media.thumbnail = cdnSrc.length > 0 ? cdnSrc :
      (memeThumbnail.length > 0 ? memeThumbnail : (srcValue.length > 0 ? srcValue : media.url));
    if (bsize.length > 0) {
      const parts: string[] = bsize.split(',');
      if (parts.length >= 2) {
        const w: number = Number(parts[0]);
        const h: number = Number(parts[1]);
        media.width = Number.isNaN(w) ? 0 : w;
        media.height = Number.isNaN(h) ? 0 : h;
      }
    }
    if (media.width === 0 && memeWidth > 0) {
      media.width = memeWidth;
    }
    if (media.height === 0 && memeHeight > 0) {
      media.height = memeHeight;
    }
    if (media.url.length > 0) {
      result.mediaList.push(media);
    } else if (textValue.length > 0 || emojiDesc.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.TEXT;
      frag.text = textValue.length > 0 ? textValue : `[${emojiDesc}]`;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 5) {
    // #151 FragVideo: 视频碎片
    if (srcValue.length > 0 && linkValue.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.VIDEO;
      frag.text = textValue;
      frag.videoUrl = linkValue;
      frag.coverUrl = srcValue;
      frag.videoWidth = videoWidth;
      frag.videoHeight = videoHeight;
      result.fragments.push(frag);
    } else if (textValue.length > 0 || linkValue.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.LINK;
      frag.text = textValue.length > 0 ? textValue : '[视频]';
      frag.link = linkValue.length > 0 ? linkValue : textValue;
      result.fragments.push(frag);
    }
  } else if (fragmentType === 10) {
    const frag: ContentFragment = new ContentFragment();
    frag.type = ContentFragmentType.TEXT;
    frag.text = '[语音]';
    result.fragments.push(frag);
  } else if (fragmentType === 35 || fragmentType === 36 || fragmentType === 37) {
    // 贴吧+ 卡片/推广/话题链接
    const tpLabel: string = tiebaplusTitle.length > 0 ? tiebaplusTitle :
      (tiebaplusDesc.length > 0 ? tiebaplusDesc : textValue);
    if (tpLabel.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = tiebaplusUrl.length > 0 ? ContentFragmentType.LINK : ContentFragmentType.TEXT;
      frag.text = tpLabel;
      frag.link = tiebaplusUrl;
      result.fragments.push(frag);
    }
  } else {
    // 兜底渲染其他未单独适配的富文本碎片，避免整层楼显示为空白
    const fallbackText: string = textValue.length > 0 ? textValue :
      (emojiDesc.length > 0 ? `[${emojiDesc}]` :
        (itemName.length > 0 ? itemName :
          (tiebaplusTitle.length > 0 ? tiebaplusTitle : linkValue)));
    if (fallbackText.length > 0) {
      const frag: ContentFragment = new ContentFragment();
      frag.type = ContentFragmentType.TEXT;
      frag.text = fallbackText;
      result.fragments.push(frag);
    }
  }

  return result;
}

/**
 * 解析 SubPostList message（field 编号对齐 SubPostList.proto）
 * 字段：id=1 / content=2(repeated PbContent) / time=3 / author_id=4 / title=5 /
 *      floor=6 / author=7(User) / is_giftpost=8 / agree=9(Agree) / location=10 / is_fake_top=11
 * #252 楼中楼预览：从 PbFloorProto 提取到此处，供 Post.sub_post_list (field 15) 解码复用，
 * 同时 PbFloorProto 改为 import 此函数，保持单一数据源，避免循环依赖。
 */
export function decodeSubPostList(reader: ProtoReader, tid: number, pid: number,
  users: Map<number, UserInfo> | undefined = undefined): SubPostInfo {
  const subPost = new SubPostInfo();
  subPost.tid = tid;
  subPost.pid = pid;
  let authorId: number = 0;

  while (!reader.isEnd()) {
    const tag = reader.readTag();
    switch (tag.fieldNumber) {
      case 1:   // id（楼中楼 spid）
        subPost.spid = reader.readVarint();
        break;
      case 2: {  // content（repeated PbContent）- 复用 decodePostContent
        const contentReader = reader.readMessage();
        // #101 decodePostContent 返回 PostContentDecodeResult（纯函数无副作用）
        // 楼中楼无独立 mediaList，丢弃 result.mediaList（图片碎片不渲染为独立图片块）
        const contentResult: PostContentDecodeResult = decodePostContent(contentReader);
        // 合并 fragments 到 subPost.fragments
        for (let i = 0; i < contentResult.fragments.length; i++) {
          subPost.fragments.push(contentResult.fragments[i]);
        }
        break;
      }
      case 3:   // time（创建时间戳，秒）
        subPost.createTime = reader.readVarint();
        break;
      case 4:   // author_id
        authorId = reader.readVarint();
        break;
      case 5:   // title
        subPost.title = reader.readString();
        break;
      case 6:   // floor
        subPost.floor = reader.readVarint();
        break;
      case 7: {  // author（User message）
        const authorReader = reader.readMessage();
        subPost.author = decodeUser(authorReader);
        break;
      }
      case 9: {  // agree（Agree: agree_num=1, disagree_num=4）
        const agreeReader = reader.readMessage();
        while (!agreeReader.isEnd()) {
          const agreeTag = agreeReader.readTag();
          if (agreeTag.fieldNumber === 1) {        // agree_num
            subPost.agreeNum = agreeReader.readVarint();
          } else if (agreeTag.fieldNumber === 4) { // disagree_num
            subPost.disagreeNum = agreeReader.readVarint();
          } else if (agreeTag.fieldNumber === 2) { // has_agree
            subPost.isAgreed = agreeReader.readVarint() !== 0;
          } else if (agreeTag.fieldNumber === 5) { // diff_agree_num
            subPost.agreeNum = agreeReader.readVarint();
          } else {
            agreeReader.skipField(agreeTag.wireType);
          }
        }
        break;
      }
      case 10: { // location（楼中楼 IP 属地兜底）
        const loc: string = reader.readString();
        if (loc.length > 0 && subPost.author.ipAddress.length === 0) {
          subPost.author.ipAddress = loc;
        }
        break;
      }
      default:
        reader.skipField(tag.wireType);
        break;
    }
  }

  // 拼接 content 文本（用于复制/搜索场景，对齐 PostInfo.content 拼接策略）
  // 用数组 push + join 替代 += 拼接，避免循环内产生大量字符串中间对象
  const contentParts: string[] = [];
  for (let i = 0; i < subPost.fragments.length; i++) {
    const frag: ContentFragment = subPost.fragments[i];
    // 包含 TEXT/LINK/AT 的 text（可读文本），不包含 EMOJI（text 是 id 非可读）
    if (frag.type === ContentFragmentType.TEXT
        || frag.type === ContentFragmentType.LINK
        || frag.type === ContentFragmentType.AT) {
      contentParts.push(frag.text);
    }
  }
  subPost.content = contentParts.join('');

  if (authorId > 0 && users !== undefined) {
    const user: UserInfo | undefined = users.get(authorId);
    if (user !== undefined) {
      const locFallback: string = subPost.author.ipAddress;
      subPost.author = user;
      if (subPost.author.ipAddress.length === 0 && locFallback.length > 0) {
        subPost.author.ipAddress = locFallback;
      }
    }
  }
  if (subPost.author.uid === 0 && authorId > 0) {
    subPost.author.uid = authorId;
  }
  return subPost;
}

/** 解析 Post（field 编号对齐 Post.proto） */
export function decodePost(reader: ProtoReader, users: Map<number, UserInfo>, threadTid: number): PostInfo {
  const post = new PostInfo();
  post.tid = threadTid;
  let authorId: number = 0;
  let contentText: string = '';
  let foldTip: string = '';
  let hasSpriteMeme: boolean = false;
  let embeddedAuthor: UserInfo | null = null;

  while (!reader.isEnd()) {
    const tag = reader.readTag();
    switch (tag.fieldNumber) {
      case 1:   // id（pid）
        post.pid = reader.readVarint();
        break;
      case 3:   // floor
        post.floor = reader.readVarint();
        break;
      case 4:   // time（create_time）
        post.createTime = reader.readVarint();
        break;
      case 5: {  // content（repeated PbContent）
        const contentReader = reader.readMessage();
        const contentResult: PostContentDecodeResult = decodePostContent(contentReader);
        for (let i = 0; i < contentResult.fragments.length; i++) {
          post.fragments.push(contentResult.fragments[i]);
          if (contentResult.fragments[i].type === ContentFragmentType.TEXT
              || contentResult.fragments[i].type === ContentFragmentType.LINK
              || contentResult.fragments[i].type === ContentFragmentType.AT) {
            contentText += contentResult.fragments[i].text;
          }
        }
        for (let i = 0; i < contentResult.mediaList.length; i++) {
          post.mediaList.push(contentResult.mediaList[i]);
        }
        break;
      }
      case 13:  // sub_post_number（楼中楼数 = replyNum）
        post.replyNum = reader.readVarint();
        break;
      case 15: {  // #252 sub_post_list（SubPost message，含 repeated SubPostList 预览）
        const subPostReader = reader.readMessage();
        while (!subPostReader.isEnd()) {
          const subPostTag = subPostReader.readTag();
          if (subPostTag.fieldNumber === 2) {  // repeated SubPostList
            const subPostListReader = subPostReader.readMessage();
            const subPost = decodeSubPostList(subPostListReader, threadTid, post.pid, users);
            if (subPost.spid > 0) {
              post.subPostList.push(subPost);
            }
          } else {
            subPostReader.skipField(subPostTag.wireType);
          }
        }
        break;
      }
      case 19:  // author_id
        authorId = reader.readVarint();
        break;
      case 23: { // 内嵌 author（user_list 缺失时兜底）
        const authorReader = reader.readMessage();
        embeddedAuthor = decodeUser(authorReader);
        break;
      }
      case 37: {  // agree（Agree: agree_num=1, has_agree=2, disagree_num=4）
        const agreeReader = reader.readMessage();
        while (!agreeReader.isEnd()) {
          const agreeTag = agreeReader.readTag();
          if (agreeTag.fieldNumber === 1) {        // agree_num
            post.agreeNum = agreeReader.readVarint();
          } else if (agreeTag.fieldNumber === 2) { // has_agree（当前用户已赞）
            post.isAgreed = agreeReader.readVarint() !== 0;
          } else if (agreeTag.fieldNumber === 4) { // disagree_num
            post.disagreeNum = agreeReader.readVarint();
          } else {
            agreeReader.skipField(agreeTag.wireType);
          }
        }
        break;
      }
      case 29: {  // #151 video_info（VideoInfo，对齐 Post.proto field 29）
        const videoReader = reader.readMessage();
        post.videoInfo = decodeVideoInfo(videoReader);
        break;
      }
      case 44:  // fold_tip
        foldTip = reader.readString();
        break;
      case 79:  // sprite_meme_info
        hasSpriteMeme = true;
        reader.skipField(tag.wireType);
        break;
      default:
        reader.skipField(tag.wireType);
        break;
    }
  }

  const hasPostVideo: boolean = post.videoInfo !== null && post.videoInfo.videoUrl.length > 0;
  if (post.fragments.length === 0 && post.mediaList.length === 0 && !hasPostVideo) {
    if (foldTip.length > 0) {
      const tipFrag: ContentFragment = new ContentFragment();
      tipFrag.type = ContentFragmentType.TEXT;
      tipFrag.text = foldTip;
      post.fragments.push(tipFrag);
      contentText = foldTip;
    } else if (hasSpriteMeme) {
      const memeFrag: ContentFragment = new ContentFragment();
      memeFrag.type = ContentFragmentType.TEXT;
      memeFrag.text = '[贴吧表情包]';
      post.fragments.push(memeFrag);
      contentText = '[贴吧表情包]';
    }
  }

  post.content = contentText;

  // 从 user_list 中查找作者，缺失时回退内嵌 author
  if (authorId > 0) {
    const user = users.get(authorId);
    if (user !== undefined) {
      post.author = user;
    } else if (embeddedAuthor !== null) {
      post.author = embeddedAuthor;
    }
  } else if (embeddedAuthor !== null) {
    post.author = embeddedAuthor;
  }
  if (post.author.ipAddress.length === 0 && embeddedAuthor !== null && embeddedAuthor.ipAddress.length > 0) {
    post.author.ipAddress = embeddedAuthor.ipAddress;
  }

  return post;
}

/**
 * #151 解析 VideoInfo（field 编号对齐 VideoInfo.proto）
 * 用于 Post field 29 / ThreadInfo field 79
 * 字段映射：2=videoUrl, 3=videoDuration, 4=videoWidth, 5=videoHeight,
 *           6=thumbnailUrl, 7=thumbnailWidth, 8=thumbnailHeight
 * field 1(videoMD5) / 11(mediaSubtitle) 暂不使用，跳过
 */
function decodeVideoInfo(reader: ProtoReader): VideoInfo {
  const info: VideoInfo = new VideoInfo();
  while (!reader.isEnd()) {
    const tag = reader.readTag();
    if (tag.fieldNumber === 2) {
      info.videoUrl = reader.readString();
    } else if (tag.fieldNumber === 3) {
      info.videoDuration = reader.readVarint();
    } else if (tag.fieldNumber === 4) {
      info.videoWidth = reader.readVarint();
    } else if (tag.fieldNumber === 5) {
      info.videoHeight = reader.readVarint();
    } else if (tag.fieldNumber === 6) {
      info.thumbnailUrl = reader.readString();
    } else if (tag.fieldNumber === 7) {
      info.thumbnailWidth = reader.readVarint();
    } else if (tag.fieldNumber === 8) {
      info.thumbnailHeight = reader.readVarint();
    } else {
      reader.skipField(tag.wireType);
    }
  }
  return info;
}

/**
 * 解析 PbPageResIdl 顶层
 * 对齐 aiotieba get_posts.parse_body + Posts.from_proto
 * 关联逻辑：先收集 user_list，再解析 post_list（避免字段顺序问题）
 */
export function decodePbPageRes(bytes: Uint8Array): PbPageResult {
  const reader = new ProtoReader(bytes);
  const result = new PbPageResult();

  while (!reader.isEnd()) {
    const tag = reader.readTag();
    if (tag.fieldNumber === 1) {
      // error
      const errReader = reader.readMessage();
      let errorNo: number = 0;
      let errorMsg: string = '';
      while (!errReader.isEnd()) {
        const errTag = errReader.readTag();
        if (errTag.fieldNumber === 1) {        // errorno
          errorNo = errReader.readVarint();
        } else if (errTag.fieldNumber === 2) { // errmsg
          errorMsg = errReader.readString();
        } else {
          errReader.skipField(errTag.wireType);
        }
      }
      if (errorNo !== 0) {
        throw new Error(`获取回复列表失败 [${errorNo}]: ${errorMsg}`);
      }
    } else if (tag.fieldNumber === 2) {
      // data
      const dataReader = reader.readMessage();
      const users = new Map<number, UserInfo>();
      const rawPosts: ProtoReader[] = [];  // 先收集 post_list raw bytes
      let threadTid: number = 0;
      let threadAuthorId: number = 0;
      let forumName: string = '';
      let forumIdValue: number = 0;  // #74 forum.id（回帖 API 必传字段）

      // 第一遍：收集 forum/page/user_list/thread，post_list 只存 raw bytes
      while (!dataReader.isEnd()) {
        const dataTag = dataReader.readTag();
        if (dataTag.fieldNumber === 2) {
          // forum（SimpleForum）：id=1, name=2, avatar=4
          const forumReader = dataReader.readMessage();
          while (!forumReader.isEnd()) {
            const forumTag = forumReader.readTag();
            if (forumTag.fieldNumber === 1) {        // id
              forumIdValue = forumReader.readVarint();
              result.forum.id = forumIdValue;
            } else if (forumTag.fieldNumber === 2) { // name
              forumName = forumReader.readString();
              result.forum.name = forumName;
            } else if (forumTag.fieldNumber === 4) { // avatar
              result.forum.avatar = forumReader.readString();
            } else {
              forumReader.skipField(forumTag.wireType);
            }
          }
        } else if (dataTag.fieldNumber === 3) {
          // page（Page）：current_page=3, total_page=5, has_more=6, has_prev=7
          const pageReader = dataReader.readMessage();
          while (!pageReader.isEnd()) {
            const pageTag = pageReader.readTag();
            if (pageTag.fieldNumber === 3) {         // current_page
              result.posts.currentPage = pageReader.readVarint();
            } else if (pageTag.fieldNumber === 5) {  // total_page
              result.posts.totalPage = pageReader.readVarint();
            } else if (pageTag.fieldNumber === 6) {  // has_more
              result.posts.hasMore = pageReader.readVarint() !== 0;
            } else if (pageTag.fieldNumber === 7) {  // has_prev（#72 加载上一页）
              result.posts.hasPrev = pageReader.readVarint() !== 0;
            } else {
              pageReader.skipField(pageTag.wireType);
            }
          }
        } else if (dataTag.fieldNumber === 6) {
          // post_list（repeated）—— 先存 raw bytes，第二遍再解码
          rawPosts.push(dataReader.readMessage());
        } else if (dataTag.fieldNumber === 8) {
          // thread（ThreadInfo）—— 提取 tid、title、reply_num、view_num、create_time、forum_name、author_id、agree
          // 字段编号对齐 aiotieba ThreadInfo.proto（与真实响应一致）+ 旧版 Thread.proto 兼容位：
          //   id=1（真实响应中 tid 所在，aiotieba）/ tid=2（旧版定义，兼容保留）
          //   title=3, reply_num=4, view_num=5, create_time=45, forum_name=28, author_id=56, agree=126（Agree）
          // 此前仅读 field 2，实测响应（field 1）下 threadTid 恒为 0，
          // 导致楼层点赞请求 thread_id=0 被服务端拒绝（"评论无法点赞"根因）
          const threadReader = dataReader.readMessage();
          while (!threadReader.isEnd()) {
            const threadTag = threadReader.readTag();
            if (threadTag.fieldNumber === 1 || threadTag.fieldNumber === 2) { // tid（id=1 主字段 / tid=2 兼容）
              const tidValue: number = threadReader.readVarint();
              if (tidValue > 0) {
                threadTid = tidValue;
                result.thread.tid = tidValue;
              }
            } else if (threadTag.fieldNumber === 3) { // title
              result.thread.title = threadReader.readString();
            } else if (threadTag.fieldNumber === 4) { // reply_num（总回复数）
              result.thread.replyNum = threadReader.readVarint();
            } else if (threadTag.fieldNumber === 5) { // view_num（浏览数）
              result.thread.viewNum = threadReader.readVarint();
            } else if (threadTag.fieldNumber === 28) { // forum_name（吧名，优先于 forum 字段）
              result.thread.forumName = threadReader.readString();
            } else if (threadTag.fieldNumber === 155) { // forum_info（SimpleForum）
              const forumReader = threadReader.readMessage();
              while (!forumReader.isEnd()) {
                const forumTag = forumReader.readTag();
                if (forumTag.fieldNumber === 1) {
                  result.thread.forumInfo.id = forumReader.readVarint();
                } else if (forumTag.fieldNumber === 2) {
                  result.thread.forumInfo.name = forumReader.readString();
                } else if (forumTag.fieldNumber === 4) {
                  result.thread.forumInfo.avatar = forumReader.readString();
                } else if (forumTag.fieldNumber === 5) {
                  result.thread.forumInfo.isFollowed = forumReader.readVarint() !== 0;
                } else {
                  forumReader.skipField(forumTag.wireType);
                }
              }
            } else if (threadTag.fieldNumber === 18) { // author（内嵌 User）
              const authorReader = threadReader.readMessage();
              const embeddedAuthor = decodeUser(authorReader);
              if (embeddedAuthor.uid > 0 || embeddedAuthor.name.length > 0 || embeddedAuthor.nickname.length > 0) {
                result.thread.author = embeddedAuthor;
                if (embeddedAuthor.uid > 0) {
                  threadAuthorId = embeddedAuthor.uid;
                }
              }
            } else if (threadTag.fieldNumber === 45) { // create_time（创建时间戳，秒）
              result.thread.createTime = threadReader.readVarint();
            } else if (threadTag.fieldNumber === 56) { // author_id（作者 uid）
              threadAuthorId = threadReader.readVarint();
            } else if (threadTag.fieldNumber === 126) { // agree（Agree，#69 主题帖点赞）
              const agreeReader = threadReader.readMessage();
              while (!agreeReader.isEnd()) {
                const agreeTag = agreeReader.readTag();
                if (agreeTag.fieldNumber === 1) {        // agree_num
                  result.thread.agreeNum = agreeReader.readVarint();
                } else if (agreeTag.fieldNumber === 2) { // has_agree（当前用户已赞）
                  result.thread.isAgreed = agreeReader.readVarint() !== 0;
                } else if (agreeTag.fieldNumber === 4) { // disagree_num
                  result.thread.disagreeNum = agreeReader.readVarint();
                } else {
                  agreeReader.skipField(agreeTag.wireType);
                }
              }
            } else {
              threadReader.skipField(threadTag.wireType);
            }
          }
        } else if (dataTag.fieldNumber === 13) {
          // user_list（repeated）
          const userReader = dataReader.readMessage();
          const user = decodeUser(userReader);
          users.set(user.uid, user);
        } else {
          dataReader.skipField(dataTag.wireType);
        }
      }

      // 第一遍结束后：补全 thread.forumName（若 thread 内嵌吧名缺失则用 forum 字段）
      if (result.thread.forumName.length === 0 && forumName.length > 0) {
        result.thread.forumName = forumName;
      }
      // #74 补全 forumId（回帖 API 必传字段，来自 forum.id）
      result.forumId = forumIdValue;
      // 补全 thread.author（从 user_list 查找作者信息）
      if (threadAuthorId > 0) {
        const author = users.get(threadAuthorId);
        if (author !== undefined) {
          result.thread.author = author;
        }
      }

      // 第二遍：解析 posts（此时 users map 已全部填充，author 关联可靠）
      const posts: PostInfo[] = [];
      for (let i = 0; i < rawPosts.length; i++) {
        const post = decodePost(rawPosts[i], users, threadTid);
        posts.push(post);
        // 补全楼主作者与创建时间：部分帖子 thread.author_id 为 0，需从 1 楼 post.author 回填
        if (post.floor === 1) {
          if (result.thread.author.uid === 0 && result.thread.author.name.length === 0 &&
            result.thread.author.nickname.length === 0 &&
            (post.author.uid > 0 || post.author.name.length > 0 || post.author.nickname.length > 0)) {
            result.thread.author = post.author;
          }
          if (result.thread.createTime === 0 && post.createTime > 0) {
            result.thread.createTime = post.createTime;
          }
        }
      }
      result.posts.list = posts;
    } else {
      reader.skipField(tag.wireType);
    }
  }

  return result;
}

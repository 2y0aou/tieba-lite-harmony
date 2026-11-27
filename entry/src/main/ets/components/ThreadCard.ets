import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { ThreadInfo, MediaInfo, SubPostInfo, ContentFragment, ContentFragmentType } from '../model/ForumModels';
import { EmoticonInfo, EmoticonManager } from '../utils/EmoticonManager';
import { resolveHighResImageUrl } from '../utils/MediaAnimation';
import { formatRelativeTime } from '../utils/TimeUtil';
import { getMediaImageUrl, getAvatarImageUrl } from '../utils/ImageLoadUtil';
import { connectTheme, ThemeState } from '../theme/ThemeManager';
import { RADIUS_PILL, RADIUS_SM } from '../theme/DesignTokens';
import { RouterUtil, ImageViewerNavParams } from '../utils/RouterUtil';
import { getResourceString } from '../utils/ResourceUtil';
import { buildThreadShareUrl } from '../utils/AppLinkingUtil';
import { buildHyperlinkShareData } from '../utils/KnockShareUtil';
import { Logger } from '../utils/Logger';
import { formatCount } from '../utils/FormatUtil';
import { formatTiebaName, getTiebaPrimaryName, getTiebaUsernameSuffix } from '../utils/TiebaName';
import { connectTiebaUsername, TiebaUsernameState } from '../model/AppStorageV2Models';
import { requestCommentPreview } from '../utils/ThreadCommentCache';

const SUB_POST_ANONYMOUS_NAME: string = '匿名';

/** 信息流正文内联表情切片（解析 #(滑稽) 等贴吧表情标记） */
class FeedTextSegment {
  isEmoji: boolean;
  value: string;

  constructor(isEmoji: boolean, value: string) {
    this.isEmoji = isEmoji;
    this.value = value;
  }
}

function parseFeedEmoticonSegments(text: string): FeedTextSegment[] {
  const segments: FeedTextSegment[] = [];
  let cursor: number = 0;
  const len: number = text.length;
  while (cursor < len) {
    const start: number = text.indexOf('#(', cursor);
    if (start < 0) {
      segments.push(new FeedTextSegment(false, text.slice(cursor)));
      break;
    }
    const end: number = text.indexOf(')', start + 2);
    if (end < 0) {
      segments.push(new FeedTextSegment(false, text.slice(cursor)));
      break;
    }
    if (start > cursor) {
      segments.push(new FeedTextSegment(false, text.slice(cursor, start)));
    }
    const emoName: string = text.slice(start + 2, end);
    const emoInfo: EmoticonInfo | undefined = EmoticonManager.getEmoticonByName(emoName);
    if (emoInfo !== undefined && EmoticonManager.hasRenderableEmoticon(emoInfo.id)) {
      segments.push(new FeedTextSegment(true, emoInfo.id));
    } else {
      segments.push(new FeedTextSegment(false, text.slice(start, end + 1)));
    }
    cursor = end + 1;
  }
  return segments;
}

@Preview
@ReusableV2
@ComponentV2
export struct ThreadCard {
  @Require @Param thread: ThreadInfo;
  @Event onCardClick?: () => void;
  /** 点击作者区域（头像/名字）回调。设置后用 HitTestMode.Block 阻断冒泡到卡片 onClick */
  @Event onAuthorClick?: () => void;
  /** 点赞/取消赞回调（issue #17），由父组件调 TiebaAPI.agree/unagree 并刷新 threadList */
  @Event onAgreeClick?: (thread: ThreadInfo) => void;
  /** 点踩/取消点踩回调（issue #17） */
  @Event onDisagreeClick?: (thread: ThreadInfo) => void;
  /** 评论按钮回调（issue #17），父组件弹输入框或提示开发中 */
  @Event onCommentClick?: (thread: ThreadInfo) => void;
  @Event onForumClick?: (thread: ThreadInfo) => void;
  @Event onSubPostClick?: (subPost: SubPostInfo) => void;
  /** 屏蔽当前贴吧回调（推荐流菜单） */
  @Event onBlockForumClick?: (forumName: string) => void;

  /** 卡片按下态（对齐 iOS 原型 :active 缩放 0.98 + 透明度 0.85） */
  @Local isPressed: boolean = false;
  @Local tiebaUsernameState: TiebaUsernameState = connectTiebaUsername();
  @Local themeState: ThemeState = connectTheme();
  @Param commentPreviewEnabled: boolean = false;
  // 图片加载模式（0=智能原图 1=智能无图 2=始终原图 3=始终无图），由父组件从 AppStorageV2 传入
  @Param imageLoadType: number = 0;
  // 当前是否 WiFi 网络，由父组件从 AppStorageV2 传入
  @Param isWifi: boolean = false;
  // 吧内帖子评论预览：通过 PbPage API 懒加载前几楼回复内容
  // FrsPage API 不返回楼层列表，需额外请求；用 ThreadCommentCache 全局缓存避免重复请求
  @Local previewPosts: SubPostInfo[] = [];
  @Local isPreviewLoading: boolean = false;
  private isSharing: boolean = false;

  // A11 GlobalReuse：组件被复用时重置按压态，避免上次卡片在按压状态被回收后残留
  // 同时重置评论预览状态，并对新 thread.tid 触发懒加载（如果 commentPreviewEnabled 启用）
  aboutToReuse(params: Object): void {
    this.isPressed = false;
    this.previewPosts = [];
    this.isPreviewLoading = false;
    if (this.commentPreviewEnabled && this.thread.replyNum > 0) {
      this.loadCommentPreview();
    }
  }

  // 组件首次创建时触发懒加载（aboutToReuse 仅在复用时触发）
  aboutToAppear(): void {
    if (this.commentPreviewEnabled && this.thread.replyNum > 0) {
      this.loadCommentPreview();
    }
  }

  /**
   * 懒加载评论预览（前几楼回复内容）
   * - 通过 ThreadCommentCache 统一路由：LRU 缓存命中直接显示；未命中走并发限流排队请求，
   *   避免列表滚动时每张卡片同时发起 PbPage 请求造成网络/解析突发（性能优化 2026-09）
   * - 失败静默处理，不阻塞 UI
   */
  private loadCommentPreview(): void {
    const tid: number = this.thread.tid;
    if (tid <= 0) {
      return;
    }
    const loading: boolean = requestCommentPreview(tid, (posts: SubPostInfo[]) => {
      if (this.thread.tid === tid) {
        this.previewPosts = posts;
        this.isPreviewLoading = false;
      }
    });
    this.isPreviewLoading = loading;
  }

  @Builder
  SingleMedia() {
    Image(getMediaImageUrl(
      this.thread.mediaList[0].thumbnail,
      this.thread.mediaList[0].url,
      this.imageLoadType,
      this.isWifi,
      this.thread.mediaList[0].animatedUrl
    ))
      .width('100%')
      .aspectRatio(1.6)
      .objectFit(ImageFit.Cover)
      .borderRadius(10)
      .backgroundColor($r('app.color.input_background'))
      .alt($r('app.media.startIcon'))
      // A5 图片优化：网络大图异步加载避免阻塞 UI + 高质量插值缓解锯齿 + 自动降采样减少内存
      .syncLoad(false)
      .interpolation(ImageInterpolation.High)
      .autoResize(this.thread.mediaList[0].animatedUrl.length === 0)
      .onError(() => {
        // 媒体图加载失败静默处理：alt 占位图会自动显示
      })
      // #92 HitTestMode.Transparent：让 Image 既响应 onClick 跳转，又让触控穿透到父 List
      // 解决 fling 期间手指碰到图片时 List 收不到 Down 事件导致触控丢失
      .hitTestBehavior(HitTestMode.Transparent)
      // #132 共享元素转场：源端 Image 绑定 shareId，与模态目标端 Image 配对
      // 必须配合 .transition() 使用，否则转场不触发且 Image 不显示
      .geometryTransition(`card_${this.thread.tid}_0`, { follow: true })
      .transition(TransitionEffect.OPACITY.animation({ duration: 350, curve: Curve.Friction }))
      .onClick(() => {
        this.openImageViewer(0);
      })
  }

  // 视频帖封面：显示视频缩略图 + 中央播放图标，点击跳转帖子详情页（ThreadPage）而非图片查看器
  // 视频帖通过 thread.videoInfo.videoUrl 非空识别（ThreadInfo.proto field 79 = video_info）
  @Builder
  VideoMedia() {
    Stack() {
      Image(getMediaImageUrl(
        this.thread.videoInfo.thumbnailUrl,
        this.thread.videoInfo.thumbnailUrl,
        this.imageLoadType,
        this.isWifi
      ))
        .width('100%')
        .aspectRatio(this.computeVideoAspectRatio())
        .objectFit(ImageFit.Cover)
        .borderRadius(RADIUS_SM)
        .backgroundColor($r('app.color.input_background'))
        .alt($r('app.media.startIcon'))
        .syncLoad(false)
        .interpolation(ImageInterpolation.High)
        .autoResize(true)
        .onError(() => { /* 视频封面加载失败静默处理 */ })

      // 中央播放图标（半透明圆形背景 + play_fill）
      Stack() {
        Circle({ width: 56, height: 56 })
          .fill('rgba(0, 0, 0, 0.5)')
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(28)
          .fontColor([Color.White])
      }
      .width(56)
      .height(56)
    }
    .width('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onClick(() => {
      // 视频帖点击跳转帖子详情页，不跳图片查看器
      if (this.onCardClick) {
        this.onCardClick();
      }
    })
  }

  // 两张或三张缩略图等宽，超过 3 张时在第 3 张右下角叠加 +N 胶囊角标
  @Builder
  GridMedia(index: number) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Image(getMediaImageUrl(
        this.thread.mediaList[index].thumbnail,
        this.thread.mediaList[index].url,
        this.imageLoadType,
        this.isWifi,
        this.thread.mediaList[index].animatedUrl
      ))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .borderRadius(RADIUS_SM)
        .backgroundColor($r('app.color.input_background'))
        .alt($r('app.media.startIcon'))
        // A5 图片优化：网格缩略图异步加载避免阻塞滑动 + 自动降采样减少内存 + 错误兜底
        .syncLoad(false)
        .interpolation(ImageInterpolation.Medium)
        .autoResize(this.thread.mediaList[index].animatedUrl.length === 0)
        .onError(() => {
          // 缩略图加载失败静默处理：alt 占位图会自动显示
        })
        // #92 HitTestMode.Transparent：让 Image 既响应 onClick 跳转，又让触控穿透到父 List
        .hitTestBehavior(HitTestMode.Transparent)
        // #132 共享元素转场：源端 Image 绑定 shareId，与模态目标端 Image 配对
        // 必须配合 .transition() 使用，否则转场不触发且 Image 不显示
        .geometryTransition(`card_${this.thread.tid}_${index}`, { follow: true })
        .transition(TransitionEffect.OPACITY.animation({ duration: 350, curve: Curve.Friction }))
        .onClick(() => {
          this.openImageViewer(index);
        })

      if (index === 2 && this.thread.mediaList.length > 3) {
        Text(`+${this.thread.mediaList.length - 3}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor('rgba(0, 0, 0, 0.56)')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(RADIUS_PILL)
          .margin({ right: 6, bottom: 6 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .layoutWeight(1)
    .aspectRatio(this.thread.mediaList.length === 2 ? 1.45 : 1)
    .margin({ right: index < Math.min(this.thread.mediaList.length, 3) - 1 ? 5 : 0 })
  }

  /** 计算视频封面宽高比（videoWidth/videoHeight 有效时用实际比例，否则默认 16:9） */
  private computeVideoAspectRatio(): number {
    if (this.thread.videoInfo.videoWidth > 0 && this.thread.videoInfo.videoHeight > 0) {
      return this.thread.videoInfo.videoWidth / this.thread.videoInfo.videoHeight;
    }
    return 16 / 9;
  }

  /**
   * #132 打开图片查看器（共享元素转场）
   * 先传当前可用大图秒开，同时携带 thread.tid 让查看器后台自动从 PbPage 拉取带有效签名的官方 origin_src 无损原图并无缝升级
   */
  private openImageViewer(index: number): void {
    const fallbackUrls: string[] = this.thread.mediaList.map((m: MediaInfo) =>
      m.animatedUrl.length > 0 ? m.animatedUrl : m.url);
    const highResUrls: string[] = this.thread.mediaList.map((m: MediaInfo) =>
      m.animatedUrl.length > 0 ? m.animatedUrl : resolveHighResImageUrl(m.url));
    const shareId: string = `card_${this.thread.tid}_${index}`;
    RouterUtil.pushWithTransition(
      RouterUtil.ROUTE_IMAGE_VIEWER_PAGE,
      new ImageViewerNavParams(highResUrls, index, shareId, fallbackUrls, this.thread.tid),
      this.getUIContext()
    );
  }

  @Builder
  ForumChip() {
    Row({ space: 6 }) {
      if (this.thread.forumInfo.avatar.length > 0) {
        Image(getAvatarImageUrl(this.thread.forumInfo.avatar, this.imageLoadType, this.isWifi))
          .width(16)
          .height(16)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.startIcon'))
          .syncLoad(false)
      }
      Text($r('app.string.android_forum_name', this.thread.forumName))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: 6, right: 10, top: 4, bottom: 4 })
    .borderRadius(RADIUS_PILL)
    .backgroundColor($r('app.color.input_background'))
    .margin({ top: 10 })
    .onClick(() => {
      this.onForumClick?.(this.thread);
    })
  }

  /**
   * #236 置顶帖简洁样式（对齐 Android 原版 TopThreadItem）
   * 不渲染头像/摘要/媒体/操作栏，仅显示：
   * - 左侧"置顶"Chip（圆角 3vp，黄底黄字，对齐 Android RoundedCornerShape(3.dp)）
   * - 右侧单行标题（maxLines=1 溢出省略，15sp Medium）
   * 整行点击触发 onCardClick，保留与正常卡片一致的外层容器样式
   * （card_background + borderRadius 10 + 16vp 左右安全边距）
   * 注意：外层 Column 已有 padding left/right 16vp，此处仅设 top/bottom 8vp 避免叠加
   */
  @Builder
  TopThreadItem() {
    Row() {
      // 置顶 Chip：圆角 3vp（接近 Android RoundedCornerShape(3.dp)，几乎方形）
      // 黄底黄字对齐 tag_top / tag_top_light 配色，12sp Bold
      Text($r('app.string.top_label'))
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.tag_top'))
        .backgroundColor($r('app.color.tag_top_light'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(3)

      // 标题：单行截断，15sp Medium，layoutWeight 1 占满剩余空间
      // Android 用 subtitle2 + 15sp，对齐为 15sp Medium
      // 标题与 Chip 间距 12vp（对齐 Android spacedBy 16.dp，略减避免视觉过宽）
      Text(this.thread.title.length > 0 ? this.thread.title : this.thread.content)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 12 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  HotPostPreview() {
    Column() {
      // 加载中提示（轻量，不阻塞布局）
      if (this.isPreviewLoading && this.previewPosts.length === 0) {
        Row() {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.post_metadata'))
            .margin({ right: 6 })
          Text($r('app.string.comment_preview_loading'))
            .fontSize(12)
            .fontColor($r('app.color.post_metadata'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 4, bottom: 4 })
      }

      // 前几楼回复预览（作者名：内容）
      ForEach(this.previewPosts,
        (post: SubPostInfo, index: number) => {
          Text() {
            Span(formatTiebaName(post.author.nickname, post.author.name, this.tiebaUsernameState.value) ||
              SUB_POST_ANONYMOUS_NAME)
              .fontColor(this.themeState.primary)
            if (post.fragments.length > 0) {
              Span('：')
                .fontColor($r('app.color.text_primary'))
              ForEach(post.fragments, (frag: ContentFragment, fIdx: number) => {
                if (frag.type === ContentFragmentType.EMOJI) {
                  if (EmoticonManager.hasRenderableEmoticon(frag.text)) {
                    ImageSpan(EmoticonManager.getEmoticonResource(frag.text))
                      .width(15)
                      .height(15)
                      .verticalAlign(ImageSpanAlignment.CENTER)
                  } else {
                    Span(EmoticonManager.getFallbackLabel(frag.text, frag.emojiDesc))
                      .fontColor($r('app.color.text_primary'))
                  }
                } else if (frag.type === ContentFragmentType.LINK || frag.type === ContentFragmentType.AT) {
                  Span(frag.text)
                    .fontColor(this.themeState.primary)
                } else if (frag.type === ContentFragmentType.VIDEO) {
                  Span('[视频]')
                    .fontColor($r('app.color.text_secondary'))
                } else {
                  Span(frag.text)
                    .fontColor($r('app.color.text_primary'))
                }
              }, (frag: ContentFragment, fIdx: number) => `hp_prev_${post.spid}_${fIdx}_${frag.type}_${frag.text}`)
            } else if (post.content.length > 0) {
              Span('：' + post.content)
                .fontColor($r('app.color.text_primary'))
            }
          }
          .fontSize(13)
          .lineHeight(19)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
          .onClick(() => {
            if (this.onSubPostClick) {
              this.onSubPostClick(post);
            }
          })
        }, (post: SubPostInfo, index: number) => `preview_post_${post.spid}_${index}`)

      // 查看全部回复（replyNum > 0 时显示）
      if (this.thread.replyNum > 0 && this.previewPosts.length > 0) {
        Text($r('app.string.view_all_sub_posts', this.thread.replyNum))
          .fontSize(13)
          .fontColor(this.themeState.primary)
          .margin({ top: 6 })
          .onClick(() => {
            if (this.previewPosts.length > 0 && this.onSubPostClick) {
              this.onSubPostClick(this.previewPosts[0]);
            }
          })
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.input_background'))
    .padding(12)
    .margin({ top: 10 })
    .hitTestBehavior(HitTestMode.Transparent)
    .onClick(() => {
      if (this.onCardClick) {
        this.onCardClick();
      }
    })
  }

  private async shareThread(): Promise<void> {
    const host = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!host || this.thread.tid <= 0 || this.isSharing) {
      return;
    }
    this.isSharing = true;
    try {
      const controller = new systemShare.ShareController(buildHyperlinkShareData(
        buildThreadShareUrl(this.thread.tid), this.thread.title, this.thread.content
      ));
      controller.on('dismiss', () => {
        this.isSharing = false;
      });
      await controller.show(host, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (err) {
      this.isSharing = false;
      Logger.error('ThreadCard', (err as Error).message);
    }
  }

  private buildMoreMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.onDisagreeClick) {
      items.push({
        value: getResourceString(this.thread.isDisagreed ?
          $r('app.string.android_undo_dislike') : $r('app.string.android_dislike')),
        action: () => this.onDisagreeClick?.(this.thread)
      });
    }
    if (this.onBlockForumClick && this.thread.forumName.length > 0) {
      const targetForum: string = this.thread.forumName;
      items.push({
        value: `屏蔽「${targetForum}吧」`,
        action: () => this.onBlockForumClick?.(targetForum)
      });
    }
    return items;
  }

  @Builder
  FeedAuthor() {
    Row() {
      Row({ space: 8 }) {
        Image(getAvatarImageUrl(this.thread.author.avatar, this.imageLoadType, this.isWifi))
          .width(32)
          .height(32)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.input_background'))
          .alt($r('app.media.startIcon'))
          .syncLoad(false)
          .interpolation(ImageInterpolation.Low)
          .onClick(() => this.onAuthorClick?.())
        Column({ space: 2 }) {
          Text() {
            Span(getTiebaPrimaryName(this.thread.author.nickname, this.thread.author.name))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (getTiebaUsernameSuffix(this.thread.author.nickname, this.thread.author.name,
              this.tiebaUsernameState.value).length > 0) {
              Span(getTiebaUsernameSuffix(this.thread.author.nickname, this.thread.author.name,
                this.tiebaUsernameState.value))
                .fontSize(12)
                .fontWeight(FontWeight.Normal)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .maxLines(this.tiebaUsernameState.value ? 2 : 1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => this.onAuthorClick?.())
          Text(this.thread.author.ipAddress.length > 0
            ? `${formatRelativeTime(this.thread.createTime)} · IP属地: ${this.thread.author.ipAddress}`
            : formatRelativeTime(this.thread.createTime))
            .fontSize(11)
            .fontColor($r('app.color.text_caption'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)

      if (this.onDisagreeClick || (this.onBlockForumClick && this.thread.forumName.length > 0)) {
        Row() {
          Image($r('app.media.android_chevron_down'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.post_metadata'))
        }
        .width(40)
        .height(36)
        .justifyContent(FlexAlign.End)
        .accessibilityText($r('app.string.menu_more'))
        .bindMenu(this.buildMoreMenuItems())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 })
  }

  @Builder
  FeedContent() {
    Column() {
      this.FeedAuthor()

      if (this.thread.title.length > 0) {
        Text() {
          if (this.thread.isGood) {
            Span($r('app.string.good_label'))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.themeState.primary)
            Span(' ')
          }
          Span(this.thread.title)
        }
        .width('100%')
        .fontSize(15.5)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(22)
        .margin({ bottom: this.thread.content.length > 0 ? 4 : 8 })
      }

      if (this.thread.content.length > 0) {
        if (this.thread.content.indexOf('#(') >= 0) {
          Text() {
            ForEach(parseFeedEmoticonSegments(this.thread.content), (seg: FeedTextSegment, segIdx: number) => {
              if (seg.isEmoji) {
                ImageSpan(EmoticonManager.getEmoticonResource(seg.value))
                  .width(17)
                  .height(17)
                  .verticalAlign(ImageSpanAlignment.CENTER)
              } else {
                Span(seg.value)
              }
            }, (seg: FeedTextSegment, segIdx: number) => `${this.thread.tid}_seg_${segIdx}_${seg.value}`)
          }
          .width('100%')
          .fontSize(14)
          .fontColor(this.thread.title.length > 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .maxLines(this.thread.title.length > 0 ? 3 : 5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)
          .margin({ bottom: 8 })
        } else {
          Text(this.thread.content)
            .width('100%')
            .fontSize(14)
            .fontColor(this.thread.title.length > 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
            .maxLines(this.thread.title.length > 0 ? 3 : 5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(20)
            .margin({ bottom: 8 })
        }
      }

      // 媒体区域：视频帖优先渲染 VideoMedia（封面+播放图标，点击跳帖子详情）
      // 单图和多图使用固定比例的裁切预览。
      if (this.thread.videoInfo.videoUrl.length > 0) {
        this.VideoMedia()
      } else if (this.thread.mediaList.length > 0) {
        if (this.thread.mediaList.length === 1) {
          this.SingleMedia()
        } else {
          Row() {
            this.GridMedia(0)
            if (this.thread.mediaList.length > 1) {
              this.GridMedia(1)
            }
            if (this.thread.mediaList.length > 2) {
              this.GridMedia(2)
            }
          }
          .width('100%')
          // #92 HitTestMode.Transparent：让触控穿透到父 List
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }

      if (this.thread.forumName.length > 0) {
        this.ForumChip()
      }

      // 吧内帖子评论预览：commentPreviewEnabled 启用 + 有回复时显示
      // 评论数据通过 PbPage API 懒加载（aboutToReuse / 首次渲染触发）
      if (this.commentPreviewEnabled && this.thread.replyNum > 0 &&
        (this.isPreviewLoading || this.previewPosts.length > 0)) {
        this.HotPostPreview()
      }

      // 直接读取 this.thread.*，避免 @ReusableV2 下多参数按值传递 @Builder 导致复用卡片显示上一条帖子的旧评论/点赞数
      Row() {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.share'))
            .fontSize(16)
            .fontColor([$r('app.color.post_metadata')])
          Text(this.thread.shareNum > 0 ? formatCount(this.thread.shareNum) : $r('app.string.menu_share'))
            .fontSize(12)
            .fontColor($r('app.color.post_metadata'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .height(36)
        .hitTestBehavior(HitTestMode.Transparent)
        .onClick(() => {
          this.shareThread();
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(16)
            .fontColor([$r('app.color.post_metadata')])
          Text(this.thread.replyNum > 0 ? formatCount(this.thread.replyNum) : $r('app.string.reply_button_label'))
            .fontSize(12)
            .fontColor($r('app.color.post_metadata'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .height(36)
        .hitTestBehavior(HitTestMode.Transparent)
        .onClick(() => this.onCommentClick?.(this.thread))

        Row({ space: 5 }) {
          SymbolGlyph(this.thread.isAgreed ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(16)
            .fontColor([this.thread.isAgreed ? this.themeState.primary : $r('app.color.post_metadata')])
          Text(this.thread.agreeNum > 0 ? formatCount(this.thread.agreeNum) : $r('app.string.android_agree'))
            .fontSize(12)
            .fontColor(this.thread.isAgreed ? this.themeState.primary : $r('app.color.post_metadata'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .height(36)
        .hitTestBehavior(HitTestMode.Transparent)
        .onClick(() => this.onAgreeClick?.(this.thread))
      }
      .width('100%')
      .margin({ top: 4, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.thread.isTop) {
        this.TopThreadItem()
      } else {
        this.FeedContent()
      }
      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color($r('app.color.divider'))
    }
    .width('100%')
    .padding({ top: this.thread.isTop ? 0 : 14, left: 16, right: 16 })
    .backgroundColor(this.isPressed ? $r('app.color.input_background') : $r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start)
    // #93 HitTestMode.Transparent：让卡片 onClick 仍能触发，同时让触控穿透到父 List
    // 修复热榜/关注/推荐 Tab 滑动被拦截问题（对齐 ThreadPage PostItem 实现）
    .hitTestBehavior(HitTestMode.Transparent)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
    .onClick(() => {
      if (this.onCardClick) {
        this.onCardClick();
      }
    })
  }
}

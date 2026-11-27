import { HdsNavDestination, ScrollEffectType } from '@kit.UIDesignKit';
import { MaterialLevelState, connectMaterialLevel } from '../../model/AppStorageV2Models';
import { MATERIAL_TYPE_IMMERSIVE, resolveMaterialLevel } from '../../theme/MaterialUtil';
import { connectTheme, ThemeState } from '../../theme/ThemeManager';
import { RADIUS_PILL } from '../../theme/DesignTokens';
import { BrowseHistoryItem, BrowseHistoryManager } from '../../utils/BrowseHistoryManager';
import { getResourceString } from '../../utils/ResourceUtil';
import { getStatusBarHeight } from '../../utils/StatusBarUtil';
import { formatRelativeTime } from '../../utils/TimeUtil';
import { RouterUtil, ThreadNavParams } from '../../utils/RouterUtil';
import { Logger } from '../../utils/Logger';

const TAG: string = 'BrowseHistoryPage';
const TITLE_BAR_HEIGHT: number = 48;

@Builder
export function BrowseHistoryPageBuilder() {
  BrowseHistoryPage()
}

@ComponentV2
export struct BrowseHistoryPage {
  private scroller: Scroller = new Scroller();
  private isDestroyed: boolean = false;

  @Local statusBarHeight: number = 36;
  @Local items: BrowseHistoryItem[] = [];
  @Local searchKeyword: string = '';
  @Local isLoading: boolean = true;
  @Local themeState: ThemeState = connectTheme();
  @Local materialLevelState: MaterialLevelState = connectMaterialLevel();

  async aboutToAppear() {
    try {
      this.statusBarHeight = await getStatusBarHeight(this.getUIContext());
    } catch (err) {
      Logger.error(TAG, `[BrowseHistoryPage] getStatusBarHeight failed: ${(err as Error).message}`);
    }
    await this.loadHistory();
  }

  aboutToDisappear(): void {
    this.isDestroyed = true;
  }

  private async loadHistory(): Promise<void> {
    try {
      const list: BrowseHistoryItem[] = await BrowseHistoryManager.load();
      if (!this.isDestroyed) {
        this.items = list;
      }
    } catch (err) {
      Logger.error(TAG, `[BrowseHistoryPage] loadHistory failed: ${(err as Error).message}`);
    } finally {
      if (!this.isDestroyed) {
        this.isLoading = false;
      }
    }
  }

  private async removeItem(tid: number): Promise<void> {
    try {
      await BrowseHistoryManager.remove(tid);
      if (!this.isDestroyed) {
        this.items = this.items.filter((it: BrowseHistoryItem) => it.tid !== tid);
      }
    } catch (err) {
      Logger.error(TAG, `[BrowseHistoryPage] removeItem failed: ${(err as Error).message}`);
    }
  }

  private confirmClearAll(): void {
    if (this.items.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: getResourceString($r('app.string.browse_history_clear_title')),
      message: getResourceString($r('app.string.browse_history_clear_message')),
      buttons: [
        { text: getResourceString($r('app.string.cancel_button')), color: $r('app.color.text_secondary') },
        { text: getResourceString($r('app.string.browse_history_clear_action')), color: $r('app.color.error') }
      ]
    }).then((result) => {
      if (result.index === 1) {
        BrowseHistoryManager.clear().then(() => {
          if (!this.isDestroyed) {
            this.items = [];
            this.getUIContext().getPromptAction().showToast({
              message: getResourceString($r('app.string.browse_history_cleared'))
            });
          }
        }).catch((err: Error) => {
          Logger.error(TAG, `[BrowseHistoryPage] clear failed: ${err.message}`);
        });
      }
    }).catch((err: Error) => {
      Logger.error(TAG, `[BrowseHistoryPage] clear dialog failed: ${err.message}`);
    });
  }

  @Builder
  DeleteAction(tid: number) {
    Row() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(18)
        .fontColor([Color.White])
      Text($r('app.string.browse_history_delete'))
        .fontSize(13)
        .fontColor(Color.White)
        .margin({ left: 4 })
    }
    .width(76)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.error'))
    .onClick(() => {
      this.removeItem(tid);
    })
  }

  @Builder
  HistoryRow(item: BrowseHistoryItem) {
    Column({ space: 6 }) {
      Text(item.title.length > 0 ? item.title : `#${item.tid}`)
        .width('100%')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(22)

      Row({ space: 8 }) {
        if (item.forumName.length > 0) {
          Text($r('app.string.android_forum_name', item.forumName))
            .fontSize(11.5)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.input_background'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(RADIUS_PILL)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (item.authorName.length > 0) {
          Text(item.authorName)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
        }
        Blank()
        if (item.viewedAt > 0) {
          Text(formatRelativeTime(item.viewedAt))
            .fontSize(11.5)
            .fontColor($r('app.color.text_caption'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => {
      RouterUtil.push(RouterUtil.ROUTE_THREAD_PAGE, new ThreadNavParams(item.tid));
    })
  }

  private getFilteredItems(): BrowseHistoryItem[] {
    const kw: string = this.searchKeyword.trim().toLowerCase();
    if (kw.length === 0) {
      return this.items;
    }
    return this.items.filter((item: BrowseHistoryItem) =>
      item.title.toLowerCase().indexOf(kw) >= 0 ||
      item.forumName.toLowerCase().indexOf(kw) >= 0 ||
      item.authorName.toLowerCase().indexOf(kw) >= 0
    );
  }

  build() {
    HdsNavDestination() {
      Column() {
        if (this.items.length > 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(15)
              .fontColor([$r('app.color.text_caption')])
            TextInput({ placeholder: '搜索标题 / 贴吧 / 作者', text: $$this.searchKeyword })
              .layoutWeight(1)
              .height(36)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_caption'))
              .backgroundColor(Color.Transparent)
              .padding({ left: 0, right: 0 })
            if (this.searchKeyword.length > 0) {
              Text('清除')
                .fontSize(12.5)
                .fontColor(this.themeState.primary)
                .onClick(() => {
                  this.searchKeyword = '';
                })
            }
          }
          .width('100%')
          .height(38)
          .padding({ left: 12, right: 12 })
          .borderRadius(19)
          .backgroundColor($r('app.color.input_background'))
          .alignItems(VerticalAlign.Center)
          .margin({ left: 16, right: 16, top: 6, bottom: 8 })
        }

        if (!this.isLoading && this.getFilteredItems().length === 0) {
          Column({ space: 8 }) {
            Text(this.items.length === 0 ? $r('app.string.browse_history_empty') : '没有找到匹配的浏览记录')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.getFilteredItems(), (item: BrowseHistoryItem) => {
              ListItem() {
                this.HistoryRow(item)
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.DeleteAction(item.tid)
                  }
                },
                edgeEffect: SwipeEdgeEffect.None
              })
            }, (item: BrowseHistoryItem) => `${item.tid}_${item.viewedAt}`)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 16, endMargin: 16 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8, true)
          .clip(false)
          .backgroundColor($r('app.color.card_background'))
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight + TITLE_BAR_HEIGHT })
      .backgroundColor($r('app.color.card_background'))
    }
    .titleBar({
      content: {
        title: {
          mainTitle: $r('app.string.browse_history_title')
        },
        menu: {
          maxCount: 1,
          value: [{
            content: {
              icon: $r('sys.symbol.trash'),
              label: $r('app.string.browse_history_clear_action'),
              isEnabled: this.items.length > 0,
              action: () => {
                this.confirmClearAll();
              }
            }
          }]
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: MATERIAL_TYPE_IMMERSIVE,
          materialLevel: resolveMaterialLevel(this.materialLevelState.value)
        },
        originalStyle: {
          contentStyle: { menuStyle: { iconColor: this.themeState.primary } }
        },
        scrollEffectStyle: {
          contentStyle: { menuStyle: { iconColor: this.themeState.primary } }
        }
      },
      avoidLayoutSafeArea: true
    })
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.card_background'))
  }
}

// 图片查看器页面
// 基于 @rv/image-preview 三方库实现缩放/平移/双击等手势交互
// 调用方：RouterUtil.pushImageViewer(urls, index)
//
// 保存到相册流程：
// - 长按图片 → 异步下载到应用沙箱临时文件（filesDir/imgviewer_<ts>.<ext>）
// - 下载完成后通过 bindSheet 弹出保存确认底部弹窗
// - 用户点击 SaveButton 授予 5 秒临时授权 → applyChanges 创建相册资产
// - 保存完成或失败后清理沙箱临时文件

import { HdsNavDestination } from '@kit.UIDesignKit';
import { http } from '@kit.NetworkKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import fs from '@ohos.file.fs';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getResourceString } from '../../utils/ResourceUtil';
import { getStatusBarHeight } from '../../utils/StatusBarUtil';
import { detectAnimatedImageExt } from '../../utils/MediaAnimation';
import { VibratorUtil } from '../../utils/VibratorUtil';
import { RouterUtil, ImageViewerNavParams } from '../../utils/RouterUtil';
import { ImagePreview, PreviewDirection } from '@rv/image-preview';
import { Logger } from '../../utils/Logger';

const TAG: string = 'ImageViewerPage';

// Swiper 切换动画时长（ms）
const SWIPER_ANIM_DURATION_MS: number = 200;

// #165 [A4-S5] Navigation 路由表 @Builder：供 router_map.json 的 buildFunction 引用
@Builder
export function ImageViewerPageBuilder() {
  ImageViewerPage()
}

@ComponentV2
export struct ImageViewerPage {
  @Local imageUrls: string[] = [];
  @Local fallbackUrls: string[] = [];
  @Local currentIndex: number = 0;
  @Local statusBarHeight: number = 36;
  // 共享元素转场 ID（源端 Image 与目标端 Image 绑定同 id）
  @Local shareId: string = '';
  // bindSheet 保存弹窗状态
  @Local showSaveSheet: boolean = false;
  @Local isDownloadingForSave: boolean = false;
  @Local pendingSaveUrl: string = '';
  // 沙箱临时文件路径
  private sandboxFilePath: string = '';
  // 生命周期守护
  private isDestroyed: boolean = false;

  private showToast(message: string): void {
    this.getUIContext()?.getPromptAction().showToast({ message });
  }

  aboutToDisappear(): void {
    this.isDestroyed = true;
    this.cleanupSandboxFile();
  }

  async aboutToAppear() {
    const paramsStack: Object[] = RouterUtil.getStack().getParamByName(RouterUtil.ROUTE_IMAGE_VIEWER_PAGE) as Object[];
    if (paramsStack && paramsStack.length > 0) {
      const params = paramsStack[paramsStack.length - 1] as ImageViewerNavParams;
      if (params && params.urls && params.urls.length > 0) {
        this.imageUrls = params.urls.slice();
        this.fallbackUrls = params.fallbackUrls ? params.fallbackUrls.slice() : [];
        const rawIdx: number = params.index;
        const maxIdx: number = this.imageUrls.length - 1;
        this.currentIndex = Math.max(0, Math.min(rawIdx, maxIdx));
        this.shareId = params.shareId;
      }
    }
    try {
      this.statusBarHeight = await getStatusBarHeight(this.getUIContext());
    } catch (err) {
      Logger.warn(TAG, `[ImageViewer] getStatusBarHeight failed: ${(err as Error).message}`);
    }
  }

  /** 高清原图加载失败时自动回退到原始 big_pic，避免防盗链导致白图 */
  private fallbackImageAt(index: number): void {
    if (index < 0 || index >= this.imageUrls.length || index >= this.fallbackUrls.length) {
      return;
    }
    const fallback: string = this.fallbackUrls[index];
    if (fallback.length > 0 && this.imageUrls[index] !== fallback) {
      const next: string[] = this.imageUrls.slice();
      next[index] = fallback;
      this.imageUrls = next;
    }
  }

  private closeViewer(): void {
    RouterUtil.backWithTransition(this.getUIContext());
  }

  async handleLongPress(url: string): Promise<void> {
    if (this.isDownloadingForSave || this.showSaveSheet) {
      return;
    }
    this.pendingSaveUrl = url;
    this.isDownloadingForSave = true;
    this.showSaveSheet = true;
    try {
      const imageData = await this.downloadImage(url);
      if (this.isDestroyed) {
        return;
      }
      if (!imageData || imageData.byteLength === 0) {
        this.showToast(getResourceString($r('app.string.save_failed')));
        this.isDownloadingForSave = false;
        this.showSaveSheet = false;
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const detectedExt: string = detectAnimatedImageExt(imageData);
      const ext: string = detectedExt.length > 0 ? detectedExt : this.inferExtension(url);
      const fileName: string = `imgviewer_${Date.now()}.${ext}`;
      const filePath: string = `${context.filesDir}/${fileName}`;
      const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        await fs.write(file.fd, imageData);
      } finally {
        await fs.close(file);
      }
      this.sandboxFilePath = filePath;
      this.isDownloadingForSave = false;
    } catch (err) {
      Logger.error(TAG, `[ImageViewer] download to sandbox failed: ${(err as Error).message}`);
      this.showToast(getResourceString($r('app.string.save_failed')));
      this.isDownloadingForSave = false;
      this.showSaveSheet = false;
    }
  }

  async onSaveButtonClick(result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      this.showSaveSheet = false;
      this.cleanupSandboxFile();
      return;
    }
    this.showSaveSheet = false;
    if (this.sandboxFilePath.length === 0) {
      this.cleanupSandboxFile();
      return;
    }
    try {
      this.showToast(getResourceString($r('app.string.saving_image')));
      await this.createImageAssetWithMediaChangeRequest();
      if (this.isDestroyed) {
        return;
      }
      VibratorUtil.light();
      this.showToast(getResourceString($r('app.string.save_success')));
    } catch (err) {
      const error = err as BusinessError;
      Logger.error(TAG, `[ImageViewer] save failed: code=${error.code}, message=${error.message}`);
      if (!this.isDestroyed) {
        this.showToast(`${getResourceString($r('app.string.save_failed'))}: ${error.message}`);
      }
    } finally {
      this.cleanupSandboxFile();
    }
  }

  private async createImageAssetWithMediaChangeRequest(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const fileUriStr: string = fileUri.getUriFromPath(this.sandboxFilePath);
    const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
      photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, fileUriStr);
    await helper.applyChanges(assetChangeRequest);
  }

  private async cleanupSandboxFile(): Promise<void> {
    if (this.sandboxFilePath.length === 0) {
      return;
    }
    const filePath: string = this.sandboxFilePath;
    this.sandboxFilePath = '';
    this.pendingSaveUrl = '';
    try {
      await fs.unlink(filePath);
    } catch (err) {
      Logger.warn(TAG, `[ImageViewer] cleanup sandbox file failed: ${(err as Error).message}`);
    }
  }

  private async downloadImage(url: string): Promise<ArrayBuffer> {
    const httpReq = http.createHttp();
    try {
      const response = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (response.responseCode !== 200) {
        throw new Error(`下载失败，状态码: ${response.responseCode}`);
      }
      const result = response.result;
      if (!(result instanceof ArrayBuffer)) {
        throw new Error('下载失败：响应非二进制数据');
      }
      return result;
    } finally {
      httpReq.destroy();
    }
  }

  private inferExtension(url: string): string {
    const lower: string = url.split(/[?#]/, 1)[0].toLowerCase();
    if (lower.endsWith('.png')) {
      return 'png';
    } else if (lower.endsWith('.webp')) {
      return 'webp';
    } else if (lower.endsWith('.gif')) {
      return 'gif';
    } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'jpg';
    }
    return 'jpg';
  }

  @Builder
  SaveSheetBuilder() {
    Column() {
      if (this.isDownloadingForSave) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color($r('app.color.text_primary'))
          .margin(20)
      } else {
        Text(getResourceString($r('app.string.save_image_confirm')))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 20, bottom: 16 })

        Row() {
          SaveButton({
            text: SaveDescription.DOWNLOAD,
            icon: SaveIconStyle.FULL_FILLED,
            buttonType: ButtonType.Capsule
          })
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.onSaveButtonClick(result).catch((err: BusinessError) => {
                Logger.error(TAG, `[ImageViewer] onSaveButtonClick failed: ${err.message}`);
              });
            })

          Text(getResourceString($r('app.string.cancel_button')))
            .fontSize(15)
            .fontColor('#FF453A')
            .fontWeight(FontWeight.Medium)
            .margin({ left: 24 })
            .padding({ top: 8, bottom: 8, left: 12, right: 12 })
            .onClick(() => {
              this.showSaveSheet = false;
              this.cleanupSandboxFile();
            })
        }
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 20 })
      }
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // Swiper 左右滑动切换多图，每页使用 ImagePreview 实现缩放/平移
        Swiper() {
          ForEach(this.imageUrls, (url: string, index: number) => {
            ImagePreview({
              config: {
                maxScale: 4.0,
                minScale: 1.0,
                doubleClickDefaultScale: 2.5,
                direction: PreviewDirection.Horizontal,
                onLongPress: () => {
                  VibratorUtil.heavy();
                  this.handleLongPress(url);
                }
              }
            }) {
              Image(url)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .draggable(false)
                .syncLoad(false)
                .interpolation(ImageInterpolation.High)
                .alt($r('app.media.startIcon'))
                .onError(() => {
                  // 高清原图加载失败时自动回退到原始大图 URL
                  this.fallbackImageAt(index);
                })
                // 共享元素转场：只有当前页绑定 geometryTransition
                .geometryTransition(index === this.currentIndex ? this.shareId : '')
                .clip(true)
                .transition(TransitionEffect.opacity(0.99))
            }
          }, (url: string, index: number) => `${index}_${url}`)
        }
        .index(this.currentIndex)
        .indicator(false)
        .loop(false)
        .duration(SWIPER_ANIM_DURATION_MS)
        .onChange((newIndex: number) => {
          this.currentIndex = newIndex;
        })
        .width('100%')
        .height('100%')

        // 顶部安全区操作栏：避让状态栏 + 页码胶囊 + 一键保存入口
        Row() {
          Row() {
            Image($r('app.media.ic_back'))
              .width(22)
              .height(22)
              .fillColor(Color.White)
              .syncLoad(true)
              .interpolation(ImageInterpolation.Low)
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor('rgba(0, 0, 0, 0.42)')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.closeViewer();
          })

          Blank()

          if (this.imageUrls.length > 1) {
            Text(`${this.currentIndex + 1} / ${this.imageUrls.length}`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(999)
              .backgroundColor('rgba(0, 0, 0, 0.42)')
          }

          Blank()

          Text('保存')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor('rgba(0, 0, 0, 0.42)')
            .onClick(() => {
              const activeUrl: string = this.imageUrls[this.currentIndex] ?? '';
              if (activeUrl.length > 0) {
                VibratorUtil.light();
                this.handleLongPress(activeUrl);
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .position({ x: 0, y: 0 })

        }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .bindSheet($$this.showSaveSheet, this.SaveSheetBuilder(), {
        height: SheetSize.MEDIUM,
        // #296 应用级沉浸光感开启后 sheet 背景由系统材质接管，移除 backgroundColor 避免叠加
        showClose: false,
        dragBar: true
      })
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .onBackPressed(() => {
      this.closeViewer();
      return true;
    })
  }
}
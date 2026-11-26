import { MediaInfo } from '../model/ForumModels';
import { getMediaImageUrl } from '../utils/ImageLoadUtil';

@ComponentV2
export struct InlinePostImage {
  @Require @Param media: MediaInfo;
  @Require @Param shareId: string;
  @Param imageLoadType: number = 0;
  @Param isWifi: boolean = false;
  @Param cornerRadius: number = 8;
  @Event onOpen: () => void = () => {};
  @Local loadedRatio: number = 0;

  @Monitor('shareId')
  private resetRatio(): void {
    this.loadedRatio = 0;
  }

  private resolveImageRatio(): number {
    if (this.loadedRatio > 0) {
      return this.loadedRatio;
    }
    const width = this.media.width;
    const height = this.media.height;
    return Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0 ? width / height : 4 / 3;
  }

  build() {
    Image(getMediaImageUrl(this.media.thumbnail, this.media.url, this.imageLoadType, this.isWifi,
      this.media.animatedUrl))
      .width('100%')
      .aspectRatio(this.resolveImageRatio())
      .objectFit(ImageFit.Contain)
      .borderRadius(this.cornerRadius)
      .backgroundColor($r('app.color.input_background'))
      .alt($r('app.media.startIcon'))
      .syncLoad(false)
      .interpolation(ImageInterpolation.High)
      .autoResize(this.media.animatedUrl.length === 0)
      .onComplete((event) => {
        if (this.loadedRatio === 0 && event && event.width > 0 && event.height > 0) {
          this.loadedRatio = event.width / event.height;
        }
      })
      .hitTestBehavior(HitTestMode.Transparent)
      .geometryTransition(this.shareId, { follow: true })
      .transition(TransitionEffect.OPACITY.animation({ duration: 350, curve: Curve.Friction }))
      .onClick(() => this.onOpen())
  }
}

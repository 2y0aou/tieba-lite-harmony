export function isGifImageUrl(url: string): boolean {
  return /\.gif(?:[?#]|$)/i.test(url) || /[?&](?:f|format)=gif(?:&|$)/i.test(url);
}

export function isGifImageData(data: ArrayBuffer): boolean {
  if (data.byteLength < 6) {
    return false;
  }
  const bytes = new Uint8Array(data, 0, 6);
  const signature = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
  return signature === 'GIF87a' || signature === 'GIF89a';
}

export function isWebpImageData(data: ArrayBuffer): boolean {
  if (data.byteLength < 12) {
    return false;
  }
  const bytes = new Uint8Array(data, 0, 12);
  const riff = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]);
  const webp = String.fromCharCode(bytes[8], bytes[9], bytes[10], bytes[11]);
  return riff === 'RIFF' && webp === 'WEBP';
}

export function detectAnimatedImageExt(data: ArrayBuffer): string {
  if (isGifImageData(data)) {
    return 'gif';
  }
  if (isWebpImageData(data)) {
    return 'webp';
  }
  return '';
}

export function resolveAnimatedImageUrl(dynamicUrl: string, originalUrl: string, imageType: string = '',
  activeUrl: string = ''): string {
  if (dynamicUrl.length > 0) {
    return dynamicUrl;
  }
  const type = imageType.trim().toLowerCase();
  if (isGifImageUrl(originalUrl) || type === 'gif' || type === 'image/gif') {
    return originalUrl.length > 0 ? originalUrl : activeUrl;
  }
  return isGifImageUrl(activeUrl) ? activeUrl : '';
}

/**
 * 将瀑布流/吧列表中的贴吧低清缩略图/裁切图（w%3D580、wh%3D、abpic、crop 等）
 * 还原为百度图床无损原图直链，供大图查看器高清展示（配合 fallbackUrls 失败自动回退）
 */
export function resolveHighResImageUrl(url: string): string {
  if (url.length === 0 || isGifImageUrl(url)) {
    return url;
  }
  if (/\/forum\/pic\/item\//i.test(url)) {
    return url;
  }
  if (!/(?:tiebapic|imgsa|imgsrc|hiphotos)\.baidu\.com/i.test(url)) {
    return url;
  }
  const noQuery: string = url.split(/[?#]/, 1)[0];
  const match: RegExpMatchArray | null = noQuery.match(/\/([a-f0-9]{32,})\.(jpg|jpeg|png|webp)$/i);
  if (!match || match.length < 3) {
    return url;
  }
  const hash: string = match[1];
  const ext: string = match[2].toLowerCase();
  const qIndex: number = url.indexOf('?');
  const query: string = qIndex >= 0 ? url.slice(qIndex) : '';
  return `https://tiebapic.baidu.com/forum/pic/item/${hash}.${ext}${query}`;
}

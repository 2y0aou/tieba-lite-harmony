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

export function getTiebaPrimaryName(nickname: string, username: string): string {
  const label = nickname.trim();
  const account = username.trim();
  return label.length > 0 ? label : account;
}

export function getTiebaUsernameSuffix(nickname: string, username: string, showUsername: boolean): string {
  if (!showUsername) {
    return '';
  }
  const label = nickname.trim();
  const account = username.trim();
  if (label.length > 0 && account.length > 0 && label !== account) {
    return '（' + account + '）';
  }
  return '';
}

export function formatTiebaName(nickname: string, username: string, showUsername: boolean): string {
  const primary = getTiebaPrimaryName(nickname, username);
  const suffix = getTiebaUsernameSuffix(nickname, username, showUsername);
  return suffix.length > 0 ? primary + suffix : primary;
}

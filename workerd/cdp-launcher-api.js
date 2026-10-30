// Launcher-owned CDP commands. The IWA will wire tab API replacements to these
// later; none of these stubs grants permissions or performs a native operation.
const methods = new Set([
  'Xe.showDirectoryPicker',
  'Xe.getNotificationPermission',
  'Xe.requestNotificationPermission',
  'Xe.showNotification',
  'Xe.closeNotification',
  'Xe.setAppBadge',
  'Xe.clearAppBadge',
]);

export function handleLauncherCDPCommand(message) {
  if (!message.method.startsWith('Xe.')) return null;
  const known = methods.has(message.method);
  return {
    id: message.id,
    ...(message.sessionId ? { sessionId: message.sessionId } : {}),
    error: {
      code: known ? -32000 : -32601,
      message: known ? `${message.method} is not implemented` : `Unknown launcher method: ${message.method}`,
      data: { code: known ? 'NOT_IMPLEMENTED' : 'METHOD_NOT_FOUND', method: message.method },
    },
  };
}

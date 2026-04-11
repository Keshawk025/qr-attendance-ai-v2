const { contextBridge, ipcRenderer } = require('electron');
let QRCode = null;

try {
  QRCode = require('qrcode');
} catch (_) {
  QRCode = null;
}

contextBridge.exposeInMainWorld('desktopApi', {
  setFullScreen: (enabled) => ipcRenderer.invoke('set-fullscreen', enabled),
  generateQrDataUrl: async (content) => {
    if (!QRCode) {
      throw new Error('QR generator unavailable in preload context.');
    }
    return QRCode.toDataURL(content, {
      errorCorrectionLevel: 'H',
      margin: 1,
      width: 800
    });
  }
});

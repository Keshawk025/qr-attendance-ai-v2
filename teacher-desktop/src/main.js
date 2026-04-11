const { app, BrowserWindow, ipcMain } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

let mainWindow;
let backendProcess = null;

// Avoid noisy Linux GPU/VSync warnings on systems with limited GL support.
app.disableHardwareAcceleration();
app.setName('AETTA');

const FALLBACK_ROOT_DIR = '/home/hp/Attea/attendance-suite';
const ROOT_DIR = process.env.AETTA_ROOT_DIR || (app.isPackaged ? FALLBACK_ROOT_DIR : path.join(__dirname, '..', '..'));
const BACKEND_DIR = path.join(ROOT_DIR, 'backend');
const BACKEND_URL = 'http://127.0.0.1:8000';
const BACKEND_LOG = path.join(ROOT_DIR, 'backend.log');
const PYTHON_BIN = process.env.PYTHON_BIN || '/home/hp/Attea/.venv/bin/python';
const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://postgres:REDACTED@localhost:5432/attendance_db';
const APP_ICON = path.join(ROOT_DIR, 'assets', 'app-icon.png');

async function backendIsHealthy() {
  try {
    const response = await fetch(`${BACKEND_URL}/health`);
    return response.ok;
  } catch (_) {
    return false;
  }
}

function startBackend() {
  if (backendProcess) {
    return backendProcess;
  }

  const out = fs.createWriteStream(BACKEND_LOG, { flags: 'a' });
  backendProcess = spawn(
    PYTHON_BIN,
    ['-m', 'uvicorn', 'app.main:app', '--host', '0.0.0.0', '--port', '8000'],
    {
      cwd: BACKEND_DIR,
      env: {
        ...process.env,
        DATABASE_URL,
        SQLALCHEMY_DATABASE_URL: DATABASE_URL,
      },
      detached: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    }
  );

  backendProcess.stdout.pipe(out);
  backendProcess.stderr.pipe(out);

  backendProcess.once('exit', (code) => {
    if (code !== 0) {
      console.error(`Backend exited with code ${code}`);
    }
    backendProcess = null;
  });

  return backendProcess;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    title: 'AETTA',
    width: 1400,
    height: 900,
    icon: APP_ICON,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'index.html'));
}

ipcMain.handle('set-fullscreen', (_, enabled) => {
  if (mainWindow) {
    mainWindow.setFullScreen(Boolean(enabled));
  }
  return true;
});

app.whenReady().then(async () => {
  createWindow();
  if (!(await backendIsHealthy())) {
    startBackend();
  }
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (backendProcess && !backendProcess.killed) {
    backendProcess.kill();
  }
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

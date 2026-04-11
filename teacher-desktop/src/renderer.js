const API_BASE = 'http://127.0.0.1:8000';
const VTU_CLASS_CODE = /^\d{2}[A-Z]{2,4}\d{3}$/;

const layout = document.querySelector('.layout');
const loginForm = document.getElementById('loginForm');
const sessionControls = document.getElementById('sessionControls');
const subjectCode = document.getElementById('subjectCode');
const startDynamicQr = document.getElementById('startDynamicQr');
const statusText = document.getElementById('statusText');
const countText = document.getElementById('countText');
const displayPane = document.getElementById('displayPane');
const qrImage = document.getElementById('qrImage');
const exitFullscreenBtn = document.getElementById('exitFullscreenBtn');
const verifyUsn = document.getElementById('verifyUsn');
const loadLatestPhoto = document.getElementById('loadLatestPhoto');
const downloadAttendanceReport = document.getElementById('downloadAttendanceReport');
const latestPhoto = document.getElementById('latestPhoto');
const adminLoginForm = document.getElementById('adminLoginForm');
const adminEmail = document.getElementById('adminEmail');
const adminPassword = document.getElementById('adminPassword');
const adminPanel = document.getElementById('adminPanel');
const adminListDevices = document.getElementById('adminListDevices');
const adminAuditBtn = document.getElementById('adminAuditBtn');
const adminReassignUsn = document.getElementById('adminReassignUsn');
const adminReassignDevice = document.getElementById('adminReassignDevice');
const adminReassignBtn = document.getElementById('adminReassignBtn');
const adminRevokeUsn = document.getElementById('adminRevokeUsn');
const adminRevokeBtn = document.getElementById('adminRevokeBtn');
const adminCleanupBtn = document.getElementById('adminCleanupBtn');
const adminOutput = document.getElementById('adminOutput');

let teacherToken = null;
let adminToken = null;
let currentSessionId = null;
let qrRotateTimer = null;
let pollTimer = null;

async function makeQrSource(content) {
  return `${API_BASE}/attendance/qr-image?token=${encodeURIComponent(content)}`;
}

async function api(path, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (teacherToken) {
    headers.Authorization = `Bearer ${teacherToken}`;
  }

  const response = await fetch(`${API_BASE}${path}`, { ...options, headers });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.detail || 'Request failed');
  }
  return data;
}

async function apiAdmin(path, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (adminToken) {
    headers.Authorization = `Bearer ${adminToken}`;
  }
  const response = await fetch(`${API_BASE}${path}`, { ...options, headers });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.detail || 'Admin request failed');
  }
  return data;
}

async function issueSessionAndRender() {
  const code = subjectCode.value.trim().toUpperCase();
  subjectCode.value = code;

  if (!VTU_CLASS_CODE.test(code)) {
    statusText.textContent = 'Use VTU class code format: 21CS501';
    return;
  }

  const payload = await api('/attendance/session/create', {
    method: 'POST',
    body: JSON.stringify({ subject_code: code })
  });

  currentSessionId = payload.session_id;
  const qrDataUrl = await makeQrSource(payload.qr_token);
  qrImage.src = qrDataUrl;
  qrImage.classList.remove('hidden');
  displayPane.classList.remove('hidden');
  layout.classList.add('with-display');

  const exp = new Date(payload.expires_at * 1000).toLocaleTimeString();
  statusText.textContent = `QR live and rotating. Current token expires at ${exp}`;
}

async function refreshAttendanceCount() {
  if (!currentSessionId) {
    return;
  }

  const stats = await api(`/attendance/session/${currentSessionId}/stats`);
  countText.textContent = `Attendance count: ${stats.attendance_count}`;
}

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;

  try {
    const auth = await api('/auth/teacher/login', {
      method: 'POST',
      body: JSON.stringify({ email, password })
    });

    teacherToken = auth.access_token;
    loginForm.classList.add('hidden');
    sessionControls.classList.remove('hidden');
    statusText.textContent = `Welcome ${auth.teacher_name}. Start the rotating QR session.`;
  } catch (err) {
    statusText.textContent = err.message;
  }
});

startDynamicQr.addEventListener('click', async () => {
  try {
    if (window.desktopApi && typeof window.desktopApi.setFullScreen === 'function') {
      await window.desktopApi.setFullScreen(true);
    }
    exitFullscreenBtn.classList.remove('hidden');

    await issueSessionAndRender();

    clearInterval(qrRotateTimer);
    qrRotateTimer = setInterval(() => {
      issueSessionAndRender().catch((err) => {
        statusText.textContent = err.message;
      });
    }, 25000);

    clearInterval(pollTimer);
    pollTimer = setInterval(() => {
      refreshAttendanceCount().catch((err) => {
        statusText.textContent = err.message;
      });
    }, 4000);
  } catch (err) {
    statusText.textContent = err.message;
  }
});

exitFullscreenBtn.addEventListener('click', async () => {
  if (window.desktopApi && typeof window.desktopApi.setFullScreen === 'function') {
    await window.desktopApi.setFullScreen(false);
  }
  exitFullscreenBtn.classList.add('hidden');
});

loadLatestPhoto.addEventListener('click', async () => {
  try {
    const usn = verifyUsn.value.trim().toUpperCase();
    if (!usn) {
      statusText.textContent = 'Enter a USN to verify photo';
      return;
    }
    const response = await fetch(`${API_BASE}/attendance/student/${encodeURIComponent(usn)}/photo/latest`, {
      headers: { Authorization: `Bearer ${teacherToken}` }
    });
    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      throw new Error(data.detail || 'Photo not found');
    }
    const blob = await response.blob();
    latestPhoto.src = URL.createObjectURL(blob);
    latestPhoto.classList.remove('hidden');
    statusText.textContent = `Loaded latest photo for ${usn}`;
  } catch (err) {
    statusText.textContent = err.message;
  }
});

downloadAttendanceReport.addEventListener('click', async () => {
  try {
    if (!teacherToken) {
      statusText.textContent = 'Login teacher first';
      return;
    }

    const response = await fetch(`${API_BASE}/attendance/report.json`, {
      headers: { Authorization: `Bearer ${teacherToken}` }
    });
    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      throw new Error(data.detail || 'Report download failed');
    }

    const text = await response.text();
    const blob = new Blob([text], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'attendance_report.json';
    a.click();
    URL.revokeObjectURL(url);
    statusText.textContent = 'Attendance report downloaded';
  } catch (err) {
    statusText.textContent = err.message;
  }
});

adminLoginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    const auth = await apiAdmin('/auth/admin/login', {
      method: 'POST',
      body: JSON.stringify({ email: adminEmail.value.trim(), password: adminPassword.value })
    });
    adminToken = auth.access_token;
    adminPanel.classList.remove('hidden');
    adminOutput.textContent = `Admin logged in: ${auth.admin_name}`;
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

adminListDevices.addEventListener('click', async () => {
  try {
    const data = await apiAdmin('/admin/device-sessions');
    adminOutput.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

adminAuditBtn.addEventListener('click', async () => {
  try {
    const data = await apiAdmin('/admin/audit-logs?limit=200');
    adminOutput.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

adminReassignBtn.addEventListener('click', async () => {
  try {
    const data = await apiAdmin('/admin/device/reassign', {
      method: 'POST',
      body: JSON.stringify({
        usn: adminReassignUsn.value.trim().toUpperCase(),
        new_device_id: adminReassignDevice.value.trim()
      })
    });
    adminOutput.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

adminRevokeBtn.addEventListener('click', async () => {
  try {
    const usn = adminRevokeUsn.value.trim().toUpperCase();
    const data = await apiAdmin(`/admin/device/${encodeURIComponent(usn)}/revoke`, { method: 'POST' });
    adminOutput.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

adminCleanupBtn.addEventListener('click', async () => {
  try {
    const data = await apiAdmin('/admin/maintenance/cleanup', { method: 'POST' });
    adminOutput.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    adminOutput.textContent = err.message;
  }
});

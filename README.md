# Attendance Suite

End-to-end QR attendance platform with:

- FastAPI backend with PostgreSQL
- Electron teacher desktop app
- Flutter student mobile app
- Face-gated attendance capture
- Offline queue and auto-sync
- Admin trust controls and audit logging

## Apps

- **Teacher app:** `AETTA`
- **Student app:** `ATTEA`

## Recommended Launch Flow

### One-click teacher launch

Use the desktop launcher or the packaged app. This starts the backend and teacher app together.

- Desktop icon: `AETTA`
- Script: `/home/hp/Attea/attendance-suite/launch_aetta.sh`

If you prefer terminal:

```bash
cd /home/hp/Attea/attendance-suite
bash start_teacher_suite.sh
```

## Teacher Desktop App

Path: `teacher-desktop`

### Run in development

```bash
cd /home/hp/Attea/attendance-suite/teacher-desktop
npm install
npm start
```

### Build installable Linux packages

```bash
cd /home/hp/Attea/attendance-suite/teacher-desktop
npm run dist:linux
```

Outputs:

- `teacher-desktop/dist/AETTA-1.0.0.AppImage`
- `teacher-desktop/dist/teacher-desktop_1.0.0_amd64.deb`

### Install on Linux (AppImage)

```bash
cd /home/hp/Attea/attendance-suite/teacher-desktop
chmod +x dist/AETTA-1.0.0.AppImage
./dist/AETTA-1.0.0.AppImage
```

### Install on Linux (.deb)

```bash
cd /home/hp/Attea/attendance-suite/teacher-desktop
sudo dpkg -i dist/teacher-desktop_1.0.0_amd64.deb
sudo apt-get -f install -y
```

### Teacher app features

- Teacher authentication against the backend
- One-click classroom session creation for a subject code
- Rotating QR display with automatic token refresh
- QR token lifecycle control tied to the teacher and subject
- Fullscreen projector mode for classroom use
- Live attendance count refresh during an active session
- Student face-photo verification by USN
- Single-button attendance report download for the full teacher dataset
- Admin login inside the desktop app
- Device-session viewer for seeing which student is attached to which device
- Device reassignment for restoring a student to a new phone
- Device revoke action for clearing a student’s current device binding
- Maintenance cleanup action for expiring inactive sessions and cleaning old exports
- Audit log viewer for checking login, attendance, and admin activity
- Automatic backend launch from the desktop app so it behaves like one installed desktop product
- Packaged Linux output support through AppImage and `.deb`

## Student Mobile App

Path: `student_mobile`

### Build release APK

```bash
cd /home/hp/Attea/attendance-suite/student_mobile
/home/hp/tools/flutter/bin/flutter pub get
/home/hp/tools/flutter/bin/flutter build apk --release
```

### Install on Android phone

```bash
/home/hp/Android/Sdk/platform-tools/adb devices
/home/hp/Android/Sdk/platform-tools/adb uninstall com.example.student_mobile
/home/hp/Android/Sdk/platform-tools/adb install /home/hp/Attea/attendance-suite/student_mobile/build/app/outputs/flutter-apk/app-release.apk
```

### Student app features

- USN-only login flow for the student
- Auto-generated device ID that is stored on the device
- Device binding so one student stays attached to one phone
- Automatic backend discovery across common LAN addresses
- Saved server URL handling for faster reconnects
- QR scanning from the teacher display
- QR attendance submission only when a valid live teacher session is detected
- Face-presence requirement before attendance submission
- Clear-face validation so a photo is only accepted when a face is visible
- Single photo capture per attendance attempt
- Dark-scene detection using the front camera preview
- Screen flash before capture when the environment is dark
- Screenshot-safe capture flow that avoids the old live-frame conversion crash
- Offline attendance queue when the network is unavailable
- Auto-sync of queued attendance records on the next successful launch
- Haptic feedback during the scan flow
- On-screen guidance that keeps the prompt simple: bring face in front of the screen

## Backend Features

Path: `backend`

### Backend features

- FastAPI REST API for teacher, student, and admin workflows
- PostgreSQL schema for teachers, admins, students, device sessions, QR sessions, attendance, and audit logs
- HMAC-signed QR tokens so attendance tokens cannot be forged casually
- 30-second QR expiry for classroom security
- One active QR session per teacher and subject to avoid class mix-ups
- Student login with device-session binding
- Admin login for maintenance and trust controls
- Attendance mark validation against:
	- student token
	- device session
	- QR session id
	- QR signature
	- teacher id
	- subject code
	- nonce
- Duplicate attendance prevention per QR session and student
- Face image storage on each successful attendance mark
- Automatic export of captured images to `backend/exported_faces`
- Teacher session statistics endpoint
- Teacher session records endpoint
- Teacher latest-photo endpoint by USN
- Teacher photo list endpoint by USN
- One-button JSON attendance report endpoint for all attendance records
- Rate limiting on login and attendance endpoints
- Audit logging for login, attendance, cleanup, and admin actions
- Admin device listing, reassignment, revoke, and cleanup endpoints
- Database reset script for clearing runtime state while reseeding demo accounts
- Maintenance cleanup script for expiring old sessions and deleting stale exported photos

## Backend

Path: `backend`

### Run manually

```bash
cd /home/hp/Attea/attendance-suite/backend
source /home/hp/Attea/.venv/bin/activate
SQLALCHEMY_DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Health check

```bash
curl http://127.0.0.1:8000/health
```

## Demo Accounts

### Teacher

- Email: `demo.teacher@example.com`
- Password: `1234`

### Admin

- Email: `demo.teacher@example.com`
- Password: `1234`

### Demo Student USNs

- `1VA23CI051`
- `1VA23CI052`
- `1VA23CI053`

## Security Model

- HMAC-signed QR tokens
- QR expiry enforcement
- Device-session binding per student
- Duplicate attendance prevention
- Role-based access for teacher, student, and admin
- Rate limiting on login and attendance endpoints
- Audit logs for auth, attendance, and admin actions

## Reports and Data

- Captured face images are stored in PostgreSQL
- Attendance images are auto-exported to `backend/exported_faces`
- Teacher report download produces a single JSON file with all attendance details
- Old CSV export buttons were removed

## Maintenance

### Reset database to a clean state

```bash
cd /home/hp/Attea/attendance-suite/backend
SQLALCHEMY_DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' /home/hp/Attea/.venv/bin/python reset_db.py
```

### Cleanup exported photos and expired sessions

```bash
cd /home/hp/Attea/attendance-suite/backend
SQLALCHEMY_DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' DATABASE_URL='postgresql://postgres:REDACTED@localhost:5432/attendance_db' /home/hp/Attea/.venv/bin/python cleanup_runtime.py
```

## Network Notes

### Real Android phone

- Phone and laptop must be on the same Wi-Fi
- Backend must bind to `0.0.0.0`
- Student app auto-discovers common LAN addresses

### Android emulator

- Use `http://10.0.2.2:8000`

## Project Layout

- `backend/` FastAPI backend
- `teacher-desktop/` Electron teacher app
- `student_mobile/` Flutter student app
- `assets/` shared branding assets
- `launch_aetta.sh` desktop launcher helper
- `start_teacher_suite.sh` backend + teacher launch script

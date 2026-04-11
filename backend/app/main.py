import base64
import json
import os
import secrets
import uuid
from collections import defaultdict, deque
from io import BytesIO
from pathlib import Path
from typing import Annotated

import qrcode
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pydantic import BaseModel, Field

from .db import get_conn, init_db, seed_data
from .security import APP_SECRET, QR_SECRET, hash_password, now_ts, sign_json, verify_password, verify_signed_json

app = FastAPI(title="Attendance Security Backend")

EXPORT_DIR = Path(os.getenv("PHOTO_EXPORT_DIR", Path(__file__).resolve().parents[1] / "exported_faces"))
RATE_BUCKETS: dict[str, deque[int]] = defaultdict(deque)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class TeacherLogin(BaseModel):
    email: str
    password: str


class AdminLogin(BaseModel):
    email: str
    password: str


class StudentLogin(BaseModel):
    usn: str
    device_id: str = Field(min_length=8)


class CreateSessionRequest(BaseModel):
    subject_code: str = Field(pattern=r"^\d{2}[A-Z]{2,4}\d{3}$")


class MarkAttendanceRequest(BaseModel):
    qr_token: str
    usn: str
    device_id: str = Field(min_length=8)
    face_detected: bool
    face_image_b64: str | None = None


class ReassignDeviceRequest(BaseModel):
    usn: str
    new_device_id: str = Field(min_length=8)


def log_audit(event: str, status: str, actor: str | None, details: str | None) -> None:
    try:
        with get_conn() as conn:
            conn.execute(
                "INSERT INTO audit_logs (event, status, actor, details, ts) VALUES (%s, %s, %s, %s, %s)",
                (event, status, actor, details, now_ts()),
            )
    except Exception:
        return


def enforce_rate_limit(bucket: str, key: str, limit: int, window_seconds: int) -> None:
    now = now_ts()
    store_key = f"{bucket}:{key}"
    q = RATE_BUCKETS[store_key]
    while q and now - q[0] > window_seconds:
        q.popleft()
    if len(q) >= limit:
        raise HTTPException(status_code=429, detail="Too many requests. Please retry shortly.")
    q.append(now)


@app.on_event("startup")
def on_startup() -> None:
    init_db()
    seed_data(
        demo_password_hash=hash_password("demo123"),
        test_password_hash=hash_password("1234"),
        admin_password_hash=hash_password("1234"),
    )


def parse_bearer(auth_header: str | None) -> str:
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing authorization")
    kind, _, token = auth_header.partition(" ")
    if kind.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="Invalid authorization")
    return token


def require_teacher_token(authorization: Annotated[str | None, Header()] = None) -> dict:
    token = parse_bearer(authorization)
    payload = verify_signed_json(token, APP_SECRET)
    if not payload or payload.get("role") != "teacher":
        raise HTTPException(status_code=401, detail="Invalid teacher token")
    return payload


def require_student_token(authorization: Annotated[str | None, Header()] = None) -> dict:
    token = parse_bearer(authorization)
    payload = verify_signed_json(token, APP_SECRET)
    if not payload or payload.get("role") != "student":
        raise HTTPException(status_code=401, detail="Invalid student token")
    return payload


def require_admin_token(authorization: Annotated[str | None, Header()] = None) -> dict:
    token = parse_bearer(authorization)
    payload = verify_signed_json(token, APP_SECRET)
    if not payload or payload.get("role") != "admin":
        raise HTTPException(status_code=401, detail="Invalid admin token")
    return payload


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


def _export_face_snapshot(usn: str, attendance_id: int, face_image_b64: str) -> None:
    try:
        EXPORT_DIR.mkdir(parents=True, exist_ok=True)
        image_bytes = base64.b64decode(face_image_b64, validate=True)
        out_file = EXPORT_DIR / f"{usn}_{attendance_id}.jpg"
        out_file.write_bytes(image_bytes)
    except Exception:
        # Attendance is already saved in DB; avoid failing request on local export issues.
        return


@app.get("/attendance/qr-image")
def qr_image(token: str) -> Response:
    # Render a projector-ready PNG for the signed QR token.
    img = qrcode.make(token)
    buffer = BytesIO()
    img.save(buffer, format="PNG")
    return Response(content=buffer.getvalue(), media_type="image/png")


@app.post("/auth/teacher/login")
def teacher_login(body: TeacherLogin, request: Request) -> dict:
    enforce_rate_limit("teacher_login", request.client.host if request.client else "unknown", 12, 60)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM teachers WHERE email = %s", (body.email,)).fetchone()

    if not row or not verify_password(body.password, row["password_hash"]):
        log_audit("teacher_login", "fail", body.email, "Invalid credentials")
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = sign_json(
        {
            "sub": row["id"],
            "name": row["name"],
            "role": "teacher",
            "exp": now_ts() + 6 * 3600,
        },
        APP_SECRET,
    )
    log_audit("teacher_login", "ok", body.email, None)
    return {"access_token": token, "teacher_name": row["name"]}


@app.post("/auth/admin/login")
def admin_login(body: AdminLogin, request: Request) -> dict:
    enforce_rate_limit("admin_login", request.client.host if request.client else "unknown", 8, 60)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM admins WHERE email = %s", (body.email,)).fetchone()

    if not row or not verify_password(body.password, row["password_hash"]):
        log_audit("admin_login", "fail", body.email, "Invalid credentials")
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = sign_json(
        {
            "sub": row["id"],
            "name": row["name"],
            "role": "admin",
            "exp": now_ts() + 6 * 3600,
        },
        APP_SECRET,
    )
    log_audit("admin_login", "ok", body.email, None)
    return {"access_token": token, "admin_name": row["name"]}


@app.post("/auth/student/login")
def student_login(body: StudentLogin, request: Request) -> dict:
    enforce_rate_limit("student_login", request.client.host if request.client else "unknown", 20, 60)
    with get_conn() as conn:
        student = conn.execute("SELECT * FROM students WHERE usn = %s", (body.usn,)).fetchone()
        if not student:
            log_audit("student_login", "fail", body.usn, "Student not found")
            raise HTTPException(status_code=404, detail="Student not found")

        current = conn.execute("SELECT * FROM device_sessions WHERE student_id = %s", (student["id"],)).fetchone()
        if current and current["device_id"] != body.device_id:
            log_audit("student_login", "fail", body.usn, "Device mismatch")
            raise HTTPException(status_code=409, detail="Student is active on another device")

        if current:
            conn.execute(
                "UPDATE device_sessions SET last_seen_at = %s WHERE student_id = %s",
                (now_ts(), student["id"]),
            )
        else:
            conn.execute(
                "INSERT INTO device_sessions (student_id, device_id, last_seen_at) VALUES (%s, %s, %s)",
                (student["id"], body.device_id, now_ts()),
            )

    token = sign_json(
        {
            "sub": student["id"],
            "usn": student["usn"],
            "device_id": body.device_id,
            "role": "student",
            "exp": now_ts() + 12 * 3600,
        },
        APP_SECRET,
    )
    log_audit("student_login", "ok", body.usn, f"device={body.device_id[:8]}")
    return {"access_token": token, "student_name": student["name"], "usn": student["usn"]}


@app.post("/attendance/session/create")
def create_qr_session(body: CreateSessionRequest, teacher=Depends(require_teacher_token)) -> dict:
    issued = now_ts()
    expires = issued + 30
    session_id = str(uuid.uuid4())
    nonce = secrets.token_hex(8)

    qr_payload = {
        "session_id": session_id,
        "subject_code": body.subject_code,
        "teacher_id": teacher["sub"],
        "issued_at": issued,
        "expires_at": expires,
        "nonce": nonce,
    }
    qr_token = sign_json(qr_payload, QR_SECRET)

    with get_conn() as conn:
        # Keep only one active QR session per teacher+subject to avoid class mixups.
        conn.execute(
            """
            UPDATE qr_sessions
            SET active = FALSE
            WHERE teacher_id = %s AND subject_code = %s AND active = TRUE
            """,
            (teacher["sub"], body.subject_code),
        )
        conn.execute(
            """
            INSERT INTO qr_sessions (id, teacher_id, subject_code, issued_at, expires_at, nonce, signature, active)
            VALUES (%s, %s, %s, %s, %s, %s, %s, TRUE)
            """,
            (session_id, teacher["sub"], body.subject_code, issued, expires, nonce, qr_token.split(".", 1)[1]),
        )

    return {"session_id": session_id, "qr_token": qr_token, "expires_at": expires}


@app.get("/attendance/session/{session_id}/stats")
def session_stats(session_id: str, teacher=Depends(require_teacher_token)) -> dict:
    with get_conn() as conn:
        session = conn.execute("SELECT * FROM qr_sessions WHERE id = %s", (session_id,)).fetchone()
        if not session or session["teacher_id"] != teacher["sub"]:
            raise HTTPException(status_code=404, detail="Session not found")

        count = conn.execute(
            "SELECT COUNT(*) AS count FROM attendance WHERE qr_session_id = %s", (session_id,)
        ).fetchone()["count"]

    return {"session_id": session_id, "attendance_count": count, "expires_at": session["expires_at"]}


@app.get("/attendance/session/{session_id}/records")
def session_records(session_id: str, teacher=Depends(require_teacher_token)) -> dict:
    with get_conn() as conn:
        session = conn.execute("SELECT * FROM qr_sessions WHERE id = %s", (session_id,)).fetchone()
        if not session or session["teacher_id"] != teacher["sub"]:
            raise HTTPException(status_code=404, detail="Session not found")

        rows = conn.execute(
            """
            SELECT a.marked_at, s.usn, s.name, a.face_image_b64
            FROM attendance a
            JOIN students s ON s.id = a.student_id
            WHERE a.qr_session_id = %s
            ORDER BY a.marked_at DESC
            """,
            (session_id,),
        ).fetchall()

    records = [
        {
            "usn": row["usn"],
            "name": row["name"],
            "marked_at": row["marked_at"],
            "face_image_b64": row["face_image_b64"],
        }
        for row in rows
    ]
    return {"session_id": session_id, "records": records}


@app.get("/attendance/report.json")
def attendance_report(teacher=Depends(require_teacher_token)) -> Response:
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT
                a.id AS attendance_id,
                a.marked_at,
                a.face_image_b64,
                s.usn,
                s.name,
                q.id AS session_id,
                q.subject_code,
                q.issued_at,
                q.expires_at
            FROM attendance a
            JOIN students s ON s.id = a.student_id
            JOIN qr_sessions q ON q.id = a.qr_session_id
            WHERE q.teacher_id = %s
            ORDER BY a.marked_at DESC
            """,
            (teacher["sub"],),
        ).fetchall()

    payload = {
        "generated_at": now_ts(),
        "attendance_count": len(rows),
        "records": [
            {
                "attendance_id": row["attendance_id"],
                "marked_at": row["marked_at"],
                "usn": row["usn"],
                "name": row["name"],
                "session_id": row["session_id"],
                "subject_code": row["subject_code"],
                "issued_at": row["issued_at"],
                "expires_at": row["expires_at"],
                "face_image_b64": row["face_image_b64"],
            }
            for row in rows
        ],
    }

    return Response(
        content=json.dumps(payload, indent=2),
        media_type="application/json",
        headers={"Content-Disposition": 'attachment; filename="attendance_report.json"'},
    )


@app.get("/attendance/student/{usn}/photos")
def student_photos(usn: str, teacher=Depends(require_teacher_token)) -> dict:
    with get_conn() as conn:
        student = conn.execute("SELECT * FROM students WHERE usn = %s", (usn,)).fetchone()
        if not student:
            raise HTTPException(status_code=404, detail="Student not found")

        rows = conn.execute(
            """
            SELECT a.id, a.qr_session_id, a.marked_at, a.face_image_b64
            FROM attendance a
            WHERE a.student_id = %s
              AND a.face_image_b64 IS NOT NULL
              AND length(a.face_image_b64) > 0
            ORDER BY a.marked_at DESC
            """,
            (student["id"],),
        ).fetchall()

    photos = [
        {
            "attendance_id": row["id"],
            "session_id": row["qr_session_id"],
            "marked_at": row["marked_at"],
            "face_image_b64": row["face_image_b64"],
        }
        for row in rows
    ]
    return {"usn": usn, "count": len(photos), "photos": photos}


@app.get("/attendance/student/{usn}/photo/latest")
def student_latest_photo(usn: str, teacher=Depends(require_teacher_token)) -> Response:
    with get_conn() as conn:
        student = conn.execute("SELECT * FROM students WHERE usn = %s", (usn,)).fetchone()
        if not student:
            raise HTTPException(status_code=404, detail="Student not found")

        row = conn.execute(
            """
            SELECT a.face_image_b64
            FROM attendance a
            WHERE a.student_id = %s
              AND a.face_image_b64 IS NOT NULL
              AND length(a.face_image_b64) > 0
            ORDER BY a.marked_at DESC
            LIMIT 1
            """,
            (student["id"],),
        ).fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="No photo found for this USN")

    try:
        content = base64.b64decode(row["face_image_b64"], validate=True)
    except Exception:
        raise HTTPException(status_code=500, detail="Stored photo is not valid base64")

    return Response(content=content, media_type="image/jpeg")


@app.post("/attendance/mark")
def mark_attendance(body: MarkAttendanceRequest, request: Request, student=Depends(require_student_token)) -> dict:
    enforce_rate_limit("attendance_mark", request.client.host if request.client else "unknown", 35, 60)
    if not body.face_detected:
        log_audit("attendance_mark", "fail", body.usn, "Face not detected")
        raise HTTPException(status_code=400, detail="Face verification required")
    if not body.face_image_b64:
        log_audit("attendance_mark", "fail", body.usn, "Missing face image")
        raise HTTPException(status_code=400, detail="Face photo is required")

    qr_payload = verify_signed_json(body.qr_token, QR_SECRET)
    if not qr_payload:
        raise HTTPException(status_code=401, detail="Invalid or expired QR")

    if qr_payload["expires_at"] < now_ts():
        raise HTTPException(status_code=401, detail="QR expired")

    if student.get("usn") != body.usn:
        raise HTTPException(status_code=403, detail="Token and USN mismatch")

    if student.get("device_id") != body.device_id:
        raise HTTPException(status_code=403, detail="Token and device mismatch")

    with get_conn() as conn:
        db_student = conn.execute("SELECT * FROM students WHERE usn = %s", (body.usn,)).fetchone()
        if not db_student:
            raise HTTPException(status_code=404, detail="Student not found")

        if db_student["id"] != student["sub"]:
            raise HTTPException(status_code=403, detail="Token and student mismatch")

        device_row = conn.execute(
            "SELECT * FROM device_sessions WHERE student_id = %s", (db_student["id"],)
        ).fetchone()
        if not device_row or device_row["device_id"] != body.device_id:
            raise HTTPException(status_code=403, detail="Invalid device session")

        session = conn.execute("SELECT * FROM qr_sessions WHERE id = %s", (qr_payload["session_id"],)).fetchone()
        if not session or not session["active"]:
            raise HTTPException(status_code=404, detail="QR session inactive")

        if session["expires_at"] < now_ts():
            raise HTTPException(status_code=401, detail="QR session expired")

        if session["subject_code"] != qr_payload.get("subject_code"):
            raise HTTPException(status_code=403, detail="Class code mismatch")

        if session["teacher_id"] != qr_payload.get("teacher_id"):
            raise HTTPException(status_code=403, detail="Teacher mismatch")

        if session["nonce"] != qr_payload.get("nonce"):
            raise HTTPException(status_code=403, detail="QR nonce mismatch")

        parts = body.qr_token.split(".", 1)
        if len(parts) != 2:
            raise HTTPException(status_code=401, detail="Malformed QR token")
        expected_sig = parts[1]
        if session["signature"] != expected_sig:
            raise HTTPException(status_code=403, detail="QR signature mismatch")

        try:
            saved = conn.execute(
                """
                INSERT INTO attendance (qr_session_id, student_id, marked_at, face_image_b64)
                VALUES (%s, %s, %s, %s)
                RETURNING id
                """,
                (qr_payload["session_id"], db_student["id"], now_ts(), body.face_image_b64),
            ).fetchone()
        except Exception:
            log_audit("attendance_mark", "fail", body.usn, "Duplicate attendance")
            raise HTTPException(status_code=409, detail="Attendance already marked")

    _export_face_snapshot(body.usn, int(saved["id"]), body.face_image_b64)
    log_audit("attendance_mark", "ok", body.usn, f"session={qr_payload['session_id']}")

    return {"status": "marked", "session_id": qr_payload["session_id"]}


@app.get("/admin/device-sessions")
def admin_device_sessions(_admin=Depends(require_admin_token)) -> dict:
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT s.usn, s.name, d.device_id, d.last_seen_at
            FROM device_sessions d
            JOIN students s ON s.id = d.student_id
            ORDER BY d.last_seen_at DESC
            """
        ).fetchall()

    return {
        "sessions": [
            {
                "usn": r["usn"],
                "name": r["name"],
                "device_id": r["device_id"],
                "last_seen_at": r["last_seen_at"],
            }
            for r in rows
        ]
    }


@app.post("/admin/device/reassign")
def admin_reassign_device(body: ReassignDeviceRequest, _admin=Depends(require_admin_token)) -> dict:
    with get_conn() as conn:
        student = conn.execute("SELECT * FROM students WHERE usn = %s", (body.usn,)).fetchone()
        if not student:
            raise HTTPException(status_code=404, detail="Student not found")

        conn.execute(
            """
            INSERT INTO device_sessions (student_id, device_id, last_seen_at)
            VALUES (%s, %s, %s)
            ON CONFLICT (student_id)
            DO UPDATE SET device_id = EXCLUDED.device_id, last_seen_at = EXCLUDED.last_seen_at
            """,
            (student["id"], body.new_device_id, now_ts()),
        )

    log_audit("admin_reassign_device", "ok", body.usn, f"device={body.new_device_id[:8]}")
    return {"status": "ok", "usn": body.usn, "device_id": body.new_device_id}


@app.post("/admin/device/{usn}/revoke")
def admin_revoke_device(usn: str, _admin=Depends(require_admin_token)) -> dict:
    with get_conn() as conn:
        student = conn.execute("SELECT * FROM students WHERE usn = %s", (usn,)).fetchone()
        if not student:
            raise HTTPException(status_code=404, detail="Student not found")
        conn.execute("DELETE FROM device_sessions WHERE student_id = %s", (student["id"],))

    log_audit("admin_revoke_device", "ok", usn, None)
    return {"status": "ok", "usn": usn}


@app.post("/admin/maintenance/cleanup")
def admin_cleanup(_admin=Depends(require_admin_token)) -> dict:
    now = now_ts()
    deactivated = 0
    removed_files = 0
    with get_conn() as conn:
        deactivated = conn.execute(
            "UPDATE qr_sessions SET active = FALSE WHERE active = TRUE AND expires_at < %s",
            (now,),
        ).rowcount or 0

    if EXPORT_DIR.exists():
        for img in EXPORT_DIR.glob("*.jpg"):
            try:
                if img.stat().st_mtime < (now - 7 * 24 * 3600):
                    img.unlink()
                    removed_files += 1
            except Exception:
                continue

    log_audit("admin_cleanup", "ok", "admin", f"deactivated={deactivated}, removed_files={removed_files}")
    return {"status": "ok", "deactivated_sessions": deactivated, "removed_exported_files": removed_files}


@app.get("/admin/audit-logs")
def admin_audit_logs(limit: int = 200, _admin=Depends(require_admin_token)) -> dict:
    limit = max(1, min(limit, 1000))
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, event, status, actor, details, ts FROM audit_logs ORDER BY id DESC LIMIT %s",
            (limit,),
        ).fetchall()

    return {
        "logs": [
            {
                "id": r["id"],
                "event": r["event"],
                "status": r["status"],
                "actor": r["actor"],
                "details": r["details"],
                "ts": r["ts"],
            }
            for r in rows
        ]
    }

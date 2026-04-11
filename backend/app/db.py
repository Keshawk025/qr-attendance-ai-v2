import os

import psycopg
from psycopg.rows import dict_row

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    os.getenv("SQLALCHEMY_DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/attendance_db"),
)


def get_conn() -> psycopg.Connection:
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


def init_db() -> None:
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS teachers (
                id SERIAL PRIMARY KEY,
                email TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS admins (
                id SERIAL PRIMARY KEY,
                email TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS students (
                id SERIAL PRIMARY KEY,
                usn TEXT UNIQUE NOT NULL,
                name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS device_sessions (
                id SERIAL PRIMARY KEY,
                student_id INTEGER NOT NULL,
                device_id TEXT NOT NULL,
                last_seen_at INTEGER NOT NULL,
                UNIQUE(student_id),
                FOREIGN KEY(student_id) REFERENCES students(id)
            );

            CREATE TABLE IF NOT EXISTS qr_sessions (
                id TEXT PRIMARY KEY,
                teacher_id INTEGER NOT NULL,
                subject_code TEXT NOT NULL,
                issued_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                nonce TEXT NOT NULL,
                signature TEXT NOT NULL,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                FOREIGN KEY(teacher_id) REFERENCES teachers(id)
            );

            CREATE TABLE IF NOT EXISTS attendance (
                id SERIAL PRIMARY KEY,
                qr_session_id TEXT NOT NULL,
                student_id INTEGER NOT NULL,
                marked_at INTEGER NOT NULL,
                face_image_b64 TEXT,
                UNIQUE(qr_session_id, student_id),
                FOREIGN KEY(qr_session_id) REFERENCES qr_sessions(id),
                FOREIGN KEY(student_id) REFERENCES students(id)
            );

            CREATE TABLE IF NOT EXISTS audit_logs (
                id SERIAL PRIMARY KEY,
                event TEXT NOT NULL,
                status TEXT NOT NULL,
                actor TEXT,
                details TEXT,
                ts INTEGER NOT NULL
            );
            """
        )


def seed_data(demo_password_hash: str, test_password_hash: str, admin_password_hash: str) -> None:
    with get_conn() as conn:
        # Keep teacher credentials deterministic for local testing.
        conn.execute(
            """
            INSERT INTO teachers (email, password_hash, name)
            VALUES (%s, %s, %s)
            ON CONFLICT (email)
            DO UPDATE SET password_hash = EXCLUDED.password_hash, name = EXCLUDED.name
            """,
            ("teacher@example.com", demo_password_hash, "Demo Teacher"),
        )
        conn.execute(
            """
            INSERT INTO teachers (email, password_hash, name)
            VALUES (%s, %s, %s)
            ON CONFLICT (email)
            DO UPDATE SET password_hash = EXCLUDED.password_hash, name = EXCLUDED.name
            """,
            ("demo.teacher@example.com", test_password_hash, "Kkeshaw"),
        )

        conn.execute(
            """
            INSERT INTO admins (email, password_hash, name)
            VALUES (%s, %s, %s)
            ON CONFLICT (email)
            DO UPDATE SET password_hash = EXCLUDED.password_hash, name = EXCLUDED.name
            """,
            ("demo.teacher@example.com", admin_password_hash, "Kkeshaw Admin"),
        )

        student_count = conn.execute("SELECT COUNT(*) AS count FROM students").fetchone()["count"]
        if student_count == 0:
            for usn, name in [
                ("1VA23CI051", "Student One"),
                ("1VA23CI052", "Student Two"),
                ("1VA23CI053", "Student Three"),
            ]:
                conn.execute(
                    "INSERT INTO students (usn, name) VALUES (%s, %s)",
                    (usn, name),
                )


def reset_runtime_data() -> None:
    with get_conn() as conn:
        conn.execute("TRUNCATE TABLE attendance RESTART IDENTITY CASCADE")
        conn.execute("TRUNCATE TABLE device_sessions RESTART IDENTITY CASCADE")
        conn.execute("TRUNCATE TABLE qr_sessions RESTART IDENTITY CASCADE")
        conn.execute("TRUNCATE TABLE audit_logs RESTART IDENTITY CASCADE")

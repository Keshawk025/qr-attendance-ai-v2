from app.db import init_db, reset_runtime_data, seed_data
from app.security import hash_password


if __name__ == "__main__":
    init_db()
    reset_runtime_data()
    seed_data(
        demo_password_hash=hash_password("demo123"),
        test_password_hash=hash_password("1234"),
        admin_password_hash=hash_password("1234"),
    )
    print("Database refreshed: attendance/session/device data cleared and demo users seeded.")

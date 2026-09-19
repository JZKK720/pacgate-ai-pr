import sqlite3

db = sqlite3.connect('/app/backend/.deer-flow/data/deerflow.db')
print('TABLES:', [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()])
for row in db.execute('SELECT thread_id, title, status, updated_at FROM threads_meta ORDER BY updated_at DESC LIMIT 3').fetchall():
    print('ROW:', row)

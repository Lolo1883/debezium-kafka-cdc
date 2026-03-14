import pymssql
import sys

try:
    conn = pymssql.connect("mssql", "sa", "KEP_Strong!Pass123", "master")
    conn.autocommit(True)
    cur = conn.cursor()
    cur.execute("IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name='kep_target') CREATE DATABASE kep_target")
    print("kep_target database ready")
    conn.close()
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)

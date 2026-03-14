#!/bin/bash
set -e
pip install pymssql -q --no-cache-dir
python /init/init-db.py

#!/usr/bin/env python3
"""Arma el data warehouse ejecutando los archivos SQL de la carpeta sql/.

Uso:
    python run_sql.py              # ejecuta sql/*.sql en orden y exporta el resultado a data/
    python run_sql.py --ui         # lo mismo y después abre DuckDB en el navegador para explorar
    python run_sql.py --explorar   # solo abre las tablas de origen para explorarlas (no ejecuta sql/)

Las tablas de origen (los CSV de raw/) están disponibles en el esquema raw:
    SELECT * FROM raw.sales_order;

Cada vez que se arma el data warehouse:
  1. Borra la base warehouse.duckdb y la vuelve a crear desde cero.
  2. Ejecuta los archivos de sql/ en orden alfabético (01_..., 02_..., 03_...).
     Si una consulta es un SELECT, muestra el resultado en la terminal.
  3. Exporta cada tabla creada a un CSV (las carpetas se regeneran completas):
       data/marts/<tabla>.csv             las tablas mart_* (KPIs que consume el tablero)
       data/modelo_estrella/<tabla>.csv   dimensiones y hechos
  4. Genera data/modelo_estrella/modelo_estrella.md con el diagrama del modelo (GitHub lo dibuja solo).

La interfaz del navegador necesita internet. Sin conexión se abre una consola SQL en la terminal.
"""
from __future__ import annotations

import argparse
import os
import re
import socket
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
RAW_DIR = ROOT / "raw"
SQL_DIR = ROOT / "sql"
DATA_DIR = ROOT / "data"
MODEL_DIR = DATA_DIR / "modelo_estrella"
MARTS_DIR = DATA_DIR / "marts"
MART_PREFIX = "mart_"
DATABASE = ROOT / "warehouse.duckdb"
DIAGRAM = MODEL_DIR / "modelo_estrella.md"
UI_HOST = "ui.duckdb.org"  # de acá la interfaz descarga sus archivos
ALREADY_OPEN = ("La base warehouse.duckdb está abierta en otra terminal (¿quedó abierto --ui o --explorar?).\n"
                "Cerrala presionando Enter en esa terminal y volvé a ejecutar.")


# ---------------------------------------------------------------------------
# Tablas de origen
# ---------------------------------------------------------------------------
def create_raw_views(con: duckdb.DuckDBPyConnection) -> list[str]:
    """Crea una vista raw.<tabla> por cada CSV de raw/."""
    con.sql("CREATE SCHEMA IF NOT EXISTS raw")
    names = []
    for path in sorted(RAW_DIR.glob("*.csv")):
        con.sql(f"CREATE OR REPLACE VIEW raw.{path.stem} AS SELECT * FROM read_csv('{path.as_posix()}')")
        names.append(path.stem)
    return names


# ---------------------------------------------------------------------------
# Construcción del data warehouse
# ---------------------------------------------------------------------------
def reset_outputs() -> None:
    try:
        for path in (DATABASE, DATABASE.with_name(DATABASE.name + ".wal")):
            path.unlink(missing_ok=True)
        for folder in (MODEL_DIR, MARTS_DIR):
            folder.mkdir(parents=True, exist_ok=True)
            for path in folder.glob("*.csv"):
                path.unlink()
        DIAGRAM.unlink(missing_ok=True)
    except PermissionError:
        sys.exit(ALREADY_OPEN)


def run_file(con: duckdb.DuckDBPyConnection, path: Path) -> bool:
    """Ejecuta un archivo sentencia por sentencia. Devuelve False si hubo un error."""
    relative = path.relative_to(ROOT)
    try:
        statements = con.extract_statements(path.read_text(encoding="utf-8"))
    except duckdb.Error as error:
        print(f"\nERROR de sintaxis en {relative}:\n  {error}")
        return False
    print(f"\n>> {relative} ({len(statements)} sentencias)")
    for number, statement in enumerate(statements, start=1):
        query = statement.query.strip()
        try:
            result = con.sql(query)
            if result is not None:  # SELECT: mostrar el resultado
                print(f"\n-- Consulta {number}: {first_line(query)}")
                result.show(max_rows=30)
        except duckdb.Error as error:
            print(f"\nERROR en {relative}, sentencia {number}:")
            print("  " + "\n  ".join(query.splitlines()[:8]))
            print(f"\n  {error}")
            return False
    return True


def first_line(query: str) -> str:
    lines = [line for line in query.splitlines() if line.strip() and not line.strip().startswith("--")]
    return (lines[0].strip() if lines else query)[:80]


def user_tables(con: duckdb.DuckDBPyConnection) -> list[str]:
    """Tablas creadas por los archivos de sql/ (esquema main de la base)."""
    rows = con.sql(
        "SELECT table_name FROM duckdb_tables() "
        "WHERE database_name = current_database() AND schema_name = 'main' AND NOT internal "
        "ORDER BY table_name"
    ).fetchall()
    return [row[0] for row in rows]


def is_mart(table: str) -> bool:
    return table.startswith(MART_PREFIX)


def export_tables(con: duckdb.DuckDBPyConnection, tables: list[str]) -> None:
    for folder, group in ((MODEL_DIR, [t for t in tables if not is_mart(t)]),
                          (MARTS_DIR, [t for t in tables if is_mart(t)])):
        if not group:
            continue
        print(f"\nTablas exportadas a {folder.relative_to(ROOT).as_posix()}/:")
        for table in group:
            rows = con.sql(f'SELECT COUNT(*) FROM main."{table}"').fetchone()[0]
            con.sql(f"COPY main.\"{table}\" TO '{(folder / f'{table}.csv').as_posix()}' (HEADER)")
            print(f"  {table + '.csv':<32}{rows:>10} filas")


def write_diagram(con: duckdb.DuckDBPyConnection, tables: list[str]) -> None:
    """Dibuja el modelo como diagrama Mermaid a partir de las PRIMARY KEY y FOREIGN KEY."""
    where = "WHERE database_name = current_database() AND schema_name = 'main'"
    columns = con.sql(
        f"SELECT table_name, column_name, data_type FROM duckdb_columns() {where} "
        "ORDER BY table_name, column_index"
    ).fetchall()
    constraints = con.sql(
        "SELECT table_name, constraint_type, constraint_column_names, referenced_table "
        f"FROM duckdb_constraints() {where} AND constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')"
    ).fetchall()
    keys: dict[tuple[str, str], set[str]] = {}
    relations = []
    for table, kind, cols, referenced in constraints:
        for col in cols:
            keys.setdefault((table, col), set()).add("PK" if kind == "PRIMARY KEY" else "FK")
        if kind == "FOREIGN KEY":
            relations.append(f'    {referenced} ||--o{{ {table} : "{", ".join(cols)}"')

    lines = ["# Modelo estrella", "", "Generado por `run_sql.py` a partir de las tablas de `warehouse.duckdb`.", "",
             "```mermaid", "erDiagram"]
    lines += sorted(set(relations))
    for table in tables:
        lines.append(f"    {table} {{")
        for t, column, data_type in columns:
            if t == table:
                simple_type = re.sub(r"\(.*\)", "", data_type).replace(" ", "_")
                marks = ", ".join(sorted(keys.get((table, column), set()), reverse=True))
                lines.append(f"        {simple_type} {column}{' ' + marks if marks else ''}")
        lines.append("    }")
    lines.append("```")
    DIAGRAM.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nDiagrama del modelo: {DIAGRAM.relative_to(ROOT)}")


def build() -> duckdb.DuckDBPyConnection:
    sql_files = sorted(SQL_DIR.glob("*.sql"))
    if not sql_files:
        sys.exit(f"No hay archivos .sql en {SQL_DIR}")
    reset_outputs()
    try:
        con = duckdb.connect(str(DATABASE))
    except duckdb.IOException:
        sys.exit(ALREADY_OPEN)
    create_raw_views(con)
    for path in sql_files:
        if not run_file(con, path):
            print("\nSe detuvo la ejecución. Corregí el error y volvé a correr: python run_sql.py")
            con.close()
            sys.exit(1)
    tables = user_tables(con)
    if tables:
        export_tables(con, tables)
        write_diagram(con, [t for t in tables if not is_mart(t)])
    else:
        print("\nTodavía no se creó ninguna tabla.")
    print(f"\nListo. Base de datos: {DATABASE.name}")
    return con


# ---------------------------------------------------------------------------
# Exploración: interfaz web o consola en la terminal
# ---------------------------------------------------------------------------
def online() -> bool:
    try:
        socket.create_connection((UI_HOST, 443), timeout=4).close()
        return True
    except OSError:
        return False


def open_ui(con: duckdb.DuckDBPyConnection) -> None:
    if not online():
        print("\nSin conexión a internet: la interfaz del navegador no está disponible.")
        console(con)
        return
    print("\nAbriendo DuckDB en el navegador...")
    try:
        con.sql("CALL start_ui()")
    except duckdb.Error as error:
        print(f"No se pudo abrir la interfaz del navegador: {str(error).splitlines()[0]}")
        console(con)
        return
    print("Si no se abrió sola, entrá a http://localhost:4213")
    input("Cuando termines, presioná Enter acá para cerrarla...\n")


def console(con: duckdb.DuckDBPyConnection) -> None:
    print("\nConsola SQL. Terminá cada consulta con ; y presioná Enter. Escribí salir para terminar.")
    print("Ejemplo: SELECT * FROM raw.sales_order LIMIT 5;\n")
    buffer: list[str] = []
    while True:
        try:
            line = input("sql> " if not buffer else " ..> ")
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not buffer and line.strip().lower() in ("salir", "exit", "quit"):
            return
        buffer.append(line)
        if not line.rstrip().endswith(";"):
            continue
        query, buffer = "\n".join(buffer), []
        try:
            result = con.sql(query)
            if result is not None:
                result.show(max_rows=30)
        except duckdb.Error as error:
            print(f"ERROR: {error}")


def explore() -> None:
    con = duckdb.connect()  # en memoria: no toca warehouse.duckdb ni data/
    names = create_raw_views(con)
    print("Tablas de origen disponibles (esquema raw):")
    for i in range(0, len(names), 4):
        print("  " + "".join(f"raw.{name:<22}" for name in names[i:i + 4]))
    print("\nPor ejemplo:  SELECT * FROM raw.sales_order LIMIT 10;")
    print("             DESCRIBE raw.sales_order;")
    open_ui(con)
    con.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ui", action="store_true", help="armar el data warehouse y abrir DuckDB en el navegador")
    mode.add_argument("--explorar", action="store_true", help="solo explorar las tablas de origen (no ejecuta sql/)")
    args = parser.parse_args()

    os.chdir(ROOT)  # así las rutas relativas funcionan aunque se ejecute desde otra carpeta
    if args.explorar:
        explore()
        return
    con = build()
    if args.ui:
        open_ui(con)
    con.close()


if __name__ == "__main__":
    main()

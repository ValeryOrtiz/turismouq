-- ============================================================================
-- TurismoUQ - 00_usuario_opcional.sql   (OPCIONAL - ejecutar como SYSTEM)
-- Crea un esquema propio TURISMOUQ con los privilegios que necesitan los
-- scripts 01 a 07. Si ya trabajan con SYSTEM o con un usuario DBA, pueden
-- saltarse este script.
-- En Oracle XE / Free conectarse primero a la PDB (XEPDB1 o FREEPDB1),
-- no a la raiz CDB$ROOT.
-- ============================================================================

CREATE USER turismouq IDENTIFIED BY "TurismoUQ2026"
    DEFAULT TABLESPACE users
    QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE MATERIALIZED VIEW,
      CREATE JOB, CREATE TABLESPACE, UNLIMITED TABLESPACE
   TO turismouq;

-- Para que 06 pueda leer V$PARAMETER y DBA_DATA_FILES (ruta del datafile)
GRANT SELECT_CATALOG_ROLE TO turismouq;

-- Luego: conectarse como TURISMOUQ y ejecutar 01, 02, ... 07 en orden.

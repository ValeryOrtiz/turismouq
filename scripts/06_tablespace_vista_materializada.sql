-- ============================================================================
-- TurismoUQ - 06_tablespace_vista_materializada.sql  (ENTREGA 2 - entregable 3)
--   A) Tablespace TS_TURISMO_HISTORICO + tabla RESERVA_HISTORICO
--   B) Vista materializada MV_OCUPACION_MENSUAL + politica de refresco
-- Ejecutar despues de 05_disparadores.sql, como script (F5).
-- Requiere un usuario con privilegios CREATE TABLESPACE, CREATE MATERIALIZED
-- VIEW y CREATE JOB (por ejemplo SYSTEM, o el usuario creado con 00_usuario).
-- ============================================================================

SET SERVEROUTPUT ON;
SET DEFINE OFF;

-- ============================================================================
-- A) TABLESPACE PARA EL HISTORICO DE RESERVAS
-- ----------------------------------------------------------------------------
-- POR QUE SEPARARLO
-- 1. Patron de acceso distinto. RESERVA es una tabla transaccional (OLTP):
--    se inserta y actualiza todo el dia. El historico solo crece por cargas
--    periodicas (una vez al mes/anio) y casi nunca se modifica; se consulta
--    para reportes y auditoria. Mezclarlos en el mismo tablespace hace que
--    el crecimiento del historico compita por espacio y E/S con la operacion.
-- 2. Crecimiento controlado. El historico crece sin parar (25.000 reservas en
--    3 anios y subiendo). Con su propio datafile y un MAXSIZE propio, si el
--    historico se llena no detiene las reservas nuevas del tablespace de uso
--    diario (USERS).
-- 3. Respaldo y recuperacion. Un tablespace de historico puede ponerse
--    READ ONLY despues de cada cierre anual: RMAN lo respalda una vez y deja
--    de copiarlo en cada backup, y una restauracion del tablespace operativo
--    no tiene que esperar a restaurar anios de historia.
-- 4. Ubicacion fisica. Su datafile puede moverse a un disco mas barato o mas
--    lento sin afectar el rendimiento de las reservas.
-- 5. Ajustes propios. La tabla historica se crea con PCTFREE 0 (las filas no
--    se actualizan, asi que no hace falta reservar espacio en cada bloque)
--    y puede tener cuotas y politicas de compresion diferentes.
--
-- El nombre/ruta del datafile se calcula solo:
--   * si la base usa OMF (db_create_file_dest), Oracle lo nombra;
--   * si no, se usa la misma carpeta de los datafiles existentes.
--   * si ya existe el tablespace (ORA-01543), se reutiliza.
-- ============================================================================
DECLARE
    v_omf  VARCHAR2(512);
    v_ruta VARCHAR2(600);
    v_sql  VARCHAR2(1000);
BEGIN
    BEGIN
        EXECUTE IMMEDIATE q'[SELECT value FROM v$parameter WHERE name = 'db_create_file_dest']'
            INTO v_omf;
    EXCEPTION
        WHEN OTHERS THEN v_omf := NULL;
    END;

    IF v_omf IS NOT NULL THEN
        v_sql := 'CREATE TABLESPACE TS_TURISMO_HISTORICO ' ||
                 'DATAFILE SIZE 50M AUTOEXTEND ON NEXT 10M MAXSIZE 1G ' ||
                 'EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';
    ELSE
        BEGIN
            EXECUTE IMMEDIATE q'[SELECT file_name FROM dba_data_files WHERE ROWNUM = 1]'
                INTO v_ruta;
            v_ruta := SUBSTR(v_ruta, 1, GREATEST(INSTR(v_ruta, '/', -1), INSTR(v_ruta, '\', -1)));
        EXCEPTION
            WHEN OTHERS THEN v_ruta := NULL;   -- sin acceso: carpeta por defecto de Oracle
        END;
        v_sql := 'CREATE TABLESPACE TS_TURISMO_HISTORICO ' ||
                 'DATAFILE ''' || v_ruta || 'ts_turismo_historico01.dbf'' ' ||
                 'SIZE 50M REUSE AUTOEXTEND ON NEXT 10M MAXSIZE 1G ' ||
                 'EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';
    END IF;

    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('Tablespace creado: ' || v_sql);
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1543 THEN
            DBMS_OUTPUT.PUT_LINE('El tablespace TS_TURISMO_HISTORICO ya existia; se reutiliza.');
        ELSE
            RAISE;
        END IF;
END;
/

-- Cuota para el usuario actual (si ya tiene UNLIMITED TABLESPACE no hace falta)
BEGIN
    EXECUTE IMMEDIATE 'ALTER USER ' || USER || ' QUOTA UNLIMITED ON TS_TURISMO_HISTORICO';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE RESERVA_HISTORICO CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- Foto resumida e inmutable de cada reserva cerrada (COMPLETADA o CANCELADA).
-- Va desnormalizada a proposito (municipio, alojamiento, totales) para que
-- los reportes historicos no tengan que unir las tablas operativas.
CREATE TABLE RESERVA_HISTORICO (
    reserva_id        NUMBER        NOT NULL,
    cliente_id        NUMBER        NOT NULL,
    alojamiento_id    NUMBER,
    alojamiento       VARCHAR2(150),
    municipio         VARCHAR2(100),
    fecha_reserva     DATE          NOT NULL,
    fecha_checkin     DATE          NOT NULL,
    fecha_checkout    DATE          NOT NULL,
    estado            VARCHAR2(15)  NOT NULL,
    num_habitaciones  NUMBER        NOT NULL,
    noches_habitacion NUMBER        NOT NULL,
    total_pagado      NUMBER(14,2)  NOT NULL,
    fecha_archivo     DATE          NOT NULL,
    CONSTRAINT pk_reserva_historico PRIMARY KEY (reserva_id)
        USING INDEX TABLESPACE TS_TURISMO_HISTORICO,
    CONSTRAINT ck_reshist_estado CHECK (estado IN ('COMPLETADA','CANCELADA'))
)
TABLESPACE TS_TURISMO_HISTORICO
PCTFREE 0;
COMMENT ON TABLE RESERVA_HISTORICO IS 'Historico de reservas cerradas, en el tablespace TS_TURISMO_HISTORICO.';

-- Procedimiento de archivo: copia al historico las reservas cerradas con
-- check-out anterior a la fecha de corte que aun no esten archivadas.
-- No borra de RESERVA porque PAGO, RESENA y las consultas de la Entrega 1
-- dependen de esas filas; en produccion, despues de copiar, se purgarian.
CREATE OR REPLACE PROCEDURE sp_archivar_reservas (
    p_fecha_corte IN DATE DEFAULT TRUNC(SYSDATE, 'YYYY')
) IS
    v_filas NUMBER;
BEGIN
    INSERT INTO RESERVA_HISTORICO (reserva_id, cliente_id, alojamiento_id, alojamiento,
                municipio, fecha_reserva, fecha_checkin, fecha_checkout, estado,
                num_habitaciones, noches_habitacion, total_pagado, fecha_archivo)
    SELECT r.reserva_id, r.cliente_id, a.alojamiento_id, a.nombre_comercial, mu.nombre,
           r.fecha_reserva, r.fecha_checkin, r.fecha_checkout, r.estado,
           l.num_habitaciones, l.noches,
           NVL((SELECT SUM(p.monto) FROM PAGO p
                 WHERE p.reserva_id = r.reserva_id AND p.estado = 'EXITOSO'), 0),
           SYSDATE
      FROM RESERVA r
      JOIN (SELECT rh.reserva_id,
                   MIN(h.alojamiento_id)                     AS alojamiento_id,
                   COUNT(*)                                  AS num_habitaciones,
                   SUM(rh.fecha_checkout - rh.fecha_checkin) AS noches
              FROM RESERVA_HABITACION rh
              JOIN HABITACION h ON h.habitacion_id = rh.habitacion_id
             GROUP BY rh.reserva_id) l ON l.reserva_id = r.reserva_id
      JOIN ALOJAMIENTO a  ON a.alojamiento_id = l.alojamiento_id
      JOIN MUNICIPIO   mu ON mu.municipio_id  = a.municipio_id
     WHERE r.estado IN ('COMPLETADA', 'CANCELADA')
       AND r.fecha_checkout < p_fecha_corte
       AND NOT EXISTS (SELECT 1 FROM RESERVA_HISTORICO x WHERE x.reserva_id = r.reserva_id);

    v_filas := SQL%ROWCOUNT;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Reservas archivadas en RESERVA_HISTORICO: ' || v_filas);
END sp_archivar_reservas;
/
SHOW ERRORS PROCEDURE sp_archivar_reservas;

-- Carga inicial: todo lo cerrado antes de 2026 (anios 2024 y 2025)
EXEC sp_archivar_reservas(DATE '2026-01-01');

-- ============================================================================
-- B) VISTA MATERIALIZADA DE OCUPACION MENSUAL
-- ----------------------------------------------------------------------------
-- Tabla de apoyo CALENDARIO (un dia por fila, 2024-2027). Permite repartir
-- cada estadia en las noches que realmente caen en cada mes: una estadia del
-- 30/01 al 02/02 aporta 2 noches a enero y 1 a febrero (la C1 de la Entrega 1
-- asignaba todas las noches al mes del check-in).
-- ============================================================================
BEGIN
    EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW MV_OCUPACION_MENSUAL';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -12003 THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE CALENDARIO CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

CREATE TABLE CALENDARIO (
    fecha    DATE      NOT NULL,
    anio     NUMBER(4) NOT NULL,
    mes      NUMBER(2) NOT NULL,
    dia      NUMBER(2) NOT NULL,
    CONSTRAINT pk_calendario PRIMARY KEY (fecha)
);
COMMENT ON TABLE CALENDARIO IS 'Un dia por fila (2024-2027); reparte las noches de cada estadia por mes.';

INSERT INTO CALENDARIO (fecha, anio, mes, dia)
SELECT d, EXTRACT(YEAR FROM d), EXTRACT(MONTH FROM d), EXTRACT(DAY FROM d)
FROM  (SELECT DATE '2024-01-01' + LEVEL - 1 AS d FROM dual
       CONNECT BY LEVEL <= DATE '2027-12-31' - DATE '2024-01-01' + 1);
COMMIT;

-- ----------------------------------------------------------------------------
-- MV_OCUPACION_MENSUAL: una fila por alojamiento y mes.
--   noches_disponibles = habitaciones del alojamiento x dias del mes
--   noches_vendidas    = noches de reservas CONFIRMADA o COMPLETADA que caen
--                        en ese mes (PENDIENTE y CANCELADA no ocupan)
--   pct_ocupacion      = vendidas / disponibles x 100
-- Incluye los meses sin ventas (0 %) gracias al CROSS JOIN con los meses y
-- al LEFT JOIN con las ventas; sin eso, los alojamientos pequenos sin
-- reservas en un mes desaparecerian y el promedio de ocupacion se inflaria.
-- Los meses van desde el primer check-in hasta el ultimo check-out que haya
-- en los datos, asi que el rango se amplia solo en cada refresco.
--
-- POLITICA DE REFRESCO: COMPLETE, ON DEMAND, programado cada noche (2:00 a.m.)
-- y manual despues de cada cierre mensual.
--   * Por que no FAST: el refresco rapido exige logs de vista materializada y
--     una consulta "simple". Esta usa CROSS JOIN, LEFT JOIN contra subconsultas
--     agregadas y un join por rango (c.fecha >= checkin AND c.fecha < checkout),
--     construcciones que Oracle no puede refrescar de forma incremental.
--     Ademas, los logs en RESERVA y RESERVA_HABITACION encarecerian cada
--     reserva nueva.
--   * Por que no ON COMMIT: recalcularia la vista en cada COMMIT de una
--     reserva, metiendo un proceso pesado dentro de la transaccion del
--     cliente y serializando las reservas. Inaceptable en OLTP.
--   * Por que diario y de noche: la ocupacion mensual es un indicador de
--     gerencia, no operativo; un dia de retraso es aceptable. La vista es
--     pequena (~60 alojamientos x 37 meses = ~2.200 filas) y el COMPLETE tarda
--     segundos, a las 2:00 a.m. no compite con las reservas.
--   * atomic_refresh => TRUE: el refresco borra e inserta en una sola
--     transaccion, asi quien consulte durante el refresco ve los datos
--     anteriores completos, nunca la vista vacia.
--   * Al cerrar un mes (antes de la liquidacion) se refresca a mano:
--       EXEC DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C');
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW MV_OCUPACION_MENSUAL
BUILD IMMEDIATE
REFRESH COMPLETE ON DEMAND
AS
SELECT a.alojamiento_id,
       a.nombre_comercial                                   AS alojamiento,
       mu.nombre                                            AS municipio,
       ta.nombre                                            AS tipo_alojamiento,
       m.anio,
       m.mes,
       cap.habitaciones,
       cap.habitaciones * m.dias_mes                        AS noches_disponibles,
       NVL(o.noches_vendidas, 0)                            AS noches_vendidas,
       ROUND(100 * NVL(o.noches_vendidas, 0)
                 / (cap.habitaciones * m.dias_mes), 2)      AS pct_ocupacion
FROM   ALOJAMIENTO a
JOIN   MUNICIPIO        mu ON mu.municipio_id        = a.municipio_id
JOIN   TIPO_ALOJAMIENTO ta ON ta.tipo_alojamiento_id = a.tipo_alojamiento_id
JOIN  (SELECT alojamiento_id, COUNT(*) AS habitaciones
       FROM   HABITACION
       GROUP BY alojamiento_id) cap ON cap.alojamiento_id = a.alojamiento_id
CROSS JOIN
      (SELECT c.anio, c.mes, COUNT(*) AS dias_mes
       FROM   CALENDARIO c
       WHERE  c.fecha >= (SELECT TRUNC(MIN(fecha_checkin), 'MM') FROM RESERVA_HABITACION)
       AND    c.fecha <= (SELECT LAST_DAY(MAX(fecha_checkout) - 1) FROM RESERVA_HABITACION)
       GROUP BY c.anio, c.mes) m
LEFT JOIN
      (SELECT h.alojamiento_id, c.anio, c.mes, COUNT(*) AS noches_vendidas
       FROM   RESERVA_HABITACION rh
       JOIN   RESERVA    r ON r.reserva_id    = rh.reserva_id
       JOIN   HABITACION h ON h.habitacion_id = rh.habitacion_id
       JOIN   CALENDARIO c ON c.fecha >= rh.fecha_checkin
                          AND c.fecha <  rh.fecha_checkout
       WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
       GROUP BY h.alojamiento_id, c.anio, c.mes) o
       ON  o.alojamiento_id = a.alojamiento_id
       AND o.anio = m.anio
       AND o.mes  = m.mes;

COMMENT ON MATERIALIZED VIEW MV_OCUPACION_MENSUAL IS 'Ocupacion mensual por alojamiento. Refresco COMPLETE ON DEMAND, diario 2:00 a.m. (JOB_REFRESCO_MV_OCUPACION).';

CREATE INDEX ix_mv_ocup_periodo ON MV_OCUPACION_MENSUAL (anio, mes);

-- Programacion del refresco nocturno con DBMS_SCHEDULER
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('JOB_REFRESCO_MV_OCUPACION', TRUE);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'JOB_REFRESCO_MV_OCUPACION',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN DBMS_MVIEW.REFRESH(''MV_OCUPACION_MENSUAL'', method => ''C'', atomic_refresh => TRUE); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Refresco completo nocturno de MV_OCUPACION_MENSUAL');
    DBMS_OUTPUT.PUT_LINE('Job JOB_REFRESCO_MV_OCUPACION creado (diario 2:00 a.m.).');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('No se pudo crear el job (falta el privilegio CREATE JOB?): ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Refresque manualmente con: EXEC DBMS_MVIEW.REFRESH(''MV_OCUPACION_MENSUAL'',''C'');');
END;
/

-- Verificacion rapida
SELECT mview_name, refresh_mode, refresh_method, build_mode, last_refresh_date
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

SELECT table_name, tablespace_name
FROM   user_tables
WHERE  table_name IN ('RESERVA', 'RESERVA_HISTORICO');

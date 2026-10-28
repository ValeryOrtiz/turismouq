-- ============================================================================
-- TurismoUQ - 03_consultas.sql - Siete consultas de analisis
-- Sin vistas, sin WITH, sin CONNECT BY. Solo SELECT, JOIN, GROUP BY y las
-- funciones pedidas (PIVOT, ROLLUP/GROUPING, RANK, LAG, bind, UNPIVOT).
-- Ejecutar como script (F5)
-- ----------------------------------------------------------------------------
-- CORRECCIONES FRENTE A LA ENTREGA 1 (observaciones de la docente):
--   * C2: las temporadas ahora cubren todos los dias (ver 02_datos.sql), asi
--     que ya no se descartan ingresos; y la temporada se agrupa CON SU ANIO
--     (columna compuesta (t.anio, t.nombre) dentro del ROLLUP).
--   * C5: VARIABLE y EXEC quedan declarados en el script (antes estaban
--     comentados y fallaba con SP2-0552: Bind variable not declared).
--   * C6: el UNPIVOT se aplica sobre columnas reales de RESERVA
--     (fecha_reserva, fecha_checkin, fecha_checkout), no sobre columnas
--     fabricadas por la misma consulta.
-- ============================================================================
SET LINESIZE 200;
SET PAGESIZE 100;
-- NOTAS PARA ENTENDER LAS CONSULTAS
--
--  * INGRESO = suma de PAGO.monto con estado = 'EXITOSO'.
--
--  * Como una reserva puede tener 1, 2 o 3 filas en RESERVA_HABITACION, si se
--    une PAGO con esa tabla el pago se repetiria. Para evitarlo, en las
--    consultas de ingresos se une cada reserva con UNA sola fila:
--       reserva_habitacion_id = (SELECT MIN(reserva_habitacion_id) ...)
--    Segun el script de datos, todas las habitaciones de una misma reserva
--    pertenecen al mismo alojamiento, asi que usar una sola es correcto.
--
--  * El mes y la temporada de un ingreso se toman de RESERVA.fecha_checkin.
-- ============================================================================


-- ============================================================================
-- CONSULTA 1. OCUPACION POR MUNICIPIO Y MES  (PIVOT)
-- Cuantas noches-habitacion se vendieron en cada municipio, mes a mes (2025).
-- Se cuentan las noches de reservas CONFIRMADA o COMPLETADA segun el mes del
-- check-in.
-- ============================================================================
SELECT municipio,
       NVL(ene, 0) AS ene, -- NVL reemplaza los NULL por cero
       NVL(feb, 0) AS feb,
       NVL(mar, 0) AS mar,
       NVL(abr, 0) AS abr,
       NVL(may, 0) AS may,
       NVL(jun, 0) AS jun,
       NVL(jul, 0) AS jul,
       NVL(ago, 0) AS ago,
       NVL(sep, 0) AS sep,
       NVL(oct, 0) AS oct,
       NVL(nov, 0) AS nov,
       NVL(dic, 0) AS dic
FROM (
    SELECT mu.nombre                              AS municipio,
           EXTRACT(MONTH FROM rh.fecha_checkin)   AS mes,
           rh.fecha_checkout - rh.fecha_checkin   AS noches
    FROM   RESERVA_HABITACION rh
    JOIN   RESERVA     r  ON r.reserva_id      = rh.reserva_id
    JOIN   HABITACION  h  ON h.habitacion_id   = rh.habitacion_id
    JOIN   ALOJAMIENTO a  ON a.alojamiento_id  = h.alojamiento_id
    JOIN   MUNICIPIO   mu ON mu.municipio_id   = a.municipio_id
    WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
    AND    EXTRACT(YEAR FROM rh.fecha_checkin) = 2025
)
PIVOT (
    SUM(noches)
    FOR mes IN (1 AS ene, 2 AS feb, 3 AS mar, 4 AS abr, 5 AS may, 6 AS jun,
                7 AS jul, 8 AS ago, 9 AS sep, 10 AS oct, 11 AS nov, 12 AS dic)
)
ORDER BY municipio;


-- ============================================================================
-- CONSULTA 2. INGRESOS POR MUNICIPIO, TIPO DE ALOJAMIENTO Y TEMPORADA (ROLLUP)
-- ROLLUP genera subtotales de derecha a izquierda:
--   (municipio, tipo, temporada) -> (municipio, tipo) -> (municipio) -> total
-- (t.anio, t.nombre) va entre parentesis: es UNA columna compuesta, asi que
-- "Semana Santa 2025" y "Semana Santa 2026" quedan separadas y el ROLLUP no
-- genera un subtotal intermedio solo por anio.
-- GROUPING(col) vale 1 cuando esa columna es un subtotal (no un NULL real).
-- Como TEMPORADA cubre todos los dias 2024-2027, el TOTAL GENERAL coincide
-- con la suma de todos los pagos exitosos (se comprueba en 07_pruebas).
-- ============================================================================
SELECT CASE WHEN GROUPING(mu.nombre) = 1 THEN 'TOTAL GENERAL'
            ELSE mu.nombre END                AS municipio,
       CASE WHEN GROUPING(ta.nombre) = 1 THEN 'Subtotal'
            ELSE ta.nombre END                AS tipo_alojamiento,
       CASE WHEN GROUPING(t.nombre) = 1 THEN 'Subtotal'
            ELSE t.nombre || ' ' || t.anio END AS temporada,
       SUM(p.monto)                           AS ingreso_total
FROM   PAGO p
JOIN   RESERVA           r  ON r.reserva_id           = p.reserva_id
JOIN   RESERVA_HABITACION rh ON rh.reserva_id         = r.reserva_id
                            AND rh.reserva_habitacion_id =
                                (SELECT MIN(x.reserva_habitacion_id)
                                 FROM   RESERVA_HABITACION x
                                 WHERE  x.reserva_id = r.reserva_id)
JOIN   HABITACION        h  ON h.habitacion_id        = rh.habitacion_id
JOIN   ALOJAMIENTO       a  ON a.alojamiento_id       = h.alojamiento_id
JOIN   MUNICIPIO         mu ON mu.municipio_id        = a.municipio_id
JOIN   TIPO_ALOJAMIENTO  ta ON ta.tipo_alojamiento_id = a.tipo_alojamiento_id
JOIN   TEMPORADA         t  ON r.fecha_checkin BETWEEN t.fecha_inicio AND t.fecha_fin
WHERE  p.estado = 'EXITOSO'
GROUP BY ROLLUP (mu.nombre, ta.nombre, (t.anio, t.nombre))
ORDER BY mu.nombre, ta.nombre, t.anio, MIN(t.fecha_inicio);


-- ============================================================================
-- CONSULTA 3. TOP 3 ALOJAMIENTOS DE MAYOR INGRESO POR MUNICIPIO (RANK)
-- RANK() OVER (PARTITION BY municipio ...) reinicia la posicion en cada
-- municipio. Se envuelve en una subconsulta para poder filtrar posicion <= 3.
-- ============================================================================
SELECT municipio, posicion, alojamiento, ingreso_total
FROM (
    SELECT mu.nombre            AS municipio,
           a.nombre_comercial   AS alojamiento,
           SUM(p.monto)         AS ingreso_total,
           RANK() OVER (PARTITION BY mu.nombre
                        ORDER BY SUM(p.monto) DESC) AS posicion
    FROM   PAGO p
    JOIN   RESERVA           r  ON r.reserva_id     = p.reserva_id
    JOIN   RESERVA_HABITACION rh ON rh.reserva_id   = r.reserva_id
                                AND rh.reserva_habitacion_id =
                                    (SELECT MIN(x.reserva_habitacion_id)
                                     FROM   RESERVA_HABITACION x
                                     WHERE  x.reserva_id = r.reserva_id)
    JOIN   HABITACION        h  ON h.habitacion_id  = rh.habitacion_id
    JOIN   ALOJAMIENTO       a  ON a.alojamiento_id = h.alojamiento_id
    JOIN   MUNICIPIO         mu ON mu.municipio_id  = a.municipio_id
    WHERE  p.estado = 'EXITOSO'
    GROUP BY mu.nombre, a.alojamiento_id, a.nombre_comercial
)
WHERE posicion <= 3
ORDER BY municipio, posicion;


-- ============================================================================
-- CONSULTA 4. VARIACION DE INGRESOS MES CONTRA MES (LAG)
-- LAG(ingreso) trae el ingreso de la fila anterior (el mes anterior).
-- Variacion % = (mes actual - mes anterior) / mes anterior * 100
-- ============================================================================
SELECT mes,
       ingreso,
       LAG(ingreso) OVER (ORDER BY mes)                         AS ingreso_mes_anterior,
       ingreso - LAG(ingreso) OVER (ORDER BY mes)               AS variacion,
       ROUND((ingreso - LAG(ingreso) OVER (ORDER BY mes))
             / LAG(ingreso) OVER (ORDER BY mes) * 100, 1)       AS variacion_porcentaje
FROM (
    SELECT TO_CHAR(r.fecha_checkin, 'YYYY-MM') AS mes,
           SUM(p.monto)                        AS ingreso
    FROM   PAGO p
    JOIN   RESERVA r ON r.reserva_id = p.reserva_id
    WHERE  p.estado = 'EXITOSO'
    GROUP BY TO_CHAR(r.fecha_checkin, 'YYYY-MM')
)
ORDER BY mes;


-- ============================================================================
-- CONSULTA 5. CONSULTA PARAMETRIZADA CON VARIABLES DE ENLACE
-- :fecha_desde y :fecha_hasta son variables de enlace (bind variables).
-- Se declaran con VARIABLE y se les asigna valor con EXEC ANTES de la
-- consulta (sin esto SQL*Plus responde SP2-0552). Ejecutar como script (F5).
-- Para otro rango basta con cambiar los dos EXEC; la consulta no se toca y
-- Oracle reutiliza el mismo plan de ejecucion.
--
-- Muestra, por municipio, cuantas reservas hubo y cuanto se recaudo en ese
-- rango de fechas (segun la fecha de check-in).
-- ============================================================================
VARIABLE fecha_desde VARCHAR2(10)
VARIABLE fecha_hasta VARCHAR2(10)
EXEC :fecha_desde := '2025-06-01';
EXEC :fecha_hasta := '2025-07-31';

SELECT mu.nombre               AS municipio,
       COUNT(DISTINCT r.reserva_id) AS reservas,
       SUM(p.monto)            AS ingreso_total
FROM   PAGO p
JOIN   RESERVA           r  ON r.reserva_id     = p.reserva_id
JOIN   RESERVA_HABITACION rh ON rh.reserva_id   = r.reserva_id
                            AND rh.reserva_habitacion_id =
                                (SELECT MIN(x.reserva_habitacion_id)
                                 FROM   RESERVA_HABITACION x
                                 WHERE  x.reserva_id = r.reserva_id)
JOIN   HABITACION        h  ON h.habitacion_id  = rh.habitacion_id
JOIN   ALOJAMIENTO       a  ON a.alojamiento_id = h.alojamiento_id
JOIN   MUNICIPIO         mu ON mu.municipio_id  = a.municipio_id
WHERE  p.estado = 'EXITOSO'
AND    r.fecha_checkin BETWEEN TO_DATE(:fecha_desde, 'YYYY-MM-DD')
                           AND TO_DATE(:fecha_hasta, 'YYYY-MM-DD')
GROUP BY mu.nombre
ORDER BY ingreso_total DESC;


-- ============================================================================
-- CONSULTA 6. UNPIVOT SOBRE COLUMNAS REALES
-- PREGUNTA: "Cuanta actividad operativa hay cada mes: reservas que se crean,
-- huespedes que llegan (check-in) y huespedes que salen (check-out)?"
-- Sirve para planear el personal de recepcion mes a mes.
--
-- RESERVA tiene tres columnas reales de fecha: fecha_reserva, fecha_checkin
-- y fecha_checkout. UNPIVOT las convierte en filas: cada reserva produce 3
-- filas (tipo_evento, fecha_evento). Despues se cuentan los eventos por mes.
-- Se excluyen las reservas canceladas y se muestra 2025.
-- ============================================================================
SELECT TO_CHAR(fecha_evento, 'YYYY-MM') AS mes,
       tipo_evento,
       COUNT(*)                         AS eventos
FROM   RESERVA
UNPIVOT (
    fecha_evento FOR tipo_evento IN (fecha_reserva  AS 'RESERVA_CREADA',
                                     fecha_checkin  AS 'CHECK_IN',
                                     fecha_checkout AS 'CHECK_OUT')
)
WHERE  estado <> 'CANCELADA'
AND    EXTRACT(YEAR FROM fecha_evento) = 2025
GROUP BY TO_CHAR(fecha_evento, 'YYYY-MM'), tipo_evento
ORDER BY mes, tipo_evento;


-- ============================================================================
-- CONSULTA 7. CONSULTA LIBRE
-- PREGUNTA DE NEGOCIO: "Que tipo de alojamiento (finca, hotel, glamping,
-- hostal) tiene mejor calificacion de los huespedes?"
-- Sirve para decidir en que tipo de negocio conviene invertir o promocionar.
-- Se muestran tambien cuantos alojamientos y resenas respaldan cada promedio,
-- porque un promedio con pocas resenas no es confiable.
-- ============================================================================
SELECT ta.nombre                         AS tipo_alojamiento,
       COUNT(DISTINCT a.alojamiento_id)  AS alojamientos,
       COUNT(rs.resena_id)               AS resenas,
       ROUND(AVG(rs.calificacion), 2)    AS calificacion_promedio
FROM   TIPO_ALOJAMIENTO ta
JOIN   ALOJAMIENTO a   ON a.tipo_alojamiento_id = ta.tipo_alojamiento_id
LEFT JOIN RESENA rs    ON rs.alojamiento_id     = a.alojamiento_id
GROUP BY ta.nombre
ORDER BY calificacion_promedio DESC;

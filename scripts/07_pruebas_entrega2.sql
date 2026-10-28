-- ============================================================================
-- TurismoUQ - 07_pruebas_entrega2.sql               (ENTREGA 2 - entregable 4)
-- Evidencia de prueba de cada componente. Ejecutar como script (F5) despues
-- de 01 a 06. Con SPOOL todo el resultado queda en un archivo de texto que
-- se sube al repositorio como evidencia (evidencias/07_resultado_pruebas.txt).
-- Cada prueba imprime OK o FALLO; los casos de error muestran el ORA-200xx.
--
--   P0  Correcciones de la Entrega 1 (datos)
--   P1  fn_valor_estadia                  (20 %)
--   P2  sp_crear_reserva                  (15 %)
--   P3  Cursor de liquidacion mensual     (15 %)
--   P4  Paquete                           (10 %)
--   P5  Disparador de sentencia: auditoria TARIFA (10 %)
--   P6  Disparador de fila: solapes       (10 %)
--   P7  Tablespace                        (5 %)
--   P8  Vista materializada               (15 %)
-- ============================================================================

-- Cambie la ruta si quiere el archivo en otra carpeta (ej. C:\turismouq\evidencias\...)
SPOOL 07_resultado_pruebas.txt

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET DEFINE OFF;
SET ECHO ON;
SET FEEDBACK ON;
SET LINESIZE 220;
SET PAGESIZE 200;
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';

SELECT USER AS usuario, SYSDATE AS fecha_ejecucion FROM dual;

-- ============================================================================
-- P0. CORRECCIONES DE LA ENTREGA 1
-- ============================================================================
PROMPT ===== P0.1 Volumenes (RESERVA_SERVICIO debe ser >= 40.000) =====
SELECT 'TEMPORADA' tabla, COUNT(*) filas FROM TEMPORADA
UNION ALL SELECT 'TARIFA', COUNT(*) FROM TARIFA
UNION ALL SELECT 'RESERVA', COUNT(*) FROM RESERVA
UNION ALL SELECT 'RESERVA_HABITACION', COUNT(*) FROM RESERVA_HABITACION
UNION ALL SELECT 'PAGO', COUNT(*) FROM PAGO
UNION ALL SELECT 'SERVICIO', COUNT(*) FROM SERVICIO
UNION ALL SELECT 'RESERVA_SERVICIO', COUNT(*) FROM RESERVA_SERVICIO;

PROMPT ===== P0.2 Temporadas por anio y dias sin temporada / con cruce (deben ser 0) =====
SELECT anio, COUNT(*) AS temporadas, MIN(fecha_inicio) AS desde, MAX(fecha_fin) AS hasta,
       SUM(fecha_fin - fecha_inicio + 1) AS dias_cubiertos
FROM   TEMPORADA GROUP BY anio ORDER BY anio;

SELECT SUM(CASE WHEN n = 0 THEN 1 ELSE 0 END) AS dias_sin_temporada,
       SUM(CASE WHEN n > 1 THEN 1 ELSE 0 END) AS dias_con_cruce
FROM  (SELECT c.fecha, COUNT(t.temporada_id) AS n
       FROM   CALENDARIO c
       LEFT JOIN TEMPORADA t ON c.fecha BETWEEN t.fecha_inicio AND t.fecha_fin
       GROUP BY c.fecha);

PROMPT ===== P0.3 Solapes de habitacion en los datos (debe ser 0) =====
SELECT COUNT(*) AS solapes_habitacion
FROM   RESERVA_HABITACION a
JOIN   RESERVA_HABITACION b
       ON  a.habitacion_id = b.habitacion_id
       AND a.reserva_habitacion_id < b.reserva_habitacion_id
       AND a.fecha_checkin  < b.fecha_checkout
       AND b.fecha_checkin  < a.fecha_checkout;

PROMPT ===== P0.4 UNIQUE en CLIENTE.correo (debe rechazar el duplicado) =====
BEGIN
    INSERT INTO CLIENTE (nombre, documento_identidad, correo)
    VALUES ('Cliente Duplicado', 'DOC-PRUEBA-UQ', 'cliente1@correo.com');
    DBMS_OUTPUT.PUT_LINE('FALLO: se acepto un correo repetido');
    ROLLBACK;
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P0.5 Montos de PAGO salen de TARIFA (diferencias debe ser 0) =====
-- En reservas no canceladas, la suma de sus pagos = estadia noche a noche + servicios
SELECT COUNT(*) AS reservas_revisadas,
       SUM(CASE WHEN ABS(pagado - calculado) > 0.01 THEN 1 ELSE 0 END) AS diferencias
FROM  (SELECT r.reserva_id,
              (SELECT SUM(p.monto) FROM PAGO p WHERE p.reserva_id = r.reserva_id) AS pagado,
              pkg_turismo.fn_valor_reserva(r.reserva_id) AS calculado
       FROM   RESERVA r
       WHERE  r.estado <> 'CANCELADA'
       AND    MOD(r.reserva_id, 10) = 0
       AND    EXISTS (SELECT 1 FROM PAGO p WHERE p.reserva_id = r.reserva_id));

PROMPT ===== P0.6 La C2 ya no descarta ingresos (las dos columnas deben ser iguales) =====
SELECT (SELECT SUM(monto) FROM PAGO WHERE estado = 'EXITOSO') AS total_pagos_exitosos,
       (SELECT SUM(p.monto)
        FROM   PAGO p
        JOIN   RESERVA r   ON r.reserva_id = p.reserva_id
        JOIN   TEMPORADA t ON r.fecha_checkin BETWEEN t.fecha_inicio AND t.fecha_fin
        WHERE  p.estado = 'EXITOSO')                       AS total_con_temporada
FROM dual;

-- ============================================================================
-- P1. fn_valor_estadia
-- ============================================================================
VARIABLE hab NUMBER
EXEC SELECT MIN(habitacion_id) INTO :hab FROM HABITACION;
PRINT hab

PROMPT ===== P1.1 Detalle noche a noche de una estadia que cruza dos temporadas =====
PROMPT        28/11/2026 -> 03/12/2026: 3 noches en Temporada media III y 2 en Fin de ano
SELECT n.noche, t.nombre || ' ' || t.anio AS temporada, t.categoria, ta.precio_noche
FROM  (SELECT DATE '2026-11-28' + LEVEL - 1 AS noche FROM dual
       CONNECT BY LEVEL <= DATE '2026-12-03' - DATE '2026-11-28') n
JOIN   TEMPORADA t ON n.noche BETWEEN t.fecha_inicio AND t.fecha_fin
JOIN   TARIFA ta   ON ta.temporada_id = t.temporada_id AND ta.habitacion_id = :hab
ORDER BY n.noche;

SELECT pkg_turismo.fn_valor_estadia(:hab, DATE '2026-11-28', DATE '2026-12-03') AS valor_funcion
FROM dual;

PROMPT ===== P1.2 Casos: el valor de la funcion contra un calculo independiente en SQL =====
DECLARE
    v_hab NUMBER := :hab;

    PROCEDURE probar(p_desc VARCHAR2, p_in DATE, p_out DATE) IS
        v_esperado NUMBER;
        v_noches   NUMBER;
        v_temps    NUMBER;
        v_calc     NUMBER;
    BEGIN
        -- calculo independiente: una fila por noche, unida a su temporada y tarifa
        SELECT SUM(ta.precio_noche), COUNT(*), COUNT(DISTINCT t.temporada_id)
          INTO v_esperado, v_noches, v_temps
          FROM (SELECT p_in + LEVEL - 1 AS noche FROM dual
                CONNECT BY LEVEL <= p_out - p_in) n
          JOIN TEMPORADA t ON n.noche BETWEEN t.fecha_inicio AND t.fecha_fin
          JOIN TARIFA ta   ON ta.temporada_id = t.temporada_id AND ta.habitacion_id = v_hab;

        v_calc := pkg_turismo.fn_valor_estadia(v_hab, p_in, p_out);

        DBMS_OUTPUT.PUT_LINE(RPAD(p_desc, 48) || ' noches=' || LPAD(v_noches, 3) ||
            ' temporadas=' || v_temps || ' esperado=' || LPAD(v_esperado, 10) ||
            ' funcion=' || LPAD(v_calc, 10) ||
            CASE WHEN v_esperado = v_calc THEN '   OK' ELSE '   FALLO' END);
    END;
BEGIN
    probar('Una temporada (05/10/2026-08/10/2026)',      DATE '2026-10-05', DATE '2026-10-08');
    probar('Dos temporadas (28/11/2026-03/12/2026)',     DATE '2026-11-28', DATE '2026-12-03');
    probar('Tres temporadas, S. Santa (27/03-08/04/26)', DATE '2026-03-27', DATE '2026-04-08');
    probar('Cambio de anio (29/12/2026-03/01/2027)',     DATE '2026-12-29', DATE '2027-01-03');
    probar('Una sola noche (24/12/2025-25/12/2025)',     DATE '2025-12-24', DATE '2025-12-25');
    probar('Cuatro temporadas (01/06/2025-20/08/2025)',  DATE '2025-06-01', DATE '2025-08-20');
    probar('Anio 2024 (antes sin temporadas)',           DATE '2024-07-18', DATE '2024-07-23');
END;
/

PROMPT ===== P1.3 Errores esperados de fn_valor_estadia =====
DECLARE
    v NUMBER;
BEGIN
    v := pkg_turismo.fn_valor_estadia(:hab, DATE '2026-12-10', DATE '2026-12-10');
    DBMS_OUTPUT.PUT_LINE('FALLO: checkout = checkin fue aceptado');
EXCEPTION
    WHEN pkg_turismo.e_fechas_invalidas THEN DBMS_OUTPUT.PUT_LINE('OK  checkout = checkin  -> ' || SQLERRM);
END;
/
DECLARE
    v NUMBER;
BEGIN
    v := pkg_turismo.fn_valor_estadia(:hab, DATE '2026-12-10', DATE '2026-12-07');
    DBMS_OUTPUT.PUT_LINE('FALLO: checkout < checkin fue aceptado');
EXCEPTION
    WHEN pkg_turismo.e_fechas_invalidas THEN DBMS_OUTPUT.PUT_LINE('OK  checkout < checkin  -> ' || SQLERRM);
END;
/
DECLARE
    v NUMBER;
BEGIN
    v := pkg_turismo.fn_valor_estadia(-1, DATE '2026-12-10', DATE '2026-12-12');
    DBMS_OUTPUT.PUT_LINE('FALLO: habitacion inexistente aceptada');
EXCEPTION
    WHEN pkg_turismo.e_habitacion_no_existe THEN DBMS_OUTPUT.PUT_LINE('OK  habitacion -1      -> ' || SQLERRM);
END;
/
DECLARE
    v NUMBER;
BEGIN
    v := pkg_turismo.fn_valor_estadia(:hab, DATE '2027-12-30', DATE '2028-01-02');
    DBMS_OUTPUT.PUT_LINE('FALLO: noche sin tarifa aceptada');
EXCEPTION
    WHEN pkg_turismo.e_sin_tarifa THEN DBMS_OUTPUT.PUT_LINE('OK  noche sin tarifa    -> ' || SQLERRM);
END;
/

-- ============================================================================
-- P2. sp_crear_reserva (y sp_agregar_habitacion)
-- ============================================================================
VARIABLE cli        NUMBER
VARIABLE hab_libre  NUMBER
VARIABLE cap        NUMBER
VARIABLE aloj_libre NUMBER
VARIABLE hab2       NUMBER
VARIABLE hab_otro   NUMBER
VARIABLE res1       NUMBER
VARIABLE val1       NUMBER
VARIABLE res2       NUMBER
VARIABLE val2       NUMBER

-- Se buscan habitaciones libres entre el 20/11/2026 y el 15/12/2026
DECLARE
    FUNCTION libre(p_hab NUMBER) RETURN BOOLEAN IS
        n NUMBER;
    BEGIN
        SELECT COUNT(*) INTO n
          FROM RESERVA_HABITACION rh JOIN RESERVA r ON r.reserva_id = rh.reserva_id
         WHERE rh.habitacion_id = p_hab AND r.estado <> 'CANCELADA'
           AND rh.fecha_checkin < DATE '2026-12-15' AND rh.fecha_checkout > DATE '2026-11-20';
        RETURN n = 0;
    END;
BEGIN
    SELECT MIN(cliente_id) INTO :cli FROM CLIENTE;
    :hab_libre := NULL;
    :hab2      := NULL;
    :hab_otro  := NULL;
    FOR h IN (SELECT habitacion_id, capacidad_maxima, alojamiento_id
                FROM HABITACION ORDER BY habitacion_id) LOOP
        IF :hab_libre IS NULL THEN
            IF h.capacidad_maxima >= 2 AND libre(h.habitacion_id) THEN
                :hab_libre := h.habitacion_id; :cap := h.capacidad_maxima; :aloj_libre := h.alojamiento_id;
            END IF;
        ELSIF :hab2 IS NULL AND h.alojamiento_id = :aloj_libre THEN
            IF libre(h.habitacion_id) THEN :hab2 := h.habitacion_id; END IF;
        ELSIF :hab_otro IS NULL AND h.alojamiento_id <> :aloj_libre THEN
            IF libre(h.habitacion_id) THEN :hab_otro := h.habitacion_id; END IF;
        END IF;
        EXIT WHEN :hab_libre IS NOT NULL AND :hab2 IS NOT NULL AND :hab_otro IS NOT NULL;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('cliente=' || :cli || '  habitacion=' || :hab_libre || ' (capacidad ' || :cap ||
                         ', alojamiento ' || :aloj_libre || ')  hab2=' || :hab2 || '  hab_otro=' || :hab_otro);
END;
/

PROMPT ===== P2.1 Reserva valida que cruza temporadas (28/11/2026 -> 03/12/2026, 2 huespedes) =====
BEGIN
    pkg_turismo.sp_crear_reserva(
        p_cliente_id    => :cli,
        p_habitacion_id => :hab_libre,
        p_fecha_in      => DATE '2026-11-28',
        p_fecha_out     => DATE '2026-12-03',
        p_num_huespedes => 2,
        p_reserva_id    => :res1,
        p_valor_estadia => :val1,
        p_estado        => 'CONFIRMADA');
    DBMS_OUTPUT.PUT_LINE('OK  reserva creada: ' || :res1 || '  valor estadia: ' || :val1 ||
        CASE WHEN :val1 = pkg_turismo.fn_valor_estadia(:hab_libre, DATE '2026-11-28', DATE '2026-12-03')
             THEN '  (= fn_valor_estadia)' ELSE '  FALLO: no coincide con la funcion' END);
END;
/
SELECT r.reserva_id, r.cliente_id, r.fecha_checkin, r.fecha_checkout, r.estado,
       rh.habitacion_id, rh.num_huespedes
FROM   RESERVA r JOIN RESERVA_HABITACION rh ON rh.reserva_id = r.reserva_id
WHERE  r.reserva_id = :res1;

PROMPT ===== P2.2 Habitacion no disponible (-20001): misma habitacion 01/12 -> 04/12 =====
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-01', DATE '2026-12-04', 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: se acepto una reserva solapada');
EXCEPTION
    WHEN pkg_turismo.e_habitacion_no_disponible THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P2.3 Checkout igual al checkin (-20002) =====
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-10', DATE '2026-12-10', 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: checkout = checkin aceptado');
EXCEPTION
    WHEN pkg_turismo.e_fechas_invalidas THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P2.4 Checkout anterior al checkin (-20002) =====
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-10', DATE '2026-12-08', 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: checkout < checkin aceptado');
EXCEPTION
    WHEN pkg_turismo.e_fechas_invalidas THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P2.5 Capacidad excedida (-20003): capacidad + 1 huespedes =====
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-10', DATE '2026-12-12', :cap + 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: se excedio la capacidad');
EXCEPTION
    WHEN pkg_turismo.e_capacidad_excedida THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P2.6 Otras validaciones: cliente, habitacion y estado (-20004, -20005, -20012) =====
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(-1, :hab_libre, DATE '2026-12-10', DATE '2026-12-12', 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: cliente inexistente aceptado');
EXCEPTION
    WHEN pkg_turismo.e_cliente_no_existe THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, -1, DATE '2026-12-10', DATE '2026-12-12', 1, v_id, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: habitacion inexistente aceptada');
EXCEPTION
    WHEN pkg_turismo.e_habitacion_no_existe THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/
DECLARE
    v_id NUMBER; v_val NUMBER;
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-10', DATE '2026-12-12', 1, v_id, v_val, 'COMPLETADA');
    DBMS_OUTPUT.PUT_LINE('FALLO: estado inicial invalido aceptado');
EXCEPTION
    WHEN pkg_turismo.e_parametro_invalido THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

PROMPT ===== P2.7 Borde: entrar el mismo dia del check-out anterior (03/12 -> 05/12) si se permite =====
BEGIN
    pkg_turismo.sp_crear_reserva(:cli, :hab_libre, DATE '2026-12-03', DATE '2026-12-05', 1, :res2, :val2);
    DBMS_OUTPUT.PUT_LINE('OK  reserva creada: ' || :res2 || '  valor: ' || :val2 || ' (estado por defecto PENDIENTE)');
END;
/

PROMPT ===== P2.8 Reserva de grupo: segunda habitacion del mismo alojamiento, llega un dia despues =====
DECLARE
    v_val NUMBER;
BEGIN
    pkg_turismo.sp_agregar_habitacion(:res1, :hab2, DATE '2026-11-29', DATE '2026-12-03', 1, v_val);
    DBMS_OUTPUT.PUT_LINE('OK  linea agregada, valor linea: ' || v_val ||
                         '  valor total reserva: ' || pkg_turismo.fn_valor_reserva(:res1) ||
                         CASE WHEN pkg_turismo.fn_valor_reserva(:res1) = :val1 + v_val
                              THEN '  (= estadia 1 + estadia 2)' ELSE '  FALLO' END);
END;
/
DECLARE
    v_val NUMBER;
BEGIN
    pkg_turismo.sp_agregar_habitacion(:res1, :hab_otro, DATE '2026-11-28', DATE '2026-12-03', 1, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: se agrego una habitacion de otro alojamiento');
EXCEPTION
    WHEN pkg_turismo.e_otro_alojamiento THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/
DECLARE
    v_val NUMBER;
BEGIN
    pkg_turismo.sp_agregar_habitacion(:res1, :hab2, DATE '2026-11-25', DATE '2026-11-29', 1, v_val);
    DBMS_OUTPUT.PUT_LINE('FALLO: se acepto una linea fuera del rango de la reserva');
EXCEPTION
    WHEN pkg_turismo.e_fechas_invalidas THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

COMMIT;

SELECT r.reserva_id, r.estado, rh.habitacion_id, rh.fecha_checkin, rh.fecha_checkout, rh.num_huespedes,
       pkg_turismo.fn_valor_estadia(rh.habitacion_id, rh.fecha_checkin, rh.fecha_checkout) AS valor_linea
FROM   RESERVA r JOIN RESERVA_HABITACION rh ON rh.reserva_id = r.reserva_id
WHERE  r.reserva_id IN (:res1, :res2)
ORDER BY r.reserva_id, rh.reserva_habitacion_id;

-- ============================================================================
-- P3. CURSOR EXPLICITO CON PARAMETROS: LIQUIDACION MENSUAL
-- ============================================================================
PROMPT ===== P3.1 Liquidacion de julio 2025, todos los alojamientos =====
EXEC pkg_turismo.sp_liquidacion_mensual(2025, 7);

PROMPT ===== P3.2 Resumen guardado en LIQUIDACION_MENSUAL =====
SELECT COUNT(*) AS alojamientos, SUM(num_reservas) AS reservas, SUM(noches_vendidas) AS noches,
       SUM(valor_hospedaje) AS hospedaje, SUM(valor_servicios) AS servicios,
       SUM(valor_bruto) AS bruto, SUM(valor_comision) AS comision, SUM(valor_neto) AS neto
FROM   LIQUIDACION_MENSUAL
WHERE  anio = 2025 AND mes = 7;

PROMPT ===== P3.3 Verificacion independiente (noches contra la vista materializada, hospedaje con CALENDARIO) =====
SELECT (SELECT SUM(noches_vendidas) FROM LIQUIDACION_MENSUAL WHERE anio = 2025 AND mes = 7) AS noches_liquidacion,
       (SELECT SUM(noches_vendidas) FROM MV_OCUPACION_MENSUAL WHERE anio = 2025 AND mes = 7) AS noches_vista_mat,
       (SELECT SUM(valor_hospedaje) FROM LIQUIDACION_MENSUAL WHERE anio = 2025 AND mes = 7) AS hospedaje_liquidacion,
       (SELECT SUM(ta.precio_noche)
        FROM   RESERVA_HABITACION rh
        JOIN   RESERVA r    ON r.reserva_id = rh.reserva_id
        JOIN   CALENDARIO c ON c.fecha >= rh.fecha_checkin AND c.fecha < rh.fecha_checkout
        JOIN   TEMPORADA t  ON c.fecha BETWEEN t.fecha_inicio AND t.fecha_fin
        JOIN   TARIFA ta    ON ta.habitacion_id = rh.habitacion_id AND ta.temporada_id = t.temporada_id
        WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
        AND    c.anio = 2025 AND c.mes = 7)                                                AS hospedaje_noche_a_noche
FROM dual;

PROMPT ===== P3.4 Top 5 alojamientos de julio 2025 por valor neto =====
SELECT l.alojamiento_id, a.nombre_comercial, l.num_reservas, l.noches_vendidas,
       l.valor_bruto, l.valor_comision, l.valor_neto
FROM   LIQUIDACION_MENSUAL l JOIN ALOJAMIENTO a ON a.alojamiento_id = l.alojamiento_id
WHERE  l.anio = 2025 AND l.mes = 7
ORDER BY l.valor_neto DESC
FETCH FIRST 5 ROWS ONLY;

PROMPT ===== P3.5 Mismo cursor con otros parametros: un solo alojamiento, diciembre 2025, comision 15 % =====
VARIABLE aloj_top NUMBER
EXEC SELECT alojamiento_id INTO :aloj_top FROM (SELECT alojamiento_id FROM MV_OCUPACION_MENSUAL WHERE anio = 2025 AND mes = 12 ORDER BY noches_vendidas DESC) WHERE ROWNUM = 1;
EXEC pkg_turismo.sp_liquidacion_mensual(2025, 12, :aloj_top, 0.15);

PROMPT ===== P3.6 Parametro invalido (-20012) =====
BEGIN
    pkg_turismo.sp_liquidacion_mensual(2025, 13);
    DBMS_OUTPUT.PUT_LINE('FALLO: mes 13 aceptado');
EXCEPTION
    WHEN pkg_turismo.e_parametro_invalido THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
END;
/

-- ============================================================================
-- P4. PAQUETE
-- ============================================================================
PROMPT ===== P4.1 Estado del paquete y subprogramas publicos =====
SELECT object_name, object_type, status, last_ddl_time
FROM   user_objects
WHERE  object_name = 'PKG_TURISMO';

SELECT object_name AS paquete, procedure_name AS subprograma, subprogram_id
FROM   user_procedures
WHERE  object_name = 'PKG_TURISMO' AND procedure_name IS NOT NULL
ORDER BY subprogram_id;

-- ============================================================================
-- P5. DISPARADOR DE SENTENCIA: AUDITORIA DE TARIFA
-- Se modifican tarifas de 'Temporada media III 2027' (sin reservas, asi no se
-- alteran los montos ya pagados).
-- ============================================================================
VARIABLE temp_prueba NUMBER
VARIABLE precio_guardado NUMBER
EXEC SELECT temporada_id INTO :temp_prueba FROM TEMPORADA WHERE nombre = 'Temporada media III' AND anio = 2027;

PROMPT ===== P5.1 Tarifas antes del cambio =====
SELECT ta.habitacion_id, ta.temporada_id, ta.precio_noche
FROM   TARIFA ta JOIN HABITACION h ON h.habitacion_id = ta.habitacion_id
WHERE  ta.temporada_id = :temp_prueba AND h.alojamiento_id = :aloj_top
ORDER BY ta.habitacion_id;

PROMPT ===== P5.2 Una sola sentencia UPDATE que cambia varias filas (+5.000) =====
UPDATE TARIFA
SET    precio_noche = precio_noche + 5000
WHERE  temporada_id = :temp_prueba
AND    habitacion_id IN (SELECT habitacion_id FROM HABITACION WHERE alojamiento_id = :aloj_top);

PROMPT ===== P5.3 UPDATE que no cambia el precio (no debe auditar filas) =====
UPDATE TARIFA SET precio_noche = precio_noche
WHERE  temporada_id = :temp_prueba AND habitacion_id = :hab;

PROMPT ===== P5.4 DELETE e INSERT de una tarifa (operaciones DELETE e INSERT) =====
EXEC SELECT precio_noche INTO :precio_guardado FROM TARIFA WHERE habitacion_id = :hab AND temporada_id = :temp_prueba;
DELETE FROM TARIFA WHERE habitacion_id = :hab AND temporada_id = :temp_prueba;
INSERT INTO TARIFA (habitacion_id, temporada_id, precio_noche) VALUES (:hab, :temp_prueba, :precio_guardado);
COMMIT;

PROMPT ===== P5.5 Auditoria agrupada por sentencia (quien y cuando, una fila por sentencia) =====
SELECT id_sentencia, operacion, COUNT(*) AS filas_auditadas,
       MIN(usuario_bd) AS usuario_bd, MIN(usuario_so) AS usuario_so, MIN(equipo) AS equipo,
       MIN(fecha_hora) AS fecha_hora
FROM   AUDITORIA_TARIFA
GROUP BY id_sentencia, operacion
ORDER BY id_sentencia;

PROMPT ===== P5.6 Detalle: valor anterior y nuevo =====
SELECT id_sentencia, operacion, habitacion_id, temporada_id, precio_anterior, precio_nuevo,
       usuario_bd, TO_CHAR(fecha_hora, 'DD/MM/YYYY HH24:MI:SS.FF3') AS fecha_hora
FROM   AUDITORIA_TARIFA
ORDER BY auditoria_id
FETCH FIRST 15 ROWS ONLY;

-- ============================================================================
-- P6. DISPARADOR DE FILA: SIN SOLAPES
-- Se inserta DIRECTAMENTE en RESERVA_HABITACION (sin pasar por el paquete)
-- para probar que el disparador es quien impide el solape.
-- ============================================================================
VARIABLE res_prueba NUMBER
VARIABLE res_cancel NUMBER

PROMPT ===== P6.1 Lineas activas actuales de la habitacion de prueba =====
SELECT rh.reserva_id, r.estado, rh.habitacion_id, rh.fecha_checkin, rh.fecha_checkout
FROM   RESERVA_HABITACION rh JOIN RESERVA r ON r.reserva_id = rh.reserva_id
WHERE  rh.habitacion_id = :hab_libre AND rh.fecha_checkin >= DATE '2026-11-01'
ORDER BY rh.fecha_checkin;

BEGIN
    INSERT INTO RESERVA (cliente_id, fecha_checkin, fecha_checkout, estado)
    VALUES (:cli, DATE '2026-12-01', DATE '2026-12-07', 'CONFIRMADA')
    RETURNING reserva_id INTO :res_prueba;
    INSERT INTO RESERVA (cliente_id, fecha_checkin, fecha_checkout, estado)
    VALUES (:cli, DATE '2026-12-01', DATE '2026-12-07', 'CANCELADA')
    RETURNING reserva_id INTO :res_cancel;
END;
/

PROMPT ===== P6.2 CASO REAL: INSERT directo que se solapa (01/12 -> 06/12) -> debe dar ORA-20011 =====
INSERT INTO RESERVA_HABITACION (reserva_id, habitacion_id, fecha_checkin, fecha_checkout, num_huespedes)
VALUES (:res_prueba, :hab_libre, DATE '2026-12-01', DATE '2026-12-06', 1);

PROMPT ===== P6.3 Mismo caso con manejo de excepcion =====
BEGIN
    INSERT INTO RESERVA_HABITACION (reserva_id, habitacion_id, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (:res_prueba, :hab_libre, DATE '2026-12-02', DATE '2026-12-04', 1);
    DBMS_OUTPUT.PUT_LINE('FALLO: el disparador dejo pasar un solape');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20011 THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
        ELSE RAISE; END IF;
END;
/

PROMPT ===== P6.4 Sin solape: entra el dia en que sale la anterior (05/12 -> 07/12) -> se acepta =====
BEGIN
    INSERT INTO RESERVA_HABITACION (reserva_id, habitacion_id, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (:res_prueba, :hab_libre, DATE '2026-12-05', DATE '2026-12-07', 1);
    DBMS_OUTPUT.PUT_LINE('OK  linea sin solape aceptada');
END;
/

PROMPT ===== P6.5 Linea de una reserva CANCELADA: no ocupa la habitacion -> se acepta =====
BEGIN
    INSERT INTO RESERVA_HABITACION (reserva_id, habitacion_id, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (:res_cancel, :hab_libre, DATE '2026-12-01', DATE '2026-12-06', 1);
    DBMS_OUTPUT.PUT_LINE('OK  linea de reserva cancelada aceptada (no ocupa)');
END;
/

PROMPT ===== P6.6 Intentar mover las fechas de una linea existente -> ORA-20013 =====
BEGIN
    UPDATE RESERVA_HABITACION
    SET    fecha_checkout = fecha_checkout + 3
    WHERE  reserva_id = :res1 AND habitacion_id = :hab_libre;
    DBMS_OUTPUT.PUT_LINE('FALLO: se permitio cambiar fechas');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20013 THEN DBMS_OUTPUT.PUT_LINE('OK  -> ' || SQLERRM);
        ELSE RAISE; END IF;
END;
/

-- Se deshacen las filas de prueba de P6 (P2 y P5 ya quedaron confirmadas)
ROLLBACK;

PROMPT ===== P6.7 Disparadores creados =====
SELECT trigger_name, trigger_type, triggering_event, table_name, status
FROM   user_triggers
WHERE  trigger_name IN ('TRG_TARIFA_AUDITORIA', 'TRG_RESHAB_NO_SOLAPE');

-- ============================================================================
-- P7. TABLESPACE
-- ============================================================================
PROMPT ===== P7.1 Tablespace propio =====
SELECT tablespace_name, status, contents, extent_management, segment_space_management
FROM   user_tablespaces
WHERE  tablespace_name = 'TS_TURISMO_HISTORICO';

PROMPT ===== P7.2 Segmentos dentro del tablespace (tabla historica y su indice) vs RESERVA =====
SELECT segment_name, segment_type, tablespace_name, ROUND(bytes / 1024 / 1024, 2) AS mb
FROM   user_segments
WHERE  segment_name IN ('RESERVA', 'RESERVA_HISTORICO', 'PK_RESERVA_HISTORICO')
ORDER BY tablespace_name, segment_name;

PROMPT ===== P7.3 Contenido del historico =====
SELECT estado, COUNT(*) AS reservas, MIN(fecha_checkin) AS desde, MAX(fecha_checkout) AS hasta,
       SUM(total_pagado) AS total_pagado
FROM   RESERVA_HISTORICO
GROUP BY estado;

PROMPT ===== P7.4 Archivar de nuevo no duplica (debe archivar 0) =====
EXEC sp_archivar_reservas(DATE '2026-01-01');

PROMPT ===== P7.5 Datafile (requiere acceso a DBA_DATA_FILES) =====
DECLARE
    v_archivo VARCHAR2(600);
    v_mb      NUMBER;
    v_auto    VARCHAR2(3);
BEGIN
    EXECUTE IMMEDIATE q'[SELECT file_name, ROUND(bytes/1024/1024), autoextensible
                         FROM dba_data_files WHERE tablespace_name = 'TS_TURISMO_HISTORICO'
                         AND ROWNUM = 1]'
        INTO v_archivo, v_mb, v_auto;
    DBMS_OUTPUT.PUT_LINE('Datafile: ' || v_archivo || '  ' || v_mb || ' MB  autoextend=' || v_auto);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Sin acceso a DBA_DATA_FILES: ' || SQLERRM);
END;
/

-- ============================================================================
-- P8. VISTA MATERIALIZADA DE OCUPACION MENSUAL
-- ============================================================================
PROMPT ===== P8.1 Definicion y ultimo refresco =====
SELECT mview_name, refresh_mode, refresh_method, build_mode, last_refresh_type,
       TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

SELECT COUNT(*) AS filas, MIN(anio * 100 + mes) AS primer_mes, MAX(anio * 100 + mes) AS ultimo_mes
FROM   MV_OCUPACION_MENSUAL;

PROMPT ===== P8.2 Ocupacion 2025 por municipio (se lee de la vista, sin recalcular) =====
SELECT municipio,
       SUM(noches_vendidas)    AS noches_vendidas,
       SUM(noches_disponibles) AS noches_disponibles,
       ROUND(100 * SUM(noches_vendidas) / SUM(noches_disponibles), 2) AS pct_ocupacion
FROM   MV_OCUPACION_MENSUAL
WHERE  anio = 2025
GROUP BY municipio
ORDER BY pct_ocupacion DESC;

PROMPT ===== P8.3 Ocupacion mensual 2025 (estacionalidad) =====
SELECT mes, SUM(noches_vendidas) AS noches_vendidas,
       ROUND(100 * SUM(noches_vendidas) / SUM(noches_disponibles), 2) AS pct_ocupacion
FROM   MV_OCUPACION_MENSUAL
WHERE  anio = 2025
GROUP BY mes
ORDER BY mes;

PROMPT ===== P8.4 La vista es correcta: comparada contra el calculo en vivo de 2025 (diferencias = 0) =====
SELECT COUNT(*) AS meses_comparados,
       SUM(CASE WHEN mv.noches <> vivo.noches THEN 1 ELSE 0 END) AS diferencias
FROM  (SELECT mes, SUM(noches_vendidas) AS noches
       FROM   MV_OCUPACION_MENSUAL WHERE anio = 2025 GROUP BY mes) mv
JOIN  (SELECT c.mes, COUNT(*) AS noches
       FROM   RESERVA_HABITACION rh
       JOIN   RESERVA r    ON r.reserva_id = rh.reserva_id
       JOIN   CALENDARIO c ON c.fecha >= rh.fecha_checkin AND c.fecha < rh.fecha_checkout
       WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA') AND c.anio = 2025
       GROUP BY c.mes) vivo ON vivo.mes = mv.mes;

PROMPT ===== P8.5 Politica ON DEMAND: la reserva confirmada de P2 aun NO aparece en la vista =====
SELECT (SELECT noches_vendidas FROM MV_OCUPACION_MENSUAL
        WHERE alojamiento_id = :aloj_libre AND anio = 2026 AND mes = 11) AS noches_en_vista,
       (SELECT COUNT(*)
        FROM   RESERVA_HABITACION rh
        JOIN   RESERVA r    ON r.reserva_id = rh.reserva_id
        JOIN   HABITACION h ON h.habitacion_id = rh.habitacion_id
        JOIN   CALENDARIO c ON c.fecha >= rh.fecha_checkin AND c.fecha < rh.fecha_checkout
        WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
        AND    h.alojamiento_id = :aloj_libre AND c.anio = 2026 AND c.mes = 11) AS noches_en_vivo
FROM dual;

PROMPT ===== P8.6 Refresco manual (el mismo que ejecuta el job cada noche) =====
EXEC DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C');

SELECT (SELECT noches_vendidas FROM MV_OCUPACION_MENSUAL
        WHERE alojamiento_id = :aloj_libre AND anio = 2026 AND mes = 11) AS noches_en_vista_despues,
       TO_CHAR((SELECT last_refresh_date FROM user_mviews WHERE mview_name = 'MV_OCUPACION_MENSUAL'),
               'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM dual;

PROMPT ===== P8.7 Job de refresco nocturno =====
SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'DD/MM/YYYY HH24:MI') AS proxima_ejecucion
FROM   user_scheduler_jobs
WHERE  job_name = 'JOB_REFRESCO_MV_OCUPACION';

PROMPT ===== FIN DE LAS PRUEBAS =====
SET ECHO OFF;
SPOOL OFF

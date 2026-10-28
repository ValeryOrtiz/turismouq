-- ============================================================================
-- TurismoUQ - 02_datos.sql
-- Carga de datos con PL/SQL y DBMS_RANDOM (volumen minimo y datos asimetricos)
-- Ejecutar despues de 01_ddl.sql, como script completo (F5 en SQL Developer).
-- Tiempo aproximado: 2 a 5 minutos.
-- ----------------------------------------------------------------------------
-- CORRECCIONES FRENTE A LA ENTREGA 1 (observaciones de la docente):
--   1. TEMPORADA cubre TODOS los dias de 2024, 2025, 2026 y 2027, sin huecos
--      ni cruces (10 temporadas por anio = 40). Antes 2024 no tenia temporadas
--      y quedaban 371 dias de 2025-2026 sin temporada. 2027 se incluye porque
--      hay estadias de finales de 2026 que terminan en enero de 2027 y porque
--      la plataforma vende reservas a futuro.
--   2. RESERVA_SERVICIO supera las 40.000 filas: cada alojamiento ofrece
--      entre 0 y 8 servicios (segun su tipo) y no solo uno.
--   3. PAGO.monto ya no es aleatorio: es el valor de la estadia calculado
--      noche por noche contra TARIFA (la misma regla de fn_valor_estadia)
--      mas los servicios contratados (precio x cantidad).
--   4. Cero solapes: antes de asignar una habitacion se revisa, dia por dia,
--      que no este ocupada por otra reserva en ese rango.
--   5. RESERVA_HABITACION.num_huespedes se llena respetando la capacidad.
-- ============================================================================

SET DEFINE OFF;
SET SERVEROUTPUT ON SIZE UNLIMITED;

-- Semilla fija: los datos son reproducibles entre integrantes del equipo
EXEC DBMS_RANDOM.SEED(20261022);

-- ---------- Reset seguro (idempotente) ----------
DELETE FROM USUARIO_ALOJAMIENTO;
DELETE FROM USUARIO_SISTEMA;
DELETE FROM RESENA;
DELETE FROM RESERVA_SERVICIO;
DELETE FROM SERVICIO;
DELETE FROM PAGO;
DELETE FROM RESERVA_HABITACION;
DELETE FROM RESERVA;
DELETE FROM CLIENTE;
DELETE FROM TARIFA;
DELETE FROM HABITACION;
DELETE FROM ALOJAMIENTO;
DELETE FROM TEMPORADA;
DELETE FROM ROL;
DELETE FROM TIPO_ALOJAMIENTO;
DELETE FROM MUNICIPIO;
COMMIT;

-- ============================================================================
-- 1. Catalogos
-- ============================================================================
INSERT INTO MUNICIPIO (nombre) VALUES ('Armenia');
INSERT INTO MUNICIPIO (nombre) VALUES ('Calarca');
INSERT INTO MUNICIPIO (nombre) VALUES ('Montenegro');
INSERT INTO MUNICIPIO (nombre) VALUES ('Quimbaya');
INSERT INTO MUNICIPIO (nombre) VALUES ('La Tebaida');
INSERT INTO MUNICIPIO (nombre) VALUES ('Circasia');
INSERT INTO MUNICIPIO (nombre) VALUES ('Filandia');
INSERT INTO MUNICIPIO (nombre) VALUES ('Salento');
INSERT INTO MUNICIPIO (nombre) VALUES ('Genova');
INSERT INTO MUNICIPIO (nombre) VALUES ('Pijao');
INSERT INTO MUNICIPIO (nombre) VALUES ('Buenavista');
INSERT INTO MUNICIPIO (nombre) VALUES ('Cordoba');

INSERT INTO TIPO_ALOJAMIENTO (nombre) VALUES ('FINCA_CAFETERA');
INSERT INTO TIPO_ALOJAMIENTO (nombre) VALUES ('HOTEL');
INSERT INTO TIPO_ALOJAMIENTO (nombre) VALUES ('GLAMPING');
INSERT INTO TIPO_ALOJAMIENTO (nombre) VALUES ('HOSTAL');

INSERT INTO ROL (nombre) VALUES ('ADMINISTRADOR');
INSERT INTO ROL (nombre) VALUES ('ENCARGADO_ALOJAMIENTO');
COMMIT;

-- ============================================================================
-- 2. TEMPORADA: 10 temporadas por anio, 2024-2027, cubriendo cada dia.
--    Calendario de cada anio (Semana Santa = Domingo de Ramos a Domingo de
--    Resurreccion, cambia cada anio):
--      01-01..01-12  Inicio de ano         ALTA   (vacaciones y Reyes)
--      01-13..01-31  Temporada baja I      BAJA
--      02-01..Ramos-1 Temporada media I    MEDIA
--      Ramos..Pascua Semana Santa          ALTA
--      Pascua+1..06-14 Temporada baja II   BAJA
--      06-15..07-20  Mitad de ano          ALTA
--      07-21..08-14  Temporada media II    MEDIA
--      08-15..09-30  Temporada baja III    BAJA
--      10-01..11-30  Temporada media III   MEDIA  (receso de octubre)
--      12-01..12-31  Fin de ano            ALTA
-- ============================================================================
DECLARE
    TYPE t_fechas IS TABLE OF DATE INDEX BY PLS_INTEGER;
    l_ramos t_fechas;

    FUNCTION f(p_anio NUMBER, p_mmdd VARCHAR2) RETURN DATE IS
    BEGIN
        RETURN TO_DATE(p_anio || '-' || p_mmdd, 'YYYY-MM-DD');
    END;

    PROCEDURE ins(p_nombre VARCHAR2, p_cat VARCHAR2, p_anio NUMBER,
                  p_ini DATE, p_fin DATE) IS
    BEGIN
        INSERT INTO TEMPORADA (nombre, categoria, anio, fecha_inicio, fecha_fin)
        VALUES (p_nombre, p_cat, p_anio, p_ini, p_fin);
    END;
BEGIN
    l_ramos(2024) := DATE '2024-03-24';   -- Pascua 31-mar-2024
    l_ramos(2025) := DATE '2025-04-13';   -- Pascua 20-abr-2025
    l_ramos(2026) := DATE '2026-03-29';   -- Pascua 05-abr-2026
    l_ramos(2027) := DATE '2027-03-21';   -- Pascua 28-mar-2027

    FOR y IN 2024 .. 2027 LOOP
        ins('Inicio de ano',       'ALTA',  y, f(y,'01-01'),     f(y,'01-12'));
        ins('Temporada baja I',    'BAJA',  y, f(y,'01-13'),     f(y,'01-31'));
        ins('Temporada media I',   'MEDIA', y, f(y,'02-01'),     l_ramos(y) - 1);
        ins('Semana Santa',        'ALTA',  y, l_ramos(y),       l_ramos(y) + 7);
        ins('Temporada baja II',   'BAJA',  y, l_ramos(y) + 8,   f(y,'06-14'));
        ins('Mitad de ano',        'ALTA',  y, f(y,'06-15'),     f(y,'07-20'));
        ins('Temporada media II',  'MEDIA', y, f(y,'07-21'),     f(y,'08-14'));
        ins('Temporada baja III',  'BAJA',  y, f(y,'08-15'),     f(y,'09-30'));
        ins('Temporada media III', 'MEDIA', y, f(y,'10-01'),     f(y,'11-30'));
        ins('Fin de ano',          'ALTA',  y, f(y,'12-01'),     f(y,'12-31'));
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('TEMPORADA generada: 40 temporadas (2024-2027).');
END;
/

-- Verificacion inmediata: dias sin temporada y dias con mas de una (ambos deben ser 0)
SELECT SUM(CASE WHEN n = 0 THEN 1 ELSE 0 END) AS dias_sin_temporada,
       SUM(CASE WHEN n > 1 THEN 1 ELSE 0 END) AS dias_con_cruce
FROM (
    SELECT d.dia, COUNT(t.temporada_id) AS n
    FROM  (SELECT DATE '2024-01-01' + LEVEL - 1 AS dia FROM dual
           CONNECT BY LEVEL <= DATE '2027-12-31' - DATE '2024-01-01' + 1) d
    LEFT JOIN TEMPORADA t ON d.dia BETWEEN t.fecha_inicio AND t.fecha_fin
    GROUP BY d.dia
);

-- ============================================================================
-- 3. ALOJAMIENTO (60) + HABITACION (>=400, ASIMETRICO)
--    - Cada municipio recibe un peso distinto (Armenia y Salento concentran
--      mas oferta que Buenavista o Cordoba).
--    - Cada municipio tiene un tipo dominante (70 % de sus alojamientos).
--    - Habitaciones segun el tipo: hoteles 20-40, hostales 8-15,
--      glampings 4-10, fincas cafeteras 3-8.
-- ============================================================================
DECLARE
    TYPE t_str IS TABLE OF VARCHAR2(60);
    TYPE t_num IS TABLE OF NUMBER;

    l_municipios t_str := t_str('Armenia','Calarca','Montenegro','Quimbaya',
                                 'La Tebaida','Circasia','Filandia','Salento',
                                 'Genova','Pijao','Buenavista','Cordoba');
    l_pesos      t_num := t_num(14,6,5,4,3,4,6,12,2,2,1,1); -- suma = 60
    l_perfil     t_str := t_str('HOTEL','HOTEL','FINCA_CAFETERA','GLAMPING',
                                 'HOTEL','FINCA_CAFETERA','GLAMPING','GLAMPING',
                                 'FINCA_CAFETERA','FINCA_CAFETERA','FINCA_CAFETERA',
                                 'FINCA_CAFETERA');
    l_tipos      t_str := t_str('FINCA_CAFETERA','HOTEL','GLAMPING','HOSTAL');
    l_adjetivos  t_str := t_str('Real','Andino','Cafetero','Colonial','del Valle',
                                 'Mirador','Bosque Verde','Rio Claro','Paraiso',
                                 'Sol Naciente','Los Yarumos','La Montana');

    l_municipio_id NUMBER;
    l_tipo_id      NUMBER;
    l_aloj_id      NUMBER;
    v_tipo_txt     VARCHAR2(30);
    v_num_hab      NUMBER;
    v_hab_tipo     VARCHAR2(15);
    v_capacidad    NUMBER;
    v_rand         NUMBER;
    v_estrellas    NUMBER;
    v_nombre_comercial VARCHAR2(200);
    v_direccion    VARCHAR2(250);
    v_telefono     VARCHAR2(30);
    contador       NUMBER := 0;
BEGIN
    FOR m IN 1..l_municipios.COUNT LOOP
        SELECT municipio_id INTO l_municipio_id
          FROM MUNICIPIO WHERE nombre = l_municipios(m);

        FOR a IN 1..l_pesos(m) LOOP
            contador := contador + 1;

            IF DBMS_RANDOM.VALUE < 0.7 THEN
                v_tipo_txt := l_perfil(m);
            ELSE
                v_tipo_txt := l_tipos(TRUNC(DBMS_RANDOM.VALUE(1, l_tipos.COUNT + 1)));
            END IF;
            SELECT tipo_alojamiento_id INTO l_tipo_id
              FROM TIPO_ALOJAMIENTO WHERE nombre = v_tipo_txt;

            v_estrellas := LEAST(5, GREATEST(1, ROUND(DBMS_RANDOM.NORMAL * 0.8 + 4)));

            v_nombre_comercial := INITCAP(REPLACE(v_tipo_txt,'_',' ')) || ' ' ||
                        l_adjetivos(TRUNC(DBMS_RANDOM.VALUE(1, l_adjetivos.COUNT + 1))) ||
                        ' ' || l_municipios(m) || ' ' || TO_CHAR(contador);
            v_direccion := 'Km ' || TRUNC(DBMS_RANDOM.VALUE(1,20)) || ' via ' ||
                        l_municipios(m) || ', vereda ' ||
                        TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(1,15)));
            v_telefono := '+57 3' || TRUNC(DBMS_RANDOM.VALUE(100000000,999999999));

            INSERT INTO ALOJAMIENTO (municipio_id, tipo_alojamiento_id,
                        nombre_comercial, direccion, calificacion_estrellas,
                        telefono, correo)
            VALUES (l_municipio_id, l_tipo_id, v_nombre_comercial, v_direccion,
                    v_estrellas, v_telefono, 'contacto' || contador || '@turismouq.co')
            RETURNING alojamiento_id INTO l_aloj_id;

            v_num_hab := CASE v_tipo_txt
                           WHEN 'HOTEL'    THEN ROUND(DBMS_RANDOM.VALUE(20,40))
                           WHEN 'HOSTAL'   THEN ROUND(DBMS_RANDOM.VALUE(8,15))
                           WHEN 'GLAMPING' THEN ROUND(DBMS_RANDOM.VALUE(4,10))
                           ELSE                 ROUND(DBMS_RANDOM.VALUE(3,8))
                         END;

            FOR h IN 1..v_num_hab LOOP
                v_rand := DBMS_RANDOM.VALUE;
                v_hab_tipo := CASE WHEN v_rand < 0.25 THEN 'SENCILLA'
                                   WHEN v_rand < 0.75 THEN 'DOBLE'
                                   WHEN v_rand < 0.90 THEN 'SUITE'
                                   ELSE 'CABANA' END;
                v_capacidad := CASE v_hab_tipo
                                 WHEN 'SENCILLA' THEN ROUND(DBMS_RANDOM.VALUE(1,2))
                                 WHEN 'DOBLE'    THEN ROUND(DBMS_RANDOM.VALUE(2,4))
                                 WHEN 'SUITE'    THEN ROUND(DBMS_RANDOM.VALUE(2,6))
                                 ELSE                 ROUND(DBMS_RANDOM.VALUE(2,8))
                               END;

                INSERT INTO HABITACION (alojamiento_id, numero, capacidad_maxima,
                            tipo_habitacion, descripcion)
                VALUES (l_aloj_id, TO_CHAR(100 + h), v_capacidad, v_hab_tipo,
                        'Habitacion tipo ' || v_hab_tipo || ' en ' || l_municipios(m));
            END LOOP;
        END LOOP;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ALOJAMIENTO/HABITACION generados.');
END;
/

-- ============================================================================
-- 4. TARIFA = cruce HABITACION x TEMPORADA (una fila por combinacion)
--    Precio base por tipo de habitacion x factor de temporada. El factor de
--    temporada ALTA es distinto por alojamiento (algunos suben poco para
--    competir por volumen).
-- ============================================================================
DECLARE
    TYPE t_hab IS TABLE OF HABITACION%ROWTYPE;
    l_hab t_hab;
    l_base NUMBER;
    l_factor NUMBER;
    l_factor_alta NUMBER;
    l_ultimo_aloj NUMBER := -1;
BEGIN
    SELECT * BULK COLLECT INTO l_hab FROM HABITACION ORDER BY alojamiento_id;

    FOR i IN 1..l_hab.COUNT LOOP
        IF l_hab(i).alojamiento_id != l_ultimo_aloj THEN
            l_factor_alta := DBMS_RANDOM.VALUE(1.05, 1.5);
            l_ultimo_aloj := l_hab(i).alojamiento_id;
        END IF;

        l_base := CASE l_hab(i).tipo_habitacion
                    WHEN 'SENCILLA' THEN ROUND(DBMS_RANDOM.VALUE(70000,100000), -3)
                    WHEN 'DOBLE'    THEN ROUND(DBMS_RANDOM.VALUE(110000,160000), -3)
                    WHEN 'SUITE'    THEN ROUND(DBMS_RANDOM.VALUE(200000,300000), -3)
                    ELSE                 ROUND(DBMS_RANDOM.VALUE(160000,240000), -3)
                  END;

        FOR t IN (SELECT temporada_id, categoria FROM TEMPORADA) LOOP
            l_factor := CASE t.categoria
                          WHEN 'ALTA'  THEN l_factor_alta
                          WHEN 'MEDIA' THEN DBMS_RANDOM.VALUE(0.95,1.15)
                          ELSE              DBMS_RANDOM.VALUE(0.75,0.95)
                        END;
            INSERT INTO TARIFA (habitacion_id, temporada_id, precio_noche)
            VALUES (l_hab(i).habitacion_id, t.temporada_id, ROUND(l_base * l_factor, -3));
        END LOOP;

        IF MOD(i,50) = 0 THEN COMMIT; END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('TARIFA generada: ' || l_hab.COUNT || ' habitaciones x 40 temporadas.');
END;
/

-- ============================================================================
-- 5. CLIENTE (3.000) - ciudades variadas, correo unico
-- ============================================================================
DECLARE
    TYPE t_str IS TABLE OF VARCHAR2(40);
    l_nombres   t_str := t_str('Andres','Maria','Carlos','Laura','Juan','Camila',
                                'Santiago','Valentina','Felipe','Daniela','Diego',
                                'Paola','Julian','Natalia','Sebastian','Mariana',
                                'Alejandro','Isabella','Nicolas','Gabriela');
    l_apellidos t_str := t_str('Gomez','Rodriguez','Martinez','Lopez','Garcia',
                                'Hernandez','Perez','Sanchez','Ramirez','Torres',
                                'Florez','Vargas','Castro','Ortiz','Rojas','Mejia',
                                'Cardona','Restrepo','Zapata','Londono');
    l_ciudades  t_str := t_str('Armenia','Pereira','Manizales','Bogota','Medellin',
                                'Cali','Barranquilla','Cartagena','Bucaramanga',
                                'Ibague','Neiva','Cucuta','Miami','Madrid',
                                'Ciudad de Mexico');
    v_nombre_cliente   VARCHAR2(150);
    v_telefono_cliente VARCHAR2(30);
    v_ciudad_cliente   VARCHAR2(100);
BEGIN
    FOR i IN 1..3000 LOOP
        v_nombre_cliente := l_nombres(TRUNC(DBMS_RANDOM.VALUE(1,l_nombres.COUNT+1))) || ' ' ||
                            l_apellidos(TRUNC(DBMS_RANDOM.VALUE(1,l_apellidos.COUNT+1)));
        v_telefono_cliente := '+57 3' || TRUNC(DBMS_RANDOM.VALUE(100000000,999999999));
        v_ciudad_cliente := l_ciudades(TRUNC(DBMS_RANDOM.VALUE(1,l_ciudades.COUNT+1)));

        INSERT INTO CLIENTE (nombre, documento_identidad, correo, telefono, ciudad_origen)
        VALUES (v_nombre_cliente, TO_CHAR(100000000 + i), 'cliente' || i || '@correo.com',
                v_telefono_cliente, v_ciudad_cliente);
        IF MOD(i,500) = 0 THEN COMMIT; END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CLIENTE generado: 3000.');
END;
/

-- ============================================================================
-- 6. SERVICIO: cada alojamiento ofrece varios servicios propios, en cantidad
--    asimetrica segun su tipo (hoteles 4-8, glampings 3-6, hostales 1-3,
--    fincas 0-4). Resultado: alrededor de 200 servicios (minimo exigido: 30).
-- ============================================================================
DECLARE
    TYPE t_str IS TABLE OF VARCHAR2(60);
    TYPE t_num IS TABLE OF NUMBER;
    l_servicios t_str := t_str('Desayuno incluido','Tour guiado cafetero',
                                'Transporte al aeropuerto','Alquiler de bicicletas',
                                'Spa y masajes','Parqueadero privado','Piscina',
                                'Cabalgata','Zona de BBQ','Wifi premium');
    l_pmin t_num := t_num(15000,60000,50000,25000,90000,10000,20000,70000,30000,8000);
    l_pmax t_num := t_num(35000,120000,90000,50000,180000,25000,40000,130000,60000,15000);
    v_num    NUMBER;
    v_inicio NUMBER;
    v_idx    NUMBER;
    v_precio NUMBER;
    v_total  NUMBER := 0;
BEGIN
    FOR a IN (SELECT al.alojamiento_id, ta.nombre AS tipo
                FROM ALOJAMIENTO al
                JOIN TIPO_ALOJAMIENTO ta ON ta.tipo_alojamiento_id = al.tipo_alojamiento_id
               ORDER BY al.alojamiento_id) LOOP
        v_num := CASE a.tipo
                   WHEN 'HOTEL'    THEN ROUND(DBMS_RANDOM.VALUE(4,8))
                   WHEN 'GLAMPING' THEN ROUND(DBMS_RANDOM.VALUE(3,6))
                   WHEN 'HOSTAL'   THEN ROUND(DBMS_RANDOM.VALUE(1,3))
                   ELSE                 ROUND(DBMS_RANDOM.VALUE(0,4))
                 END;
        -- nombres distintos dentro del mismo alojamiento (UNIQUE alojamiento+nombre)
        v_inicio := TRUNC(DBMS_RANDOM.VALUE(1, l_servicios.COUNT + 1));
        FOR k IN 0 .. v_num - 1 LOOP
            v_idx    := MOD(v_inicio - 1 + k, l_servicios.COUNT) + 1;
            v_precio := ROUND(DBMS_RANDOM.VALUE(l_pmin(v_idx), l_pmax(v_idx)), -3);
            INSERT INTO SERVICIO (alojamiento_id, nombre, descripcion, precio)
            VALUES (a.alojamiento_id, l_servicios(v_idx),
                    'Servicio complementario ofrecido por el alojamiento', v_precio);
            v_total := v_total + 1;
        END LOOP;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICIO generado: ' || v_total);
END;
/

-- ============================================================================
-- 7. USUARIO_SISTEMA (10) + USUARIO_ALOJAMIENTO
--    2 administradores + 2 encargados por cada tipo de alojamiento.
-- ============================================================================
DECLARE
    l_admin_rol  NUMBER;
    l_enc_rol    NUMBER;
    l_user_id    NUMBER;
    l_n_aloj     NUMBER;
    v_clave_hash VARCHAR2(255);
BEGIN
    SELECT rol_id INTO l_admin_rol FROM ROL WHERE nombre = 'ADMINISTRADOR';
    SELECT rol_id INTO l_enc_rol   FROM ROL WHERE nombre = 'ENCARGADO_ALOJAMIENTO';

    FOR i IN 1..2 LOOP
        SELECT RAWTOHEX(STANDARD_HASH('clave_admin' || i, 'SHA256')) INTO v_clave_hash FROM dual;
        INSERT INTO USUARIO_SISTEMA (rol_id, nombre, correo, clave_hash)
        VALUES (l_admin_rol, 'Administrador ' || i, 'admin' || i || '@turismouq.co', v_clave_hash);
    END LOOP;

    FOR t IN (SELECT tipo_alojamiento_id, nombre FROM TIPO_ALOJAMIENTO) LOOP
        FOR k IN 1..2 LOOP
            SELECT RAWTOHEX(STANDARD_HASH('clave' || t.tipo_alojamiento_id || k, 'SHA256'))
              INTO v_clave_hash FROM dual;
            INSERT INTO USUARIO_SISTEMA (rol_id, nombre, correo, clave_hash)
            VALUES (l_enc_rol, 'Encargado ' || t.nombre || ' ' || k,
                    'encargado.' || LOWER(t.nombre) || k || '@turismouq.co', v_clave_hash)
            RETURNING usuario_id INTO l_user_id;

            l_n_aloj := TRUNC(DBMS_RANDOM.VALUE(1,3));
            FOR a IN (SELECT alojamiento_id FROM ALOJAMIENTO
                       WHERE tipo_alojamiento_id = t.tipo_alojamiento_id
                       ORDER BY DBMS_RANDOM.VALUE
                       FETCH FIRST l_n_aloj ROWS ONLY) LOOP
                INSERT INTO USUARIO_ALOJAMIENTO (usuario_id, alojamiento_id)
                VALUES (l_user_id, a.alojamiento_id);
            END LOOP;
        END LOOP;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('USUARIO_SISTEMA generado: 10.');
END;
/

-- ============================================================================
-- 8. RESERVA + RESERVA_HABITACION + RESERVA_SERVICIO + PAGO + RESENA
--    25.000 reservas 2024-2026 con estacionalidad real.
--    Orden por reserva: (a) fechas, (b) habitaciones LIBRES del mismo
--    alojamiento, (c) servicios, (d) pagos = valor TARIFA + servicios.
-- ============================================================================
DECLARE
    TYPE t_num     IS TABLE OF NUMBER;
    TYPE t_numlist IS TABLE OF NUMBER;
    TYPE t_map     IS TABLE OF t_numlist INDEX BY PLS_INTEGER;
    TYPE t_num_ix  IS TABLE OF NUMBER  INDEX BY PLS_INTEGER;
    TYPE t_date_ix IS TABLE OF DATE    INDEX BY PLS_INTEGER;
    TYPE t_bool_ix IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;

    c_base     CONSTANT DATE   := DATE '2024-01-01';
    c_factor   CONSTANT NUMBER := 2000;   -- clave ocupacion = hab*2000 + dia
    c_obj_serv CONSTANT NUMBER := 41000;  -- objetivo de lineas de servicio

    l_hab_id        t_num;
    l_hab_aloj      t_num;
    l_hab_cap_tmp   t_num;
    l_capacidad     t_num_ix;             -- capacidad por habitacion_id
    l_clientes      t_num;
    l_rooms_by_aloj t_map;
    l_serv_by_aloj  t_map;
    l_serv_precio   t_num_ix;             -- precio por servicio_id
    l_ocupado       t_bool_ix;            -- noches ya vendidas por habitacion

    -- habitaciones elegidas para la reserva en curso
    l_sel_hab  t_num_ix;
    l_sel_ci   t_date_ix;
    l_sel_co   t_date_ix;
    v_sel      PLS_INTEGER;

    TYPE t_completada IS RECORD (reserva_id NUMBER, cliente_id NUMBER,
                                 alojamiento_id NUMBER, fecha_out DATE);
    TYPE t_completadas IS TABLE OF t_completada;
    l_completadas t_completadas := t_completadas();

    v_reserva_id    NUMBER;
    v_cliente_id    NUMBER;
    v_anio          NUMBER;
    v_mes           NUMBER;
    v_dia           NUMBER;
    v_checkin       DATE;
    v_checkout      DATE;
    v_noches        NUMBER;
    v_fecha_reserva DATE;
    v_estado        VARCHAR2(15);
    v_r             NUMBER;
    v_anchor_idx    NUMBER;
    v_aloj_id       NUMBER;
    v_num_hab_res   NUMBER;
    v_n_rooms       NUMBER;
    v_start         NUMBER;
    v_idx           NUMBER;
    v_room_id       NUMBER;
    v_ci            DATE;
    v_co            DATE;
    v_intentos      NUMBER;
    v_valor_estadia NUMBER;
    v_valor_serv    NUMBER;
    v_valor_total   NUMBER;
    v_valor_linea   NUMBER;
    v_huespedes     NUMBER;
    v_num_pagos     NUMBER;
    v_anticipo      NUMBER;
    v_metodo        VARCHAR2(20);
    v_estado_pago   VARCHAR2(15);
    v_comentario    VARCHAR2(1000);
    v_num_serv      NUMBER;
    v_serv_ini      NUMBER;
    v_servicio_id   NUMBER;
    v_cantidad_serv NUMBER;
    v_lineas_serv   NUMBER := 0;

    FUNCTION f_metodo_aleatorio RETURN VARCHAR2 IS
        v NUMBER := TRUNC(DBMS_RANDOM.VALUE(1,6));
    BEGIN
        RETURN CASE v WHEN 1 THEN 'TARJETA_CREDITO'
                      WHEN 2 THEN 'TARJETA_DEBITO'
                      WHEN 3 THEN 'PSE'
                      WHEN 4 THEN 'TRANSFERENCIA'
                      ELSE 'EFECTIVO' END;
    END;

    -- TRUE si la habitacion no tiene ninguna noche vendida en [ci, co)
    FUNCTION f_libre(p_hab NUMBER, p_ci DATE, p_co DATE) RETURN BOOLEAN IS
    BEGIN
        FOR d IN 0 .. (p_co - p_ci - 1) LOOP
            IF l_ocupado.EXISTS(p_hab * c_factor + (p_ci - c_base) + d) THEN
                RETURN FALSE;
            END IF;
        END LOOP;
        RETURN TRUE;
    END;

    PROCEDURE p_ocupar(p_hab NUMBER, p_ci DATE, p_co DATE) IS
    BEGIN
        FOR d IN 0 .. (p_co - p_ci - 1) LOOP
            l_ocupado(p_hab * c_factor + (p_ci - c_base) + d) := TRUE;
        END LOOP;
    END;

    -- Valor de una linea contra TARIFA: cada temporada que toca la estadia
    -- aporta (noches dentro de esa temporada) x (precio de esa temporada).
    -- Es la misma regla noche a noche de pkg_turismo.fn_valor_estadia; el
    -- script 07 verifica que ambos calculos coinciden.
    FUNCTION f_valor_linea(p_hab NUMBER, p_ci DATE, p_co DATE) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT NVL(SUM((LEAST(t.fecha_fin + 1, p_co) - GREATEST(t.fecha_inicio, p_ci))
                       * ta.precio_noche), 0)
          INTO v
          FROM TEMPORADA t
          JOIN TARIFA ta ON ta.temporada_id = t.temporada_id
         WHERE ta.habitacion_id = p_hab
           AND t.fecha_inicio < p_co
           AND t.fecha_fin   >= p_ci;
        RETURN v;
    END;
BEGIN
    SELECT cliente_id BULK COLLECT INTO l_clientes FROM CLIENTE;

    SELECT habitacion_id, alojamiento_id, capacidad_maxima
      BULK COLLECT INTO l_hab_id, l_hab_aloj, l_hab_cap_tmp
      FROM HABITACION;

    FOR i IN 1..l_hab_id.COUNT LOOP
        l_capacidad(l_hab_id(i)) := l_hab_cap_tmp(i);
        IF NOT l_rooms_by_aloj.EXISTS(l_hab_aloj(i)) THEN
            l_rooms_by_aloj(l_hab_aloj(i)) := t_numlist();
        END IF;
        l_rooms_by_aloj(l_hab_aloj(i)).EXTEND;
        l_rooms_by_aloj(l_hab_aloj(i))(l_rooms_by_aloj(l_hab_aloj(i)).COUNT) := l_hab_id(i);
    END LOOP;

    FOR s IN (SELECT servicio_id, alojamiento_id, precio FROM SERVICIO) LOOP
        l_serv_precio(s.servicio_id) := s.precio;
        IF NOT l_serv_by_aloj.EXISTS(s.alojamiento_id) THEN
            l_serv_by_aloj(s.alojamiento_id) := t_numlist();
        END IF;
        l_serv_by_aloj(s.alojamiento_id).EXTEND;
        l_serv_by_aloj(s.alojamiento_id)(l_serv_by_aloj(s.alojamiento_id).COUNT) := s.servicio_id;
    END LOOP;

    FOR n IN 1..25000 LOOP
        -- ---------- (a)+(b) fechas y habitaciones libres ----------
        v_sel := 0;
        v_intentos := 0;
        WHILE v_sel = 0 LOOP
            -- cada 10 intentos fallidos se cambia la fecha
            IF MOD(v_intentos, 10) = 0 THEN
                -- anio: 25 % 2024, 45 % 2025, 30 % 2026
                v_r := DBMS_RANDOM.VALUE;
                v_anio := CASE WHEN v_r < 0.25 THEN 2024
                               WHEN v_r < 0.70 THEN 2025
                               ELSE 2026 END;
                -- mes: E13 F5 M6 A9 M5 J10 J10 A5 S5 O6 N5 D14 (suma = 93)
                v_r := DBMS_RANDOM.VALUE(0,93);
                v_mes := CASE WHEN v_r < 13 THEN 1  WHEN v_r < 18 THEN 2
                              WHEN v_r < 24 THEN 3  WHEN v_r < 33 THEN 4
                              WHEN v_r < 38 THEN 5  WHEN v_r < 48 THEN 6
                              WHEN v_r < 58 THEN 7  WHEN v_r < 63 THEN 8
                              WHEN v_r < 68 THEN 9  WHEN v_r < 74 THEN 10
                              WHEN v_r < 79 THEN 11 ELSE 12 END;
                v_dia := TRUNC(DBMS_RANDOM.VALUE(1,
                           TO_NUMBER(TO_CHAR(LAST_DAY(
                             TO_DATE(v_anio || '-' || v_mes || '-01','YYYY-MM-DD')),'DD')) + 1));
                v_checkin := TO_DATE(v_anio || '-' || v_mes || '-01','YYYY-MM-DD') + (v_dia - 1);
                -- mayoria 1-4 noches, ocasionalmente estadias largas
                v_noches := TRUNC(DBMS_RANDOM.VALUE(1,5)) +
                            CASE WHEN DBMS_RANDOM.VALUE < 0.15
                                 THEN TRUNC(DBMS_RANDOM.VALUE(3,10)) ELSE 0 END;
                v_checkout := v_checkin + v_noches;
            END IF;
            v_intentos := v_intentos + 1;

            -- habitacion ancla al azar (ponderado por tamano del alojamiento)
            v_anchor_idx := TRUNC(DBMS_RANDOM.VALUE(1, l_hab_id.COUNT + 1));
            v_aloj_id := l_hab_aloj(v_anchor_idx);
            v_n_rooms := l_rooms_by_aloj(v_aloj_id).COUNT;

            v_r := DBMS_RANDOM.VALUE;
            v_num_hab_res := LEAST(CASE WHEN v_r < 0.85 THEN 1
                                        WHEN v_r < 0.95 THEN 2
                                        ELSE 3 END, v_n_rooms);

            l_sel_hab.DELETE; l_sel_ci.DELETE; l_sel_co.DELETE;
            v_start := TRUNC(DBMS_RANDOM.VALUE(1, v_n_rooms + 1));
            FOR k IN 0 .. v_n_rooms - 1 LOOP
                v_idx := MOD(v_start - 1 + k, v_n_rooms) + 1;
                v_room_id := l_rooms_by_aloj(v_aloj_id)(v_idx);
                v_ci := v_checkin;
                v_co := v_checkout;
                -- a partir de la segunda habitacion, alguien puede llegar un dia despues
                IF v_sel > 0 AND v_noches > 1 AND DBMS_RANDOM.VALUE < 0.2 THEN
                    v_ci := v_checkin + 1;
                END IF;
                IF f_libre(v_room_id, v_ci, v_co) THEN
                    v_sel := v_sel + 1;
                    l_sel_hab(v_sel) := v_room_id;
                    l_sel_ci(v_sel)  := v_ci;
                    l_sel_co(v_sel)  := v_co;
                END IF;
                EXIT WHEN v_sel = v_num_hab_res;
            END LOOP;
        END LOOP;

        v_fecha_reserva := v_checkin - TRUNC(DBMS_RANDOM.VALUE(1,61));

        -- ---------- estado segun si ya paso o no la estadia ----------
        IF v_checkout < SYSDATE THEN
            v_estado := CASE WHEN DBMS_RANDOM.VALUE < 0.78 THEN 'COMPLETADA' ELSE 'CANCELADA' END;
        ELSE
            v_r := DBMS_RANDOM.VALUE;
            v_estado := CASE WHEN v_r < 0.5 THEN 'CONFIRMADA'
                             WHEN v_r < 0.9 THEN 'PENDIENTE'
                             ELSE 'CANCELADA' END;
        END IF;

        v_cliente_id := l_clientes(TRUNC(DBMS_RANDOM.VALUE(1, l_clientes.COUNT + 1)));

        INSERT INTO RESERVA (cliente_id, fecha_checkin, fecha_checkout, fecha_reserva, estado)
        VALUES (v_cliente_id, v_checkin, v_checkout, v_fecha_reserva, v_estado)
        RETURNING reserva_id INTO v_reserva_id;

        v_valor_estadia := 0;
        FOR k IN 1 .. v_sel LOOP
            v_huespedes := TRUNC(DBMS_RANDOM.VALUE(1, l_capacidad(l_sel_hab(k)) + 1));
            INSERT INTO RESERVA_HABITACION (reserva_id, habitacion_id, fecha_checkin,
                                            fecha_checkout, num_huespedes)
            VALUES (v_reserva_id, l_sel_hab(k), l_sel_ci(k), l_sel_co(k), v_huespedes);
            -- se marca ocupada incluso si la reserva queda CANCELADA: asi los
            -- datos no tienen ningun solape, sin importar el estado
            p_ocupar(l_sel_hab(k), l_sel_ci(k), l_sel_co(k));
            v_valor_linea := f_valor_linea(l_sel_hab(k), l_sel_ci(k), l_sel_co(k));
            v_valor_estadia := v_valor_estadia + v_valor_linea;
        END LOOP;

        -- ---------- (c) servicios (distintos, del mismo alojamiento) ----------
        v_valor_serv := 0;
        IF l_serv_by_aloj.EXISTS(v_aloj_id) THEN
            v_r := DBMS_RANDOM.VALUE;
            v_num_serv := CASE WHEN v_r < 0.08 THEN 0
                               WHEN v_r < 0.33 THEN 1
                               WHEN v_r < 0.68 THEN 2
                               WHEN v_r < 0.90 THEN 3
                               ELSE 4 END;
            -- si vamos por debajo del ritmo necesario para 40.000 lineas, una mas
            IF v_lineas_serv + (25000 - n + 1) * 1.7 < c_obj_serv THEN
                v_num_serv := v_num_serv + 1;
            END IF;
            v_num_serv := LEAST(v_num_serv, l_serv_by_aloj(v_aloj_id).COUNT);
            v_serv_ini := TRUNC(DBMS_RANDOM.VALUE(1, l_serv_by_aloj(v_aloj_id).COUNT + 1));
            FOR s IN 0 .. v_num_serv - 1 LOOP
                v_servicio_id := l_serv_by_aloj(v_aloj_id)(
                                   MOD(v_serv_ini - 1 + s, l_serv_by_aloj(v_aloj_id).COUNT) + 1);
                v_cantidad_serv := ROUND(DBMS_RANDOM.VALUE(1,4));
                INSERT INTO RESERVA_SERVICIO (reserva_id, servicio_id, cantidad)
                VALUES (v_reserva_id, v_servicio_id, v_cantidad_serv);
                v_valor_serv  := v_valor_serv + l_serv_precio(v_servicio_id) * v_cantidad_serv;
                v_lineas_serv := v_lineas_serv + 1;
            END LOOP;
        END IF;

        -- ---------- (d) pagos: el total sale de TARIFA + servicios ----------
        v_valor_total := v_valor_estadia + v_valor_serv;

        v_estado_pago := CASE v_estado
                            WHEN 'CANCELADA'  THEN CASE WHEN DBMS_RANDOM.VALUE < 0.5
                                                        THEN 'REEMBOLSADO' ELSE 'FALLIDO' END
                            WHEN 'COMPLETADA' THEN CASE WHEN DBMS_RANDOM.VALUE < 0.95
                                                        THEN 'EXITOSO' ELSE 'PENDIENTE' END
                            WHEN 'CONFIRMADA' THEN CASE WHEN DBMS_RANDOM.VALUE < 0.8
                                                        THEN 'EXITOSO' ELSE 'PENDIENTE' END
                            ELSE 'PENDIENTE'
                          END;

        IF v_estado = 'CANCELADA' THEN
            -- reserva cancelada: solo se alcanzo a pagar el anticipo (30-50 %)
            -- (las funciones locales no se pueden llamar dentro de un INSERT:
            --  el metodo se calcula antes en v_metodo)
            v_anticipo := ROUND(v_valor_total * (TRUNC(DBMS_RANDOM.VALUE(3,6)) / 10), -2);
            v_metodo   := f_metodo_aleatorio();
            INSERT INTO PAGO (reserva_id, fecha_pago, monto, metodo, estado)
            VALUES (v_reserva_id, v_fecha_reserva, v_anticipo, v_metodo, v_estado_pago);
        ELSE
            v_num_pagos := CASE WHEN DBMS_RANDOM.VALUE < 0.3 THEN 2 ELSE 1 END;
            IF v_num_pagos = 1 THEN
                v_metodo := f_metodo_aleatorio();
                INSERT INTO PAGO (reserva_id, fecha_pago, monto, metodo, estado)
                VALUES (v_reserva_id, v_fecha_reserva, v_valor_total, v_metodo, v_estado_pago);
            ELSE
                -- anticipo (30, 40 o 50 %) al reservar + saldo al llegar
                v_anticipo := ROUND(v_valor_total * (TRUNC(DBMS_RANDOM.VALUE(3,6)) / 10), -2);
                v_metodo   := f_metodo_aleatorio();
                INSERT INTO PAGO (reserva_id, fecha_pago, monto, metodo, estado)
                VALUES (v_reserva_id, v_fecha_reserva, v_anticipo, v_metodo, 'EXITOSO');
                v_metodo   := f_metodo_aleatorio();
                INSERT INTO PAGO (reserva_id, fecha_pago, monto, metodo, estado)
                VALUES (v_reserva_id, v_checkin, v_valor_total - v_anticipo, v_metodo, v_estado_pago);
            END IF;
        END IF;

        IF v_estado = 'COMPLETADA' THEN
            l_completadas.EXTEND;
            l_completadas(l_completadas.COUNT) :=
                t_completada(v_reserva_id, v_cliente_id, v_aloj_id, v_checkout);
        END IF;

        IF MOD(n,1000) = 0 THEN
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('Reservas generadas: ' || n);
        END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESERVA generada: 25000. Lineas de servicio: ' || v_lineas_serv ||
                         '. Completadas: ' || l_completadas.COUNT);

    -- ---------- RESENA: ~45 % de las reservas completadas ----------
    FOR i IN 1..l_completadas.COUNT LOOP
        IF DBMS_RANDOM.VALUE < 0.45 THEN
            v_r := DBMS_RANDOM.VALUE;
            v_comentario := CASE WHEN DBMS_RANDOM.VALUE < 0.6
                                 THEN 'Buena experiencia, volveria a hospedarme.'
                                 ELSE NULL END;
            INSERT INTO RESENA (cliente_id, alojamiento_id, reserva_id, calificacion, comentario, fecha)
            VALUES (l_completadas(i).cliente_id, l_completadas(i).alojamiento_id,
                    l_completadas(i).reserva_id,
                    CASE WHEN v_r < 0.35 THEN 5 WHEN v_r < 0.65 THEN 4
                         WHEN v_r < 0.85 THEN 3 WHEN v_r < 0.95 THEN 2
                         ELSE 1 END,
                    v_comentario, l_completadas(i).fecha_out + 1);
        END IF;
        IF MOD(i,2000) = 0 THEN COMMIT; END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESENA generada.');
END;
/

-- ============================================================================
-- 9. Verificaciones
-- ============================================================================
SELECT 'MUNICIPIO' tabla, COUNT(*) filas FROM MUNICIPIO
UNION ALL SELECT 'TIPO_ALOJAMIENTO', COUNT(*) FROM TIPO_ALOJAMIENTO
UNION ALL SELECT 'ROL', COUNT(*) FROM ROL
UNION ALL SELECT 'ALOJAMIENTO', COUNT(*) FROM ALOJAMIENTO
UNION ALL SELECT 'HABITACION', COUNT(*) FROM HABITACION
UNION ALL SELECT 'TEMPORADA', COUNT(*) FROM TEMPORADA
UNION ALL SELECT 'TARIFA', COUNT(*) FROM TARIFA
UNION ALL SELECT 'CLIENTE', COUNT(*) FROM CLIENTE
UNION ALL SELECT 'RESERVA', COUNT(*) FROM RESERVA
UNION ALL SELECT 'RESERVA_HABITACION', COUNT(*) FROM RESERVA_HABITACION
UNION ALL SELECT 'PAGO', COUNT(*) FROM PAGO
UNION ALL SELECT 'SERVICIO', COUNT(*) FROM SERVICIO
UNION ALL SELECT 'RESERVA_SERVICIO', COUNT(*) FROM RESERVA_SERVICIO
UNION ALL SELECT 'RESENA', COUNT(*) FROM RESENA
UNION ALL SELECT 'USUARIO_SISTEMA', COUNT(*) FROM USUARIO_SISTEMA
UNION ALL SELECT 'USUARIO_ALOJAMIENTO', COUNT(*) FROM USUARIO_ALOJAMIENTO;

-- Solapes de habitacion (debe dar 0)
SELECT COUNT(*) AS solapes_habitacion
FROM   RESERVA_HABITACION a
JOIN   RESERVA_HABITACION b
       ON  a.habitacion_id = b.habitacion_id
       AND a.reserva_habitacion_id < b.reserva_habitacion_id
       AND a.fecha_checkin  < b.fecha_checkout
       AND b.fecha_checkin  < a.fecha_checkout;

-- Reservas completadas con resena (debe ser >= 40 %)
SELECT ROUND(100 * COUNT(rs.resena_id) / COUNT(*), 1) AS pct_completadas_con_resena
FROM   RESERVA r
LEFT JOIN RESENA rs ON rs.reserva_id = r.reserva_id
WHERE  r.estado = 'COMPLETADA';

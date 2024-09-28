USE rac_ar;

CREATE VIEW v_informacion_cliente AS
-- acceso para equipo de Atencion al clientem permite atender consultas sobre los alquileres.
SELECT 
    c.id_cliente,
    c.nombre,
    c.apellido,
    c.documento,
    c.mail,
    a.id_alquiler,
    a.fecha_inicio,
    f.marca,
    f.modelo,
    h.kilometraje,
    h.estatus_devolucion
FROM cliente c
JOIN alquileres a ON c.id_cliente = a.id_cliente
JOIN flota_de_autos f ON a.id_auto = f.id_auto
LEFT JOIN historial h ON a.id_alquiler = h.id_alquiler;


CREATE VIEW v_revisiones_pendientes AS
-- acceso para equipo de ventas permite saber si un auto se encuentra en revision, o disponible. y sirve para el equipo tecnico, para saber cuales son los autos pendientes de revision.
SELECT 
    r.id_revision,
    f.marca,
    f.modelo,
    r.fecha_revision,
    r.descripcion_problema,
    r.resultado,
    t.nombre AS tecnico_asignado,
    t.especialidad
FROM revision r
JOIN flota_de_autos f ON r.id_auto = f.id_auto
JOIN tecnico_revision t ON r.id_tecnico = t.id_tecnico
WHERE r.resultado IS NULL;  -- Revisiones aún pendientes

-- FUNCIONES

DELIMITER $$
-- Funcion para calcular el valor real de un alquiler, cruzando la informacion de auto y tarifa

CREATE FUNCTION calcular_valor_alquiler(
    dias_alquiler INT,
    valor_unitario DECIMAL(10,2)
)
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    DECLARE valor_final DECIMAL(10,2);
    
    -- Calculamos el costo total del alquiler basado en la cantidad de días y la tarifa diaria
    SET valor_final = dias_alquiler * valor_unitario;

    -- Retornamos el valor final del alquiler
    RETURN valor_final;
END$$

DELIMITER ;

CREATE VIEW v_sucursales_ventas_rrhh AS
-- Vista que le permite a RRHH visualizar cual esel ingreso que tiene cada sucursal.
SELECT 
    s.id_sucursal,
    s.nombre_sucursal,
    COUNT(DISTINCT a.id_alquiler) AS total_alquileres,
    SUM(calcular_valor_alquiler(a.cantidad_dias, t.precio_diario)) AS ingresos_totales
FROM 
    sucursales s
JOIN 
    flota_de_autos f ON s.id_sucursal = f.id_sucursal
JOIN 
    alquileres a ON f.id_auto = a.id_auto
JOIN 
    pago p ON a.id_pago = p.id_pago
JOIN 
    tarifas t ON p.id_tarifa = t.id_tarifa
GROUP BY 
    s.id_sucursal, s.nombre_sucursal
ORDER BY 
    ingresos_totales DESC;
    
DELIMITER $$
-- funcion quem e permite calcular el promedio de ingresos por alquiler
CREATE FUNCTION promedio_ingresos_por_alquiler()
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    DECLARE promedio_ingresos DECIMAL(10,2);
    
    -- Calculamos el promedio de ingresos por alquiler considerando tarifas y adicionales.
    SELECT AVG(t.precio_diario * a.cantidad_dias + COALESCE(ad.costo_serv_adic, 0))
    INTO promedio_ingresos
    FROM alquileres a
    JOIN pago p ON a.id_pago = p.id_pago
    JOIN tarifas t ON p.id_tarifa = t.id_tarifa
    LEFT JOIN adicionales ad ON p.id_adicional = ad.id_adicional;

    RETURN promedio_ingresos;
END$$

DELIMITER ;


-- STORED PROCEDURES

-- registrar un nuevo alquiler
-- Este procedimiento almacena un nuevo alquiler en la base de datos, ingresando los datos del cliente, el auto alquilado y los días de alquiler.

DELIMITER $$

CREATE PROCEDURE registrar_nuevo_alquiler(
    IN cliente_id INT,
    IN auto_id INT,
    IN dias_alquiler INT,
    IN tarifa_id INT,
    IN metodo_pago VARCHAR(30)
)
BEGIN
    DECLARE valor_unitario DECIMAL(10,2);
    DECLARE nuevo_pago_id INT;

    -- Obtener el valor unitario de la tarifa
    SELECT precio_diario INTO valor_unitario FROM tarifas WHERE id_tarifa = tarifa_id;

    -- Crear un nuevo pago
    INSERT INTO pago (id_tarifa, fecha_transaccion, metodo_pago)
    VALUES (tarifa_id, NOW(), metodo_pago);

    -- Obtener el ID del pago recién creado
    SET nuevo_pago_id = LAST_INSERT_ID();

    -- Insertar un nuevo alquiler
    INSERT INTO alquileres (fecha_inicio, cantidad_dias, id_cliente, id_auto, id_pago)
    VALUES (NOW(), dias_alquiler, cliente_id, auto_id, nuevo_pago_id);
END$$

DELIMITER ;


-- obtener clientes frecuentes
-- Este procedimiento lista los clientes que han alquilado más de un número específico de veces.

DELIMITER $$

CREATE PROCEDURE obtener_clientes_frecuentes(
    IN min_alquileres INT
)
BEGIN
    -- Obtener clientes con un número mínimo de alquileres
    SELECT c.id_cliente, c.nombre, c.apellido, COUNT(a.id_alquiler) AS total_alquileres
    FROM clientes c
    JOIN alquileres a ON c.id_cliente = a.id_cliente
    GROUP BY c.id_cliente, c.nombre, c.apellido
    HAVING total_alquileres >= min_alquileres;
END$$

DELIMITER ;

-- TRIGGERS

DELIMITER $$

CREATE TRIGGER verificar_disponibilidad_auto
-- permitira ver si tenemos disponibilidad de un determinado auto, o si se puede reservar.
BEFORE INSERT ON alquileres
FOR EACH ROW
BEGIN
    DECLARE auto_disponible TINYINT;

    -- Verificamos si el auto está disponible
    SELECT disponibilidad INTO auto_disponible
    FROM flota_de_autos
    WHERE id_auto = NEW.id_auto;

    -- Si el auto no está disponible, lanzamos un error
    IF auto_disponible = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'El auto seleccionado no está disponible para alquiler.';
    END IF;
END$$

DELIMITER ;

-- PRUEBA DE VALIDACION
INSERT INTO rac_ar.alquileres (fecha_inicio, cantidad_dias, id_cliente, id_auto, id_pago)
VALUES (NOW(), 5, 123, 3, 139)

-- TRIGGER DE AUDITORIA POR ACTUALIZACION DE TARIFAS

-- PRIMERO CREAMOS LA TABLA DE AUDITORIA

CREATE TABLE rac_ar.auditoria_tarifas (
    id_auditoria INT AUTO_INCREMENT PRIMARY KEY,
    id_tarifa INT,
    precio_anterior DECIMAL(10,2),
    precio_nuevo DECIMAL(10,2),
    fecha_actualizacion DATETIME
);

-- Y CREAMOS EL TRIGGER PARA ACTUALIZAR LAS TARIFAS

DELIMITER $$

CREATE TRIGGER auditoria_actualizacion_tarifa
AFTER UPDATE ON tarifas
FOR EACH ROW
BEGIN
    -- Insertar en la tabla de auditoría los datos de la tarifa antes y después del cambio
    INSERT INTO auditoria_tarifas (id_tarifa, precio_anterior, precio_nuevo, fecha_actualizacion)
    VALUES (OLD.id_tarifa, OLD.precio_diario, NEW.precio_diario, NOW());
END$$

DELIMITER ;

-- actualizacion de tarifas de autos de lujo

UPDATE rac_ar.tarifas 
SET precio_diario = precio_diario + 15.99
WHERE id_tarifa = 5;

-- prueba de cambio de precios

SELECT * FROM auditoria_tarifas WHERE id_tarifa = 5;



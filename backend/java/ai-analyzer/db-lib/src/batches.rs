//! CRUD sobre la tabla `batches`.

use std::os::raw::{c_char, c_int};

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring, string_to_raw},
};

// ─── INSERT ───────────────────────────────────────────────────────────────────

/// Inserta un batch nuevo.
///
/// - `received_at`: ISO-8601 UTC, p.ej. "2025-04-25T12:00:00Z"
/// - `sensor_ip`:   puede ser NULL
/// - `payload`:     JSON crudo del sensor
///
/// Devuelve el `rowid` del batch insertado (≥1), o 0 en error.
///
/// # Safety
/// `handle`, `received_at` y `payload` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn batch_insert(
    handle:      *mut DbHandle,
    received_at: *const c_char,
    sensor_ip:   *const c_char,
    payload:     *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let at = match cstr_to_str(received_at) {
        Some(s) => s,
        None => { set_last_error("received_at nulo o UTF-8 inválido"); return 0; }
    };
    let payload_str = match cstr_to_str(payload) {
        Some(s) => s,
        None => { set_last_error("payload nulo o UTF-8 inválido"); return 0; }
    };
    let ip: Option<&str> = cstr_to_str(sensor_ip);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO batches (received_at, sensor_ip, status, payload) VALUES (?1, ?2, 'pending', ?3)",
        rusqlite::params![at, ip, payload_str],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

// ─── UPDATE STATUS ────────────────────────────────────────────────────────────

/// Actualiza `status` de un batch por ID.
///
/// Devuelve 1 si se actualizó 1 fila, 0 en error o si no existe.
///
/// # Safety
/// `handle` y `status` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn batch_set_status(
    handle: *mut DbHandle,
    id:     i64,
    status: *const c_char,
) -> c_int {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let st = match cstr_to_str(status) {
        Some(s) => s,
        None => { set_last_error("status nulo o UTF-8 inválido"); return 0; }
    };

    let conn = h.conn.lock();
    match conn.execute("UPDATE batches SET status=?1 WHERE id=?2", rusqlite::params![st, id]) {
        Ok(n) => n as c_int,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

// ─── SELECT ───────────────────────────────────────────────────────────────────

/// Devuelve el batch con el ID dado como JSON (`*mut c_char`), o NULL si no existe.
///
/// JSON: `{"id":1,"received_at":"...","sensor_ip":"...","status":"pending","payload":"..."}`
///
/// Java debe liberar el puntero con `db_free_string`.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_get_by_id(handle: *mut DbHandle, id: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };

    let conn = h.conn.lock();
    let result = conn.query_row(
        "SELECT id, received_at, sensor_ip, status, payload FROM batches WHERE id=?1",
        rusqlite::params![id],
        |row| {
            Ok(serde_json::json!({
                "id":          row.get::<_, i64>(0)?,
                "received_at": row.get::<_, String>(1)?,
                "sensor_ip":   row.get::<_, Option<String>>(2)?,
                "status":      row.get::<_, String>(3)?,
                "payload":     row.get::<_, String>(4)?,
            }))
        },
    );

    match result {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve hasta `limit` batches con `status='pending'` ordenados por id ASC,
/// como JSON array.  Devuelve `"[]"` si no hay ninguno.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_list_pending(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };

    let lim = if limit <= 0 { 100 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, received_at, sensor_ip, status, payload \
         FROM batches WHERE status='pending' ORDER BY id ASC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":          row.get::<_, i64>(0)?,
            "received_at": row.get::<_, String>(1)?,
            "sensor_ip":   row.get::<_, Option<String>>(2)?,
            "status":      row.get::<_, String>(3)?,
            "payload":     row.get::<_, String>(4)?,
        }))
    }).and_then(|mapped| mapped.collect());

    match rows {
        Ok(vec) => {
            let arr = serde_json::Value::Array(vec);
            json_to_cstring(&arr)
        }
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve los `limit` batches más recientes (cualquier status) como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };

    let lim = if limit <= 0 { 20 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, received_at, sensor_ip, status FROM batches ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":          row.get::<_, i64>(0)?,
            "received_at": row.get::<_, String>(1)?,
            "sensor_ip":   row.get::<_, Option<String>>(2)?,
            "status":      row.get::<_, String>(3)?,
        }))
    }).and_then(|mapped| mapped.collect());

    match rows {
        Ok(vec) => json_to_cstring(&serde_json::Value::Array(vec)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve el número total de batches. Devuelve -1 en error.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_count(handle: *mut DbHandle) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.query_row("SELECT COUNT(*) FROM batches", [], |r| r.get::<_, i64>(0)) {
        Ok(n) => n,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

/// Devuelve el número de batches con `status='pending'`. Devuelve -1 en error.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_count_pending(handle: *mut DbHandle) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.query_row(
        "SELECT COUNT(*) FROM batches WHERE status='pending'",
        [],
        |r| r.get::<_, i64>(0),
    ) {
        Ok(n) => n,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

// ─── DELETE ───────────────────────────────────────────────────────────────────

/// Borra batches procesados anteriores a `before_iso` (ISO-8601).
/// Devuelve número de filas eliminadas, o -1 en error.
///
/// # Safety
/// `handle` y `before_iso` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn batch_purge_before(
    handle:     *mut DbHandle,
    before_iso: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let before = match cstr_to_str(before_iso) {
        Some(s) => s,
        None => { set_last_error("before_iso nulo o UTF-8 inválido"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.execute(
        "DELETE FROM batches WHERE status != 'pending' AND received_at < ?1",
        rusqlite::params![before],
    ) {
        Ok(n) => n as i64,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

/// Devuelve el payload del batch como `*mut c_char`, o NULL si no existe.
/// Util para el worker que necesita solo el JSON crudo.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn batch_get_payload(handle: *mut DbHandle, id: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    match conn.query_row(
        "SELECT payload FROM batches WHERE id=?1",
        rusqlite::params![id],
        |r| r.get::<_, String>(0),
    ) {
        Ok(s) => string_to_raw(s),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
